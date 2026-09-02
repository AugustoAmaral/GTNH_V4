"""Find chunks that were regenerated as fresh terrain between a git ref and the working tree.

A chunk whose Level.InhabitedTime went DOWN, or whose TileEntities went from >0 to 0,
was almost certainly replaced by worldgen (crash-boot regeneration of an unloadable chunk).
Usage (repo root): python3 tools/regen_detect.py <old-ref>
Output lines: <path>\t<idx>\t(cx,cz)\tREGEN? ... ; PARSEFAIL old=False means the OLD blob had no Level.
"""
import sys, io, zlib, subprocess
import nbtlib
OLD = sys.argv[1]
files = subprocess.check_output(["git","diff","--name-only",OLD,"HEAD","--","World"]).decode().split()
files = [f for f in files if f.endswith(".mca")]
def chunks(data):
    out = {}
    for idx in range(1024):
        off = int.from_bytes(data[idx*4:idx*4+3],"big")
        if off == 0: continue
        s = off*4096
        if s+5 > len(data): out[idx] = None; continue
        ln = int.from_bytes(data[s:s+4],"big")
        if ln <= 0 or s+4+ln > len(data): out[idx] = None; continue
        out[idx] = data[s+5:s+4+ln]
    return out
def level(blob):
    try:
        t = nbtlib.File.parse(io.BytesIO(zlib.decompress(blob)))
        return t["Level"]
    except Exception:
        return None
tot = 0
for f in files:
    old = subprocess.run(["git","show",f"{OLD}:{f}"],capture_output=True).stdout
    new = open(f,"rb").read()
    oc = chunks(old) if old else {}; nc = chunks(new)
    for idx in sorted(set(oc)|set(nc)):
        ob, nb = oc.get(idx), nc.get(idx)
        if ob == nb: continue
        tot += 1
        if ob is None and nb is not None:
            print(f"{f}\t{idx}\tNEW-OR-OLD-UNREADABLE"); continue
        if nb is None:
            print(f"{f}\t{idx}\tNEW-UNREADABLE"); continue
        ol, nl = level(ob), level(nb)
        if ol is None or nl is None:
            print(f"{f}\t{idx}\tPARSEFAIL old={ol is not None} new={nl is not None}"); continue
        oi, ni = int(ol.get("InhabitedTime",0)), int(nl.get("InhabitedTime",0))
        ot, nt = len(ol.get("TileEntities",[])), len(nl.get("TileEntities",[]))
        oe, ne = len(ol.get("Entities",[])), len(nl.get("Entities",[]))
        if ni < oi or (ot > 0 and nt == 0):
            print(f"{f}\t{idx}\t({int(ol['xPos'])},{int(ol['zPos'])})\tREGEN? inhabited {oi}->{ni} tiles {ot}->{nt} ents {oe}->{ne}")
print(f"done files={len(files)} changed_chunks={tot}")
