#!/usr/bin/env python3
"""Re-apply this server's deliberate config deviations on top of a fresh pack config.

Each replacement must match exactly once; any miss aborts before writing anything.
Run from the GTNH_V4 root after the pack copy. Reads the pre-update forgeChunkLoading
blocks from the cold backup dir given as argv[1].
"""
import re
import sys
from pathlib import Path

backup = Path(sys.argv[1])

# (file, regex, replacement)
EDITS = [
    ("config/hodgepodge.cfg", r"(\n\s*B:speedupChunkCompression=)true\n", r"\1false\n"),
    ("config/hodgepodge.cfg", r"(\n\s*I:autoSaveInterval=)900\n", r"\g<1>6000\n"),
    ("config/GregTech/Pollution.cfg", r'(\n\s*B:"Activate Pollution"=)true\n', r"\1false\n"),
    ("config/ae2fc.cfg", r"(\n\s*I:maxTick=)120\n", r"\g<1>600\n"),
    ("config/ThaumicExploration.cfg", r'(\n\s*B:"Enable Soul Brazier Chunkloading"=)true\n', r"\1false\n"),
    # First list only (allowedblocks); the same line repeats in later blocks.
    ("config/personalspace.cfg",
     r"(\nallowedblocks \{\n(?:(?!\}).*\n)*?(\s*)chisel:factoryblock2:0-3\n)",
     r"\1\2chisel:nucrete:0-15\n"),
]

texts = {}
for f, pat, rep in EDITS:
    text = texts.get(f) or Path(f).read_text()
    new, n = re.subn(pat, rep, text)
    if n != 1:
        sys.exit(f"ABORT: {f}: pattern {pat!r} matched {n} times")
    texts[f] = new

# forgeChunkLoading: append the witchery + ThaumicExploration blocks verbatim from the old file.
fcl = "config/forgeChunkLoading.cfg"
old = (backup / fcl).read_text()
blocks = []
for mod in ("witchery", "ThaumicExploration"):
    m = re.search(r"(?m)^%s \{\n(?:.*\n)*?\}\n" % re.escape(mod), old)
    if not m:
        sys.exit(f"ABORT: block {mod} not found in backup {fcl}")
    blocks.append(m.group(0))
cur = Path(fcl).read_text()
for mod in ("witchery", "ThaumicExploration"):
    if re.search(r"(?m)^%s \{" % re.escape(mod), cur):
        sys.exit(f"ABORT: pack {fcl} already has a {mod} block; merge by hand")
texts[fcl] = cur.rstrip("\n") + "\n\n\n" + "\n\n".join(b.rstrip("\n") for b in blocks) + "\n\n\n"

for f, t in texts.items():
    Path(f).write_text(t)
    print(f"written {f}")
