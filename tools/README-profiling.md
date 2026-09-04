# Server-thread profiling (added 2026-09-04)

Used to diagnose the "20 s stall every ~60 s" lag (see OPERATIONS.md, "Periodic stalls / chunk unload-reload loop").

- `jfr_agg.py` — aggregate a JFR recording by leaf frame, inclusive frame and first non-vanilla ("mod") frame for the Server thread.
  ```
  jcmd <pid> JFR.start name=lag duration=90s filename=/tmp/lag.jfr settings=profile
  jfr print --events jdk.ExecutionSample --stack-depth 48 /tmp/lag.jfr | python3 tools/jfr_agg.py
  ```
- `jfr_chains.py <frame-substring>...` — for each target frame, histogram of its callers (6 frames below) + top collapsed stacks.
  ```
  jfr print --events jdk.ExecutionSample --stack-depth 64 /tmp/lag.jfr | python3 tools/jfr_chains.py TileConduitBundle.onChunkUnload ChunkProviderServer.func_73154_d
  ```
- `find_tiles.py <region-dir> <needle>...` — list chunks whose tile entities match the needles (IC2 ids are human names: "Nuclear Reactor", "Reactor Chamber"). ~25 s for 65k chunks.
- `claims_intersect.py` — cross ServerUtilities claimed chunks (dim 0) with chunks holding reactors/conduits/arcane lamps; prints claim owner + `loaded` flag per chunk. Run from the repo root.

Quick A/B for "is it the save/unload cycle?": `gtnh cmd save-off` for ~3 min (disables autosave AND unloadQueuedChunks in 1.7.10), watch `Can't keep up` and `forge tps`, then `gtnh cmd save-on`.
