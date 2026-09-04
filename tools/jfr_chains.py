import sys, re, collections
samples=[]; thread=None; frames=None; in_stack=False
for line in sys.stdin:
    line=line.rstrip("\n")
    if line.startswith("jdk.ExecutionSample"): thread=None; frames=[]; in_stack=False
    elif "sampledThread = " in line:
        m=re.search(r'sampledThread = "([^"]*)"', line); thread=m.group(1) if m else "?"
    elif line.strip().startswith("stackTrace = ["): in_stack=True
    elif in_stack and line.strip()=="]": in_stack=False
    elif in_stack: frames.append(re.sub(r"\s+line:.*$","",line.strip()).split("(")[0])
    elif line.strip()=="}" and thread is not None: samples.append((thread,frames)); thread=None
srv=[f for t,f in samples if t=="Server thread"]
N=len(srv)
targets=sys.argv[1:]
for tgt in targets:
    hits=[f for f in srv if any(tgt in fr for fr in f)]
    print(f"\n##### {tgt}: {len(hits)} samples ({100*len(hits)/N:.1f}%)")
    callers=collections.Counter()
    for f in hits:
        i=next(i for i,fr in enumerate(f) if tgt in fr)
        chain=" <- ".join(x.split(".")[-2]+"."+x.split(".")[-1] for x in f[i+1:i+7])
        callers[chain]+=1
    for c,n in callers.most_common(6): print(f"  {n:5d}  {c}")
# top collapsed stacks (frames from updateEntities down to leaf, shortened)
print("\n##### top collapsed stacks (leaf <- ... ) top 12")
col=collections.Counter()
for f in srv:
    short=[x.split(".")[-2]+"."+x.split(".")[-1] for x in f[:14]]
    col[" <- ".join(short)]+=1
for c,n in col.most_common(12): print(f"  {n:5d} ({100*n/N:4.1f}%)  {c}")
