import sys, os, struct, zlib, gzip, io, glob, collections
import nbtlib
region_dir=sys.argv[1]; needles=sys.argv[2:]
files=sorted(glob.glob(os.path.join(region_dir,"r.*.mca")))
nchunks=0; per_needle_chunks=collections.Counter(); hits={}
for fn in files:
    with open(fn,"rb") as f: data=f.read()
    if len(data)<8192: continue
    for idx in range(1024):
        off=struct.unpack(">I",b"\0"+data[idx*4:idx*4+3])[0]
        if off==0: continue
        p=off*4096
        if p+5>len(data): continue
        ln=struct.unpack(">I",data[p:p+4])[0]; ct=data[p+4]; raw=data[p+5:p+4+ln]
        try: blob = zlib.decompress(raw) if ct==2 else (gzip.decompress(raw) if ct==1 else raw)
        except Exception: continue
        nchunks+=1
        present=[n for n in needles if n.encode() in blob]
        if not present: continue
        try: root=nbtlib.File.parse(io.BytesIO(blob))
        except Exception as e: continue
        lvl=root.get("Level") or root.get("",{}).get("Level")
        if lvl is None: continue
        cx,cz=int(lvl["xPos"]),int(lvl["zPos"])
        tes=lvl.get("TileEntities",[])
        cnt=collections.Counter()
        pos=collections.defaultdict(list)
        for t in tes:
            tid=str(t.get("id"))
            for n in needles:
                if n.lower() in tid.lower():
                    cnt[n]+=1
                    if len(pos[n])<3: pos[n].append((tid,int(t["x"]),int(t["y"]),int(t["z"])))
        if cnt:
            hits[(cx,cz)]=(dict(cnt),dict(pos),len(tes))
            for n in cnt: per_needle_chunks[n]+=1
print(f"{region_dir}: scanned {nchunks} chunks; chunks-with: {dict(per_needle_chunks)}")
key=needles[0]
for (cx,cz),(cnt,pos,ntes) in sorted(hits.items()):
    if key in cnt:
        print(f"  chunk ({cx},{cz}) blocks x={cx*16}..{cx*16+15} z={cz*16}..{cz*16+15} TEs={ntes} {cnt} sample={pos.get(key)}")
