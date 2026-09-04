import sys, re, collections
# parse `jfr print --events jdk.ExecutionSample` text output
samples = []  # (thread, [frames top->bottom])
thread = None; frames = None; in_stack = False
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("jdk.ExecutionSample"):
        thread = None; frames = []; in_stack = False
    elif "sampledThread = " in line:
        m = re.search(r'sampledThread = "([^"]*)"', line); thread = m.group(1) if m else "?"
    elif line.strip().startswith("stackTrace = ["):
        in_stack = True
    elif in_stack and line.strip() == "]":
        in_stack = False
    elif in_stack:
        f = line.strip()
        f = re.sub(r"\s+line:.*$", "", f)
        frames.append(f)
    elif line.strip() == "}" and thread is not None:
        samples.append((thread, frames)); thread = None
srv = [f for t, f in samples if t == "Server thread"]
print(f"total samples={len(samples)} server-thread samples={len(srv)}")
bythread = collections.Counter(t for t, _ in samples)
print("samples per thread (top 8):")
for t, c in bythread.most_common(8): print(f"  {c:6d} {t}")
leaf = collections.Counter(f[0] for f in srv if f)
print("\n== Server thread: LEAF frames top 25 ==")
for f, c in leaf.most_common(25): print(f"  {c:6d} {100*c/len(srv):5.1f}%  {f}")
incl = collections.Counter()
for f in srv:
    for fr in set(f): incl[fr] += 1
print("\n== Server thread: INCLUSIVE frames top 45 (frame present anywhere in stack) ==")
for f, c in incl.most_common(45): print(f"  {c:6d} {100*c/len(srv):5.1f}%  {f}")
# attribute to first non-vanilla/non-jdk frame from the top (the 'mod' frame)
def mod_of(frames):
    for fr in frames:
        if not re.match(r"(net\.minecraft|java\.|jdk\.|sun\.|cpw\.mods|net\.minecraftforge|com\.google|org\.apache)", fr):
            return fr.split("(")[0]
    return "<vanilla/jdk only>"
modc = collections.Counter(mod_of(f) for f in srv)
print("\n== Server thread: first NON-vanilla frame from top (mod attribution) top 30 ==")
for f, c in modc.most_common(30): print(f"  {c:6d} {100*c/len(srv):5.1f}%  {f}")
pkg = collections.Counter()
for f in srv:
    p = mod_of(f); pkg[".".join(p.split(".")[:2])] += 1
print("\n== by top-level package ==")
for f, c in pkg.most_common(20): print(f"  {c:6d} {100*c/len(srv):5.1f}%  {f}")
