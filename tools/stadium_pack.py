#!/usr/bin/env python3
"""Pack the Pokemon Stadium battle models into the mod's own .dsm format.

    tools/stadium_pack.py [--rom=PATH] [--out=assets/stadium]
                          [--only=25,6] [--report]

Reads the ROM directly, through model_extract/pipeline -- the same modules,
in the same order, that lib/StadiumRom.lua and lib/StadiumFragment.lua port to
Lua so the mod can do this itself at runtime with no Python and no checked-in
extract.  That parallel is the point of this tool now: it is the ORACLE the
Lua extractor is verified against (tests/stadium_extract_test.lua diffs all
151 files byte for byte), so anything that changes the bytes has to change on
both sides or the suite says so.

The output is one file per species, `NNN.dsm`, holding geometry, the bone
tree, every animation, the textures and the battle system's own slot tables
(which animation each move plays, and which one each battle context asks
for).  Nothing here is decoded at runtime beyond byte order: lib/
StadiumPack.lua walks these files straight into arrays.

Textures are stored as RAW RGBA8 rather than PNG, which is why the magic is
DSM3.  Two reasons, and the second is the one that decided it.  A PNG costs a
decode on the frame a battle starts, where an ImageData over the bytes costs
nothing.  And PNG means zlib: Python's deflate and LOVE's are both valid and
need not agree byte for byte, so a packed PNG would make this file impossible
to check the Lua extractor against.  Uncompressed pixels are the same pixels
whoever wrote them.

Everything is little-endian, so the reader's byte pairs go (low, high).

    header
      "DSM3"                                        magic
      u16   species, bones, prims, textures, anims, auxAnims
      f32   rootScale                               the model_root's own scale
      u8    staticPose                              1 = never animate
      f32   height, floor, radius                   the bind pose's extent,
                                                    in GAME units after
                                                    rootScale -- what the mod
                                                    sizes a mon on its tile by
      u16   moveAnim[165]                           move id -> animation
      i16   moveAux[165]                            move id -> texture anim
      u16   ctxAnim[20]                             slot 165..184 -> animation
    bones[]
      i16   parent (-1 root)
      i16   t[3]                                    rest translation
      i16   r[3]                                    rest rotation, binary
                                                    angles (32768 = pi)
      i32   s[3]                                    rest scale, 16.16 fixed
    prims[]
      u16   texture
      u8    cull                                    1 = cull back faces
      u8    blend                                   1 = additive (fx flipbook)
      i16   texAnimChannel (-1 none)
      u8    texMapN, then texMapN * (u8 key, u16 texture)
      u16   fxN, then fxN * u16                     flipbook texture frames
      u16   verts, indices
      verts * (i16 x, y, z ; i16 u, v at 1/512 ; i8 nx, ny, nz ; u8 bone)
      indices * u16
    textures[]
      u16   w, h ; u32 length ; length RGBA8 bytes (= w * h * 4)
    anims[]
      u8    name length, then the name
      u16   frames, loopStart ; i16 aux (-1 none)
      bones * track:
        u8  1 if this bone is animated at all, else 0
        when animated, nine components in order tx ty tz rx ry rz sx sy sz,
        each   u8 kind (0 constant, 1 one value a frame)
               then 1 or `frames` values -- i16 for t and r, i32 16.16 for s
    auxAnims[]
      u16   frames, loopStart, channels
      channels * (u16 length, then that many u16 texture-table indices)

Stdlib only, like the extraction pipeline it drives.
"""

import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.dirname(HERE)
PIPELINE = os.path.join(MOD, 'model_extract', 'pipeline')
sys.path.insert(0, PIPELINE)

import battle          # noqa: E402  (needs PIPELINE on the path first)
import build           # noqa: E402
import fragment        # noqa: E402
import rom as rom_mod  # noqa: E402

# The battle system's fixed context slots, in slot order from 165.  Names are
# manifest.json's own (animationSlots); the mod indexes this list by position,
# so the ORDER is the contract and must match lib/StadiumPack.lua's CONTEXT.
CONTEXTS = [
    'idle', 'attack_default', 'faint', 'entrance', 'reaction_169', 'reaction_170',
    'reaction_171', 'reaction_172', 'reaction_173', 'reaction_174',
    'struggle', 'idle_alt', 'faint_alt', 'flinch', 'reaction_179',
    'reaction_180', 'reaction_181', 'reaction_182', 'entrance_alt',
    'idle_return',
]

N_MOVES = 165
NONE16 = 0xFFFF

# How many battle Pokemon the model archive holds, and where the fixed context
# slots start in a species' battle table (entries 0..164 are the moves).
N_POKEMON = 151
CTX_BASE = 165


# --------------------------------------------------------------- bind extent

def quat_basis(r):
    """The game's rotation as a 3x3, rows first (src/F420.c func_8000F730).

    Rx*Ry*Rz in row-vector form -- the same basis model_extract/pipeline/
    glb.py converts to a quaternion, kept as a matrix here because that is
    what the runtime builds too.
    """
    sx, cx = math.sin(r[0] / 32768 * math.pi), math.cos(r[0] / 32768 * math.pi)
    sy, cy = math.sin(r[1] / 32768 * math.pi), math.cos(r[1] / 32768 * math.pi)
    sz, cz = math.sin(r[2] / 32768 * math.pi), math.cos(r[2] / 32768 * math.pi)
    return ((cy * cz, sx * sy * cz - cx * sz, cx * sy * cz + sx * sz),
            (cy * sz, sx * sy * sz + cx * cz, cx * sy * sz - sx * cz),
            (-sy, sx * cy, cx * cy))


def mat_mul(a, b):
    """3x4 (rotation rows plus a translation column) times the same."""
    out = []
    for r in range(3):
        row = []
        for c in range(3):
            row.append(sum(a[r][k] * b[k][c] for k in range(3)))
        row.append(sum(a[r][k] * b[k][3] for k in range(3)) + a[r][3])
        out.append(tuple(row))
    return tuple(out)


def rest_sample(bones):
    def sample(i):
        b = bones[i]
        return b['t'], b['r'], b['s']
    return sample


def anim_sample(bones, anim, frame):
    """The bone TRS this animation holds at `frame`, rest where it is silent."""
    tracks = anim['tracks']

    def component(comps, i, fallback):
        if comps is None:
            return fallback
        c = comps[i]
        if isinstance(c, list):
            return c[frame % len(c)] if c else fallback
        return c

    def sample(i):
        b = bones[i]
        tr = tracks[i] if i < len(tracks) else None
        if not tr:
            return b['t'], b['r'], b['s']
        return ([component(tr.get('t'), k, b['t'][k]) for k in range(3)],
                [component(tr.get('r'), k, b['r'][k]) for k in range(3)],
                [component(tr.get('s'), k, b['s'][k]) for k in range(3)])
    return sample


def bind_matrices(bones, sample=None):
    """Every bone's draw matrix at one instant, as 3x4 rows.

    The game keeps bone scale out of the matrix chain: it accumulates in its
    own stack, a bone's local translation is pre-multiplied by the PARENT's
    accumulated scale, and the bone's own accumulated scale is applied to the
    finished matrix at draw time.  This is that, and it is the same walk
    lib/StadiumRig.lua does per frame.

    Two chains, and the distinction is the whole point: `pivot` is the
    rotation/translation chain a CHILD inherits, and the draw matrix is that
    with the bone's own accumulated scale applied on the right.  Folding the
    scale into the chain instead would apply every ancestor's scale twice --
    which is exactly the multiplicative propagation glTF has and the game
    does not (see model_extract/README.md's two-node export).
    """
    sample = sample or rest_sample(bones)
    pivot, draw, acc = [], [], []
    for i, b in enumerate(bones):
        bt, br, bs = sample(i)
        p = b['parent']
        pa = acc[p] if p >= 0 else (1.0, 1.0, 1.0)
        pm = pivot[p] if p >= 0 else ((1, 0, 0, 0), (0, 1, 0, 0), (0, 0, 1, 0))
        t = [bt[i2] * pa[i2] for i2 in range(3)]
        rot = quat_basis(br)
        local = tuple((rot[r][0], rot[r][1], rot[r][2], t[r]) for r in range(3))
        m = mat_mul(pm, local)
        a = tuple(pa[i2] * bs[i2] for i2 in range(3))
        acc.append(a)
        pivot.append(m)
        # scale on the right: the bone's own space, so it cannot reach children
        draw.append(tuple((m[r][0] * a[0], m[r][1] * a[1], m[r][2] * a[2],
                           m[r][3]) for r in range(3)))
    return draw


def pose_box(data, mats):
    """The axis-aligned box the whole model occupies under `mats`, in game
    units after the model_root scale."""
    root = data['rootScale'][0]
    lo = [1e30, 1e30, 1e30]
    hi = [-1e30, -1e30, -1e30]
    for prim in data['prims']:
        pos, skin = prim['pos'], prim['skin']
        for i in range(len(skin)):
            m = mats[skin[i]]
            x, y, z = pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]
            for a in range(3):
                v = (m[a][0] * x + m[a][1] * y + m[a][2] * z + m[a][3]) * root
                lo[a] = min(lo[a], v)
                hi[a] = max(hi[a], v)
    return lo, hi


def stance(data):
    """(height, floor, radius): how tall the mon is, where its lowest point
    sits relative to the model's own origin, and how wide it is -- all in
    game units after the model_root scale.

    Measured on the BIND POSE, which is the one pose in the set that can be
    trusted for this.  Two things recommend it.  It reproduces the verified
    glTF export bit for bit on all 151 species, so it is measuring the same
    skeleton the reference implementation agreed with; and it is immune to
    the animation quirks a handful of species carry (Exeggutor's idle throws
    limbs hundreds of units off the body from frame 1 on, and Magmar's does
    something similar) -- quirks that would otherwise decide how big every
    OTHER frame of those species is drawn.

    The floor is the interesting number, and it reads cleanly: 119 of the
    151 sit within 5% of zero, which says the model origin IS where the game
    stands a Pokemon on its field.  Every species that does not is one that
    hovers -- Zubat, Magnemite and Geodude float above their origin,
    Tentacruel, Gastly, Haunter, Weezing and Zapdos hang below it.  What the
    mod does with that is a placement decision and lives in StadiumMon.
    """
    lo, hi = pose_box(data, bind_matrices(data['bones']))
    if lo[0] > hi[0]:
        return 0.0, 0.0, 0.0
    return hi[1] - lo[1], lo[1], max(hi[0] - lo[0], hi[2] - lo[2]) / 2


def idle_is_broken(data, idle):
    """Whether this species' standby loop is corrupt in the source data.

    A handful of species come out of the extraction with animations that
    throw bones hundreds of units off the body -- Exeggutor, Tangela and
    Magmar, whose channel streams the game's own index arithmetic evidently
    reads differently from the way the exporter does.  Played, they look
    like a Pokemon coming apart; the mod would rather stand them still.

    The test is deliberately narrow, because "differs from the bind pose" is
    NOT brokenness.  It is asked only of the STANDBY loop, which is the one
    animation that is supposed to stay where it is -- a faint is meant to
    end far from the standing pose and an attack is meant to lunge -- and it
    wants both a large size blow-up and real drift, or an enormous amount of
    one.  Dewgong is what calibrates it: its idle is 2.4x its own bind pose
    because the BIND is the collapsed one, and it drifts barely at all, so
    it must not be caught.
    """
    if idle is None:
        return False
    bones = data['bones']
    lo, hi = pose_box(data, bind_matrices(bones))
    span = hi[1] - lo[1]
    if span <= 0:
        return False
    worst_h, worst_drift = 1.0, 0.0
    for frame in range(0, idle['frames'], 3):
        flo, fhi = pose_box(data, bind_matrices(bones,
                                                anim_sample(bones, idle, frame)))
        worst_h = max(worst_h, (fhi[1] - flo[1]) / span)
        worst_drift = max(worst_drift, abs(flo[1] - lo[1]) / span,
                          abs(fhi[1] - hi[1]) / span)
    return ((worst_h > 2.5 and worst_drift > 1.5)
            or worst_drift > 2.0 or worst_h > 3.4)


# --------------------------------------------------------------------- write

class Writer:
    def __init__(self):
        self.parts = []

    def raw(self, b):
        self.parts.append(b)

    def u8(self, v):
        self.parts.append(struct.pack('<B', v & 0xFF))

    def u16(self, v):
        self.parts.append(struct.pack('<H', v & 0xFFFF))

    def i16(self, v):
        self.parts.append(struct.pack('<h', clamp(int(v), -32768, 32767)))

    def i32(self, v):
        self.parts.append(struct.pack('<i', clamp(int(v), -2**31, 2**31 - 1)))

    def u32(self, v):
        self.parts.append(struct.pack('<I', v))

    def f32(self, v):
        self.parts.append(struct.pack('<f', v))

    def i8(self, v):
        self.parts.append(struct.pack('<b', clamp(int(v), -128, 127)))

    def bytes(self):
        return b''.join(self.parts)


def clamp(v, lo, hi):
    return lo if v < lo else (hi if v > hi else v)


def fixed(v):
    """16.16, which holds every bone scale in the set (-31 .. 100) exactly
    enough that a rounded one is invisible."""
    return clamp(int(round(v * 65536)), -2**31, 2**31 - 1)


def write_track_component(w, values, kind):
    """One component of one bone's t/r/s in one animation.

    `values` is the js payload's own shape: a bare number when the component
    holds still for the whole animation, or one number a frame when it does
    not.  That fold is where most of the size saving is -- a bone that only
    rotates costs two bytes for each of its six other components.
    """
    array = isinstance(values, list)
    w.u8(1 if array else 0)
    seq = values if array else [values]
    if kind == 's':
        for v in seq:
            w.i32(fixed(v))
    else:
        for v in seq:
            w.i16(int(round(v)))


def context_table(rows, n_anims):
    """Which animation each fixed battle context slot resolves to.

    Entries 165 upward of the species' own battle table, in slot order, which
    is exactly what CONTEXTS lists.  An entry naming an animation the species
    does not have is written as "none" rather than clamped: the mod would
    rather fall back than play the wrong clip.
    """
    ctx = [NONE16] * len(CONTEXTS)
    for i in range(len(CONTEXTS)):
        e = CTX_BASE + i
        ai = rows[e][0] if e < len(rows) else None
        if ai is not None and ai < n_anims:
            ctx[i] = ai
    return ctx


def pack(data, species, move_rows, ctx):
    w = Writer()
    bones, prims = data['bones'], data['prims']
    textures, anims, aux = data['textures'], data['anims'], data['auxAnims']

    height, floor, radius = stance(data)

    idle_index = ctx[CONTEXTS.index('idle')]
    idle = anims[idle_index] if idle_index != NONE16 else None
    static = idle_is_broken(data, idle)

    w.raw(b'DSM3')
    for v in (species, len(bones), len(prims), len(textures), len(anims),
              len(aux)):
        w.u16(v)
    w.f32(data['rootScale'][0])
    # 1 = hold the bind pose, never play an animation (see idle_is_broken).
    # Immediately after rootScale, which is where the format table above says
    # it is and where lib/StadiumPack.lua reads it.
    w.u8(1 if static else 0)
    w.f32(height)
    w.f32(floor)
    w.f32(radius)

    rows = move_rows or []
    for m in range(N_MOVES):
        row = rows[m] if m < len(rows) else None
        w.u16(row[0] if row and row[0] < len(anims) else NONE16)
    for m in range(N_MOVES):
        row = rows[m] if m < len(rows) else None
        w.i16(row[1] if row and 0 <= row[1] < len(aux) else -1)
    for v in ctx:
        w.u16(v)

    for b in bones:
        w.i16(b['parent'])
        for v in b['t']:
            w.i16(round(v))
        for v in b['r']:
            w.i16(v)
        for v in b['s']:
            w.i32(fixed(v))

    for p in prims:
        w.u16(p['tex'])
        # the display list's own cull mode: 1024 is G_CULL_BACK
        w.u8(1 if p.get('cull') else 0)
        w.u8(1 if p.get('blend') == 'add' else 0)
        w.i16(p.get('texAnim', -1))
        tex_map = p.get('texMap') or {}
        w.u8(len(tex_map))
        for key, tex in sorted(tex_map.items(), key=lambda kv: int(kv[0])):
            w.u8(int(key))
            w.u16(tex)
        frames = p.get('fxFrames') or []
        w.u16(len(frames))
        for f in frames:
            w.u16(f)
        pos, uv, nrm, skin, idx = (p['pos'], p['uv'], p['nrm'], p['skin'],
                                   p['idx'])
        n = len(skin)
        w.u16(n)
        w.u16(len(idx))
        for i in range(n):
            w.i16(pos[i * 3])
            w.i16(pos[i * 3 + 1])
            w.i16(pos[i * 3 + 2])
            # 1/512, which puts a texel of the largest texture in the set
            # well inside a step and still reaches the +-32 the wrapped
            # coordinates of some display lists run to
            w.i16(round(uv[i * 2] * 512))
            w.i16(round(uv[i * 2 + 1] * 512))
            w.i8(round(nrm[i * 3] * 127))
            w.i8(round(nrm[i * 3 + 1] * 127))
            w.i8(round(nrm[i * 3 + 2] * 127))
            w.u8(skin[i])
        for v in idx:
            w.u16(v)

    for t in textures:
        rgba = t['rgba']
        w.u16(t['w'])
        w.u16(t['h'])
        w.u32(len(rgba))
        w.raw(rgba)

    for a in anims:
        name = (a.get('name') or '')[:255].encode('utf8')
        w.u8(len(name))
        w.raw(name)
        w.u16(a['frames'])
        w.u16(a.get('loopStart', 0))
        w.i16(a.get('aux', -1))
        tracks = a['tracks']
        for bi in range(len(bones)):
            tr = tracks[bi] if bi < len(tracks) else None
            if not tr:
                w.u8(0)
                continue
            w.u8(1)
            for key in ('t', 'r', 's'):
                comps = tr.get(key)
                if comps is None:
                    # a bone the animation leaves at its rest value for this
                    # path: written as three constants so the reader never
                    # has to branch on a missing path
                    rest = {'t': [0, 0, 0], 'r': [0, 0, 0],
                            's': [1.0, 1.0, 1.0]}[key]
                    src = bones[bi][key] if key in bones[bi] else rest
                    comps = list(src)
                for c in comps:
                    write_track_component(w, c, key)

    for a in aux:
        w.u16(a['frames'])
        w.u16(a.get('loopStart', 0))
        chans = a['channels']
        w.u16(len(chans))
        for ch in chans:
            w.u16(len(ch))
            for v in ch:
                w.u16(v)

    return w.bytes(), (height, floor, radius)


# ---------------------------------------------------------------------- main

def build_one(blob, fileno, tables, moves):
    """One model fragment -> the payload `pack` takes.

    The same three steps build.py takes for a Pokemon, in the same order:
    parse the fragment, label the animations off the species' battle table,
    then hang the generated fire/gas stand-ins on the bones the game's own
    effect callbacks hang off.
    """
    data = fragment.extract(blob, '%d.bin' % fileno, raw=True)
    species = data['species']
    rows = tables.rows(species)
    build.label_animations(data, rows, moves)
    build.attach_effects(data, species, raw=True)
    data['name'] = battle.SPECIES.get(species, '#%d' % species)
    return data, species, rows


def main(argv):
    args = {a.split('=')[0]: (a.split('=', 1)[1] if '=' in a else True)
            for a in argv}
    out = args.get('--out') or os.path.join(MOD, 'assets', 'stadium')
    only = ({int(x) for x in args['--only'].split(',')}
            if '--only' in args else None)

    rom_path = args.get('--rom') or build.find_rom()
    if not rom_path or not os.path.exists(rom_path):
        print('ROM not found. Put a Pokemon Stadium (US 1.0) ROM at\n  %s\n'
              'or pass --rom=PATH.'
              % os.path.join(build.BASEROMS, 'baserom.z64'), file=sys.stderr)
        return 1

    rom = rom_mod.Rom(rom_path)
    if not rom.is_expected_us:
        print('warning: md5 %s is not the expected US 1.0 ROM' % rom.md5,
              file=sys.stderr)
    blobs = rom_mod.pokemon_models(rom)
    tables = battle.BattleTables(rom)
    moves = battle.load_move_names(os.path.join(MOD, 'model_extract'))

    os.makedirs(out, exist_ok=True)
    total, report, statics = 0, [], []
    for fileno in range(min(N_POKEMON, len(blobs))):
        data, species, rows = build_one(blobs[fileno], fileno, tables, moves)
        if only and species not in only:
            continue
        move_rows = [[rows[m][0], rows[m][1]] for m in range(N_MOVES)]
        blob, extent = pack(data, species, move_rows,
                            context_table(rows, len(data['anims'])))
        if blob[4 + 12 + 4] == 1:
            statics.append(species)
        path = os.path.join(out, '%03d.dsm' % species)
        with open(path, 'wb') as fp:
            fp.write(blob)
        total += len(blob)
        report.append((species, data['name'], len(blob), extent,
                       len(data['bones']), len(data['prims']),
                       len(data['anims'])))

    print('%d models, %.1f MB -> %s' % (len(report), total / 1e6, out))
    if statics:
        print('held at the bind pose (corrupt standby loop in the source): %s'
              % ', '.join(str(x) for x in statics))
    if '--report' in args:
        report.sort(key=lambda r: -r[3][0])
        print('%-4s %-12s %9s %8s %8s %6s %6s %5s'
              % ('#', 'name', 'bytes', 'height', 'floor', 'bones', 'prims',
                 'anims'))
        for r in report[:10] + report[-5:]:
            print('%-4d %-12s %9d %8.2f %8.2f %6d %6d %5d'
                  % (r[0], r[1], r[2], r[3][0], r[3][1], r[4], r[5], r[6]))
        heights = sorted(r[3][0] for r in report)
        print('height: min %.2f  median %.2f  max %.2f'
              % (heights[0], heights[len(heights) // 2], heights[-1]))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
