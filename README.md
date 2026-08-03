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

On **3RD** the boom shortens against whatever is behind you, so backing into
a wall walks the camera in to your shoulders rather than through it — squeeze
it all the way in and the view is 1ST until you step clear. The character
turns to face where they are walking, and every sprite in the world — yours,
the NPCs', the figures drawn into the furniture — turns to face the camera
and shows the frame it would look like from where the camera actually
stands, so walking behind someone shows you their back.

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
| right stick left / right | *1ST only* — snap-turn 45° |
| grip squeeze + raise / lower that hand | *diorama only* — drag the table's height |
| head | *1ST and battles* — look; FreeMove walks where you look |
| left hand | *1ST and battles* — the Pokédex: menus, dialogs and the 2D battle screen on its screen |

## Licenses

This mod redistributes one third-party binary:

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