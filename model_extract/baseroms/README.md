# Put the ROM here

`pipeline/build.py` looks for a Pokemon Stadium (US 1.0) ROM in this folder:

    model_extract/baseroms/baserom.z64

`.z64`, `.n64` and `.v64` byte orders are all accepted — the pipeline detects the
magic and normalises on load. Any ROM file dropped in this folder is picked up.

Expected md5 of the US 1.0 ROM: `ed1378bc12115f71209a77844965ba50`. A different
ROM still runs, but the build prints a warning since the offsets are keyed to
this revision.

Search order (first hit wins):

1. `model_extract/baseroms/baserom.z64`
2. `model_extract/baseroms/us/baserom.z64`
3. `baseroms/us/baserom.z64` at the repo root — the location `make init` uses
4. any `*.z64` / `*.n64` / `*.v64` in this folder

Or point at one explicitly:

    model_extract/pipeline/build.py --rom=/path/to/baserom.z64

The ROM is not included and is not tracked by git.
