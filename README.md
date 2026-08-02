# Dramatic Shape Voxel Mod

A mod for the [Pokémon Gen 1 Recompilation
Project](https://github.com/bryanthaboi/pokemon-gen1-recomp-project).

The overworld as a voxelized 3D diorama. Also supports experimental first-person and VR.

## Controls

Every key is free-roam only, and each one is also a row on the OPTIONS
menu.

| control | does |
| --- | --- |
| `3`, or the **VOXEL** options row | OFF → 15 → 35 → 50 → 75 → OFF (camera pitch) |
| `5`, or the **V-GRID** options row | OFF / ON — a one-pixel wireframe on every voxel |
| `6`, or the **T-SHIFT** options row | OFF → 1 → 2 → 3 → OFF (miniature blur) |
| `7`, or the **V-CURVE** options row | OFF → 1 → 2 → 3 — bend the world over the horizon |
| `8`, or the **3D-BTL** options row | ON / OFF — fight on the map instead of on a white field |
| `9`, or the **WATER** options row | FULL / SKY / OFF — waves and reflections on water. **SKY** gives the surface its pixel-tall wave columns and puts the sky, the sun, the moon and the cast in them; **FULL** adds a screen-space ray march that also reflects the shoreline, the trees and the buildings standing behind it |
| the **BACK SPRITES** options row | OFF / ON — keep your own Pokémon on the battle menu, seen from behind in its classic slot, instead of standing it on the map; the foe is still out there. Only on the menu while **3D-BTL** is on, because it decides nothing without it |
| the **AA** options row | OFF / 2X / 4X — smooth the stair-stepped edges of the 3D world by rendering the diorama larger than the window and folding it back down. The ladder is samples per display pixel: 2X is a canvas root-two wider and taller, 4X one exactly twice the size. Every edge in the projected picture softens with the silhouettes — the tileset's own texels are quads in a perspective view and cross the pixel grid at the same arbitrary angles — so the diorama reads smoother rather than sharper. The most expensive row in the mod, so it is OFF by default and **FULL** leaves it alone |
| the **DAYTIME** options row | SYNC / DAY / NIGHT / DUSK / DAWN / CYCLE — what time it is outdoors, on the diorama *and* on the flat 2D world; held at SYNC (and off the menu) while VOXEL is FULL |