import sys, os, struct, zlib, gzip, io, glob, collections, json
import nbtlib
# 1) claims per team, dim 0
claims={}
for fn in glob.glob("World/serverutilities/teams/claimedchunks/*.dat"):
    team=os.path.basename(fn)[:-4]
    d=nbtlib.load(fn); r=d if "ClaimedChunks" in d else d[""]
    lst=r["ClaimedChunks"].get("0",[])
    keys=collections.Counter(); xs=[]; zs=[]
    for c in lst:
        for k in c.keys(): keys[k]+=1
        claims[(int(c["x"]),int(c["z"]))]=(team, {k:int(v) for k,v in c.items() if k not in("x","z")})
        xs.append(int(c["x"])); zs.append(int(c["z"]))
    if lst: print(f"team {team:10s} dim0 claimed={len(lst)} keys={dict(keys)} bbox x={min(xs)}..{max(xs)} z={min(zs)}..{max(zs)}")
    else: print(f"team {team:10s} dim0 claimed=0")
# 2) scan dim 0 for interesting TEs
needles=["Reactor","Conduit","ogistics","ArcaneLamp","Poppet","Warded"]
hits={}
n=0
for fn in sorted(glob.glob("World/region/r.*.mca")):
    data=open(fn,"rb").read()
    if len(data)<8192: continue
    for idx in range(1024):
        off=struct.unpack(">I",b"\0"+data[idx*4:idx*4+3])[0]
        if off==0: continue
        p=off*4096
        if p+5>len(data): continue
        ln=struct.unpack(">I",data[p:p+4])[0]; ct=data[p+4]; raw=data[p+5:p+4+ln]
        try: blob=zlib.decompress(raw) if ct==2 else (gzip.decompress(raw) if ct==1 else raw)
        except Exception: continue
        n+=1
        if not any(x.encode() in blob for x in needles): continue
        try: root=nbtlib.File.parse(io.BytesIO(blob))
        except Exception: continue
        lvl=root.get("Level") or root.get("",{}).get("Level")
        if lvl is None: continue
        cx,cz=int(lvl["xPos"]),int(lvl["zPos"])
        cnt=collections.Counter()
        for t in lvl.get("TileEntities",[]):
            tid=str(t.get("id"))
            for x in needles:
                if x.lower() in tid.lower(): cnt[x]+=1
        if cnt: hits[(cx,cz)]=dict(cnt)
print(f"scanned {n} chunks; chunks with TEs of interest: {len(hits)}")
# 3) focus: the reactor base region (x -110..-90, z 325..350) + anything with Reactor
region=[(k,v) for k,v in hits.items() if (-112<=k[0]<=-88 and 322<=k[1]<=352)]
print(f"chunks of interest inside base bbox: {len(region)}")
unclaimed=[]; byteam=collections.Counter()
for (cx,cz),cnt in sorted(region):
    cl=claims.get((cx,cz))
    tag = f"{cl[0]} {cl[1]}" if cl else "UNCLAIMED"
    byteam[cl[0] if cl else "UNCLAIMED"]+=1
    if not cl: unclaimed.append(((cx,cz),cnt))
    print(f"  ({cx:5d},{cz:4d}) {tag:28s} {cnt}")
print("by team:",dict(byteam))
print("\nUNCLAIMED chunks with machinery in base bbox:",len(unclaimed))
for (c,cnt) in unclaimed: print("  ",c,"blocks x=%d..%d z=%d..%d"%(c[0]*16,c[0]*16+15,c[1]*16,c[1]*16+15),cnt)
# 4) outside bbox: any Reactor/Conduit chunk elsewhere that is unclaimed?
others=[(k,v) for k,v in hits.items() if not(-112<=k[0]<=-88 and 322<=k[1]<=352) and ("Reactor" in v or "Conduit" in v)]
print(f"\nReactor/Conduit chunks OUTSIDE base bbox: {len(others)}; unclaimed among them: {sum(1 for k,v in others if k not in claims)}")
for k,v in sorted(others)[:25]: print("  ",k, claims.get(k,("UNCLAIMED",))[0], v)
