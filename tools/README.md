# tools/ — region-file forensics and repair (MC 1.7.10 Anvil)

Written during the 2026-09-01/02 crash-loop post-mortem (see OPERATIONS.md, "Torn chunks").

| Tool | What |
|---|---|
| `ScanRegions.java` | Strict scanner replicating the game's chunk load path. `java -cp tools/bin ScanRegions World` (full), `... files < list` (given .mca files), `... check < "path idx"` (single chunks). Compiled on demand into `tools/bin/` by `gtnh backup` and `repair_chunks.py`. |
| `repair_chunks.py` | Restore broken chunks from git history, one chunk at a time (server STOPPED). |
| `regen_detect.py` | Find chunks silently regenerated as fresh terrain between a ref and the working tree. |
| `levelcheck.py`, `sectors.py`, `dump.py` | Small inspection helpers (nbtlib needed for levelcheck). |

Never trust nbtlib alone to say a chunk is fine: it decodes with errors="replace" and never raises on short byte arrays.
