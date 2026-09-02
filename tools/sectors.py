"""Region header sanity: sector overlaps, length > allocation, chunks > 1MB, sector count 255.
Usage: python3 tools/sectors.py <region.mca> ... (or a directory)
"""
import glob, os, struct, sys, collections

roots = sys.argv[1:]
files = []
for r in roots:
    files += sorted(glob.glob(os.path.join(r, "**", "region", "r.*.*.mca"), recursive=True))
    files += sorted(glob.glob(os.path.join(r, "region", "r.*.*.mca")))
files = sorted(set(files))

tot_overlap = tot_big = tot_clamp = tot_lenmismatch = 0
for path in files:
    size = os.path.getsize(path)
    if size < 8192: continue
    with open(path, "rb") as f: header = f.read(8192)
    total_sectors = size // 4096
    owner = {}
    overlaps, bigs, clamps, mism = [], [], [], []
    for i in range(1024):
        e = header[i*4:i*4+4]
        off = (e[0]<<16)|(e[1]<<8)|e[2]
        cnt = e[3]
        if off == 0: continue
        if cnt == 255: clamps.append(i)
        for s in range(off, off+cnt):
            if s in owner: overlaps.append((i, owner[s], s))
            else: owner[s] = i
        # declared payload length vs allocated sectors
        if off + 1 <= total_sectors:
            with open(path, "rb") as f:
                f.seek(off*4096); lb = f.read(4)
            if len(lb) == 4:
                (ln,) = struct.unpack(">I", lb)
                need = (ln + 4) // 4096 + 1
                if ln > 4096*cnt: mism.append((i, ln, cnt))
                if need > 255: bigs.append((i, ln, need))
    if overlaps or bigs or clamps or mism:
        print(f"### {path}  size={size} sectors={total_sectors}")
        if overlaps:
            seen = set()
            for a,b,s in overlaps:
                if (a,b) in seen: continue
                seen.add((a,b)); print(f"   OVERLAP idx {a} <-> idx {b} at sector {s}")
            tot_overlap += len(seen)
        for i,ln,cnt in mism: print(f"   LEN>ALLOC idx {i}: length={ln} allocated_sectors={cnt}"); 
        tot_lenmismatch += len(mism)
        for i,ln,need in bigs: print(f"   CHUNK>1MB idx {i}: length={ln} needs {need} sectors (byte max 255)")
        tot_big += len(bigs)
        if clamps: print(f"   SECTORCOUNT==255 at idx {clamps}")
        tot_clamp += len(clamps)
print(f"--- files={len(files)} overlaps={tot_overlap} len>alloc={tot_lenmismatch} chunks>1MB={tot_big} count255={tot_clamp}")
