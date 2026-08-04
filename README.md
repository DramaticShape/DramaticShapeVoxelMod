# Dramatic Shape Voxel Mod

A mod for the [Pokémon Gen 1 Recompilation
Project](https://github.com/bryanthaboi/pokemon-gen1-recomp-project).

The overworld as a voxelized 3D diorama. Also supports experimental
first-person, third-person and VR.

## Controls

Every key is free-roam only, and each one is also a row on the OPTIONS
menu.

| control | does |
| --- | --- |
| `3`, or the **VOXEL** options row | OFF → 15 → 35 → 50 → 75 → 1ST → 3RD → OFF (camera pitch) |
| `SELECT` (pad / touch) | the same step as `3` — for the machines with no number row |
| `5`, or the **V-GRID** options row | OFF / ON — a one-pixel wireframe on every voxel |
| `6`, or the **T-SHIFT** options row | OFF → 1 → 2 → 3 → OFF (miniature blur) |
| `7`, or the **V-CURVE** options row | OFF → 1 → 2 → 3 — bend the world over the horizon |
| `8`, or the **3D-BTL** options row | ON / OFF — fight on the map instead of on a white field |
| `9`, or the **WATER** options row | FULL / SKY / OFF — waves and reflections on water. **SKY** gives the surface its pixel-tall wave columns and puts the sky, the sun, the moon and the cast in them; **FULL** adds a screen-space ray march that also reflects the shoreline, the trees and the buildings standing behind it |
| the **BACK SPRITES** options row | OFF / ON — keep your own Pokémon on the battle menu, seen from behind in its classic slot, instead of standing it on the map; the foe is still out there. Only on the menu while **3D-BTL** is on, because it decides nothing without it |
| the **AA** options row | OFF / 2X / 4X — smooth the stair-stepped edges of the 3D world by rendering the diorama larger than the window and folding it back down. The ladder is samples per display pixel: 2X is a canvas root-two wider and taller, 4X one exactly twice the size. Every edge in the projected picture softens with the silhouettes — the tileset's own texels are quads in a perspective view and cross the pixel grid at the same arbitrary angles — so the diorama reads smoother rather than sharper. The most expensive row in the mod, so it is OFF by default and **FULL** leaves it alone |
| the **DAYTIME** options row | SYNC / DAY / NIGHT / DUSK / DAWN / CYCLE — what time it is outdoors, on the diorama *and* on the flat 2D world; held at SYNC (and off the menu) while VOXEL is FULL |

## Free-roam cameras (1ST / 3RD)

The last two rungs of the **VOXEL** ladder are experimental, and they are
the same camera: **1ST** stands it in the player's own eyes, **3RD** pulls
it back onto a boom behind their shoulder. Both steer, and on both the grid
walk is replaced by continuous camera-relative movement — push in any
direction and you go there, at any angle, not just along the four compass
lines. Collision, warps, ledges, encounters and scripts all still run
through the engine's own machinery.

| control | does |
| --- | --- |
| mouse | look (the cursor is captured; left click is A, right click is B) |
| right stick | look |
| a touch drag off the overlay's controls | look |
| left stick / touch d-pad / arrow keys | walk, relative to where the camera looks |
| wheel, `Q` / `E`, pinch, or a stick click | **3RD only** — let the boom out and pull it in (`Q` and left stick click out, `E` and right stick click in) |

On an **orbit rung** the same wheel, `Q`/`E` and pinch drive the engine's own
survey zoom. On **1ST** they do nothing at all: the eye is in your head, and
there is no distance to change.

On **3RD** the boom shortens against whatever is behind you, so backing into
a wall walks the camera in to your shoulders rather than through it — squeeze
it all the way in and the view is 1ST until you step clear. The character
turns to face where they are walking, and every sprite in the world — yours,
the NPCs', the figures drawn into the furniture — turns to face the camera
and shows the frame it would look like from where the camera actually
stands, so walking behind someone shows you their back.

## The battle camera

A fight staged on the map (**3D-BTL**, on by default) is shot with a solved
over-the-shoulder rig — and you can steer it.

| control | does |
| --- | --- |
| right stick, a touch drag, or the mouse | swing the shot around the arena (→) and raise the seat (↑) |
| wheel, `Q` / `E`, pinch, or a stick click | the lens (`Q` / left stick click out, `E` / right stick click in) |

Both axes stop where the composition does. Left stops at the shot the rig was
solved for — there is nothing to the left of it. Right ends **side-on**: the
eye square to the arena's axis, both Pokémon at the same distance instead of
one behind the other. Down stops at the rig's own low stance; up is 45° above
it. The lens opens as you swing or climb, by exactly the amount the two
Pokémon spread apart, so they stay framed at every angle. Move animations
follow the pair's position *and* its separation, so a beam still lands on the
Pokémon it was aimed at.

Where you leave the camera is where the next battle opens.

**BACK SPRITES locks it.** That setting pins your own Pokémon to the GB's slot
on the menu while the foe stands out on the map, and no angle holds a
composition that is half frame and half world — so with it on, the shot holds
the one the rig was solved for.

## STADIUM battles

The **3D-BTL** row has four rungs:

| rung | the fight |
| --- | --- |
| **2D-3D** | staged on the map, with the Game Boy's own pics stood up on their tiles |
| **STADIUM A** | staged on the map, with the Pokémon Stadium battle models |
| **STADIUM B** | the same models on two discs against the sky, with no map drawn |
| **OFF** | the engine's own battle screen |

All 151 species, skinned and animated, playing the animation the move being
used actually calls for — the Stadium ROM's own per-species move table, so
**DIG** really does put Diglett into the ground. Damage plays the hit
reaction, fainting plays the faint and holds there, a send-out plays the
entrance, and between all of that the standby loop runs. Eyes blink and go
dizzy; Charmander's tail flame and Weezing's gas are drawn over the body.

**B is for the maps that cannot host a fight.** Half of Kanto's interiors are
furniture, a cave floor can be nothing but corridors, and a map where neither
Pokémon can be *seen* from a low camera is declined outright — which drops you
back to the flat battle screen. B carries its stage, so it works everywhere
and looks the same every time. It is abstracted from the ground, not from the
world: the sky behind the discs is the hour's own, and a fight in a cave is
under that cave's void and its own flat light.

### Getting the models

**They are not in this mod, and they cannot be** — they are Pokémon Stadium's
data. What ships is the reader; you supply the cartridge, exactly as this
engine already asks you to supply the Game Boy ROM it is a recompilation of.

1. Put a **Pokémon Stadium (US)** ROM in a `baseroms/` folder beside the game.
   `.z64`, `.n64` and `.v64` all work — the byte order is detected.
   In a packaged build, `baseroms/` goes in the save directory; the mod logs
   the exact path on startup when it cannot find one.
2. Start the game. The 151 models are built out of the ROM on a loading
   screen, in about ten seconds.
3. The two STADIUM rungs appear on the 3D-BTL row.

The built models live in the save directory, not in the mod folder, and are
rebuilt automatically if the format changes or the ROM does. Until they exist
the STADIUM rungs are simply not on the row — skipped rather than shown and
refused, because a setting you can select that then does nothing is worse than
one that is not there.

**This works on mobile.** The extraction is pure Lua — no FFI, no native
helper, no second process — so it runs anywhere LÖVE does. It peaks at about
68 MB of Lua heap (32 MB of that the cartridge itself) with a working set that
does not grow across the run, and `tests/stadium_budget_test.lua` fails if
either stops being true. On Android the save directory is the app's
external-files folder, so `baseroms/` there is reachable over USB or a file
manager without root; the build is slower than a desktop's ~7 s but runs one
species a frame behind the progress bar either way.

Developers can pre-build them with `tools/stadium_pack.py`, which reads the
same ROM through `model_extract/pipeline`. That path is also the *oracle*:
`tests/stadium_extract_test.lua` runs it and the in-game Lua extractor over
the same cartridge and requires all 151 packed files to come out byte for byte
identical.

## VR

The **VR** options row (OFF / ON, off by default) drives a PCVR headset
through OpenXR on Windows — SteamVR, Oculus or WMR.

Both free-roam rungs put the headset in the player's *head*: a boom that
seats its wearer three cells behind their own body is a reliable way to make
people ill, so **3RD** in VR is **1ST** in VR. The rung still changes the
walk and the sprites the same way.

### VR controls

Suggested onto Touch, Index and WMR controllers (rebindable in the
runtime's own binding UI); pad, keyboard and mouse all keep working
alongside.

| control | does |
| --- | --- |
| left stick | move — grid-walks the diorama, free-walks 1ST |
| A / B (X / Y on the left hand) | A / B |
| either trigger | START |
| left stick click | step the VOXEL angle ladder (same as the "3" key) |
| right stick up / down | *diorama only* — zoom the model |
| right stick left / right | *1ST only* — snap-turn 45°, or turn smoothly with **SMOOTH TURN** on |
| grip squeeze + raise / lower that hand | *diorama only* — drag the table's height |
| head | *1ST and battles* — look; FreeMove walks where you look |
| left hand | *1ST and battles* — the Pokédex: menus, dialogs and the 2D battle screen on its screen |

## Licenses

This mod is released under the **MIT License** — see [`LICENSE`](LICENSE).

It redistributes one third-party binary:

- **`assets/vr/openxr_loader.dll`** — the Khronos OpenXR loader
  (version 1.0.10.2, x64, unmodified), © The Khronos Group Inc.,
  licensed under the **Apache License 2.0**. The full license text ships
  alongside the DLL at
  [`assets/vr/LICENSE-openxr_loader.txt`](assets/vr/LICENSE-openxr_loader.txt),
  as the license requires; keep the two files together if you
  redistribute this mod. Source:
  [KhronosGroup/OpenXR-SDK](https://github.com/KhronosGroup/OpenXR-SDK).

Everything else in this mod is original to it, except that the voxel
geometry and shape profiles are derived from the tile and sprite data of
the original game, as documented by the
[pret/pokered](https://github.com/pret/pokered) disassembly. No ROM
data, artwork or audio is included; the mod reads the assets the host
game already has.