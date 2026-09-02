#!/usr/bin/env python3
"""Surgical per-chunk repair for MC 1.7.10 Anvil region files from git history.

Input: a scan report from ScanRegions (lines "BAD\t<path>\t<idx>\t(cx,cz)\t<err>").
For each broken chunk, walk the git history of its region file newest->oldest
starting at --base and pick the first revision where that chunk loads under the
REAL Java reader (ScanRegions check: RegionFile gates + strict NBT + Level/Sections),
then splice only that chunk back in (appended at the end of the file, header
entry repointed). Existing sectors are never overwritten.

Usage (repo root, server STOPPED):
    java -cp tools/bin ScanRegions World > /tmp/scan.txt
    python3 tools/repair_chunks.py --scan /tmp/scan.txt [--base <ref>]          # dry-run
    python3 tools/repair_chunks.py --scan /tmp/scan.txt [--base <ref>] --apply
--base: newest commit to consider (default HEAD). Use the commit you rolled the
world back to when the current HEAD carries fresh-regenerated chunks.

Why not nbtlib for validation: it decodes strings with errors="replace" and
never raises on short byte arrays, so it reports torn chunks as clean.
"""
import collections
import io
import os
import struct
import subprocess
import sys
import zlib

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
JAVA_CP = os.path.join(TOOLS, "bin")
WORK = "/tmp/gtnh-repair-blobs"
MAX_COMMITS = 120


def arg(name, default=None):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


BASE_REF = arg("--base", "HEAD")
SCAN_FILE = arg("--scan")
if not SCAN_FILE:
    sys.exit("usage: repair_chunks.py --scan <ScanRegions output> [--base <ref>] [--apply]")


def ensure_scanner():
    cls = os.path.join(JAVA_CP, "ScanRegions.class")
    src = os.path.join(TOOLS, "ScanRegions.java")
    if not os.path.exists(cls) or os.path.getmtime(src) > os.path.getmtime(cls):
        os.makedirs(JAVA_CP, exist_ok=True)
        subprocess.run(["javac", "-d", JAVA_CP, src], check=True)


def sh(args):
    return subprocess.run(args, cwd=REPO, capture_output=True)


def java_check(pairs):
    spec = "".join("%s %d\n" % (p, i) for p, i in pairs)
    r = subprocess.run(["java", "-cp", JAVA_CP, "ScanRegions", "check"],
                       input=spec, capture_output=True, text=True)
    out = {}
    for line in r.stdout.splitlines():
        if not line.strip():
            continue
        left, res = line.rsplit("\t", 1)
        p, i = left.rsplit(" ", 1)
        out[(p, int(i))] = res
    return out


def chunk_coords(region_path, idx):
    import nbtlib
    raw = open(region_path, "rb").read()
    e = raw[idx * 4:idx * 4 + 4]
    off = (e[0] << 16) | (e[1] << 8) | e[2]
    s = off * 4096
    (ln,) = struct.unpack(">I", raw[s:s + 4])
    data = zlib.decompress(raw[s + 5:s + 5 + ln - 1])
    nbt = nbtlib.File.from_fileobj(io.BytesIO(data))
    root = nbt if "Level" in nbt else nbt[""]
    lvl = root["Level"]
    return int(lvl["xPos"]), int(lvl["zPos"])


def extract_blob(region_bytes, idx):
    e = region_bytes[idx * 4:idx * 4 + 4]
    off = (e[0] << 16) | (e[1] << 8) | e[2]
    if off == 0:
        return None
    s = off * 4096
    (ln,) = struct.unpack(">I", region_bytes[s:s + 4])
    return bytes(region_bytes[s:s + 4 + ln])


def main():
    apply_it = "--apply" in sys.argv
    ensure_scanner()
    targets = collections.defaultdict(list)
    for line in open(SCAN_FILE):
        if not line.startswith("BAD\t"):
            continue
        _, path, idx, coords, err = line.rstrip("\n").split("\t", 4)
        path = os.path.relpath(os.path.abspath(path) if os.path.isabs(path) else os.path.join(REPO, path), REPO)
        targets[path].append((int(idx), coords, err))

    os.makedirs(WORK, exist_ok=True)
    plan = []
    for relpath, items in sorted(targets.items()):
        commits = sh(["git", "log", BASE_REF, "-n", str(MAX_COMMITS), "--pretty=%H %ad",
                      "--date=format:%m-%d %H:%M", "--", relpath]).stdout.decode().splitlines()
        print("\n### %s: %d commits, %d broken chunks" % (relpath, len(commits), len(items)))
        revs = []
        for line in commits:
            c, when = line.split(" ", 1)
            bp = "%s/%s.%s.mca" % (WORK, relpath.replace("/", "_"), c[:10])
            if not os.path.exists(bp):
                r = sh(["git", "show", "%s:%s" % (c, relpath)])
                if r.returncode != 0:
                    continue
                open(bp, "wb").write(r.stdout)
            revs.append((c, when, bp))
        results = java_check([(bp, idx) for _, _, bp in revs for idx, _, _ in items])
        for idx, coords, err in items:
            hit = None
            for c, when, bp in revs:
                if results.get((bp, idx)) != "OK":
                    continue
                try:
                    cx, cz = chunk_coords(bp, idx)
                except Exception as ex:
                    print("    idx %d: %s parses but coords unreadable (%s)" % (idx, c[:10], ex))
                    continue
                want = [int(v) for v in coords.strip("()").split(",")]
                if [cx, cz] != want:
                    print("    idx %d: %s holds (%d,%d) != %s - skipping" % (idx, c[:10], cx, cz, coords))
                    continue
                hit = (c, when, bp)
                break
            if hit:
                print("    idx %-4d %-12s OK at %s (%s)   [was: %s]" % (idx, coords, hit[0][:10], hit[1], err[:55]))
                plan.append((relpath, idx, coords, hit[2], hit[0]))
            else:
                print("    idx %-4d %-12s *** NO GOOD REVISION in %d commits ***" % (idx, coords, len(revs)))

    if not apply_it:
        print("\n=== dry-run: %d chunks repairable ===" % len(plan))
        return

    by_file = collections.defaultdict(list)
    for relpath, idx, coords, bp, c in plan:
        by_file[relpath].append((idx, coords, bp, c))
    for relpath, items in by_file.items():
        target = os.path.join(REPO, relpath)
        buf = bytearray(open(target, "rb").read())
        assert len(buf) % 4096 == 0, "%s not sector aligned" % relpath
        header = bytearray(buf[:8192])
        for idx, coords, bp, c in items:
            blob = extract_blob(open(bp, "rb").read(), idx)
            need = (len(blob) + 4095) // 4096
            if need > 255:
                print("    !! idx %d needs %d sectors (>255) - REFUSING" % (idx, need))
                continue
            new_off = len(buf) // 4096
            buf.extend(blob + b"\x00" * (need * 4096 - len(blob)))
            he = idx * 4
            header[he] = (new_off >> 16) & 0xFF
            header[he + 1] = (new_off >> 8) & 0xFF
            header[he + 2] = new_off & 0xFF
            header[he + 3] = need
            print("    patched idx %d %s from %s -> sector %d x%d" % (idx, coords, c[:10], new_off, need))
        buf[:8192] = header
        open(target, "wb").write(buf)
        print("=== wrote %s (%d bytes) ===" % (relpath, len(buf)))


main()
