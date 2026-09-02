"""Print root keys / Level keys / Sections / xPos / zPos of specific chunks (nbtlib, lenient).
Usage: python3 tools/levelcheck.py <region.mca>:<idx> ...
"""
import io, struct, sys, zlib
import nbtlib

def read(path, idx):
    raw = open(path, "rb").read()
    e = raw[idx*4:idx*4+4]
    off = (e[0] << 16) | (e[1] << 8) | e[2]
    cnt = e[3]
    s = off * 4096
    (ln,) = struct.unpack(">I", raw[s:s+4])
    data = zlib.decompress(raw[s+5:s+5+ln-1])
    nbt = nbtlib.File.from_fileobj(io.BytesIO(data))
    root = nbt if "Level" in nbt else nbt.get("", nbt)
    keys = list(root.keys())
    has_level = "Level" in root
    info = "root_keys=%s" % keys[:6]
    if has_level:
        lvl = root["Level"]
        info += " level_keys=%s" % [k for k in list(lvl.keys())[:12]]
        info += " Sections=%s xPos=%s zPos=%s" % (
            "Sections" in lvl, lvl.get("xPos"), lvl.get("zPos"))
    print("%s idx=%d off=%d sectors=%d len=%d -> Level=%s | %s" % (
        path.split("/")[-1], idx, off, cnt, ln, has_level, info))

for spec in sys.argv[1:]:
    p, i = spec.rsplit(":", 1)
    try:
        read(p, int(i))
    except Exception as ex:
        print("%s idx=%s -> ERROR %s: %s" % (p, i, type(ex).__name__, ex))
