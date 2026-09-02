# GTNH V4 — Operations Runbook

The CLI is `./gtnh` (run `./gtnh help`). Per-machine config lives in `.env`
(copy `.env.example`, chmod 600). `./gtnh doctor` tells you what is missing
on a machine.

## Daily flow

- The server runs on ONE machine at a time. `state/active-host.json` says
  which one (also shown by `gtnh status`).
- `gtnh status` — process, port, lock, TPS.
- `gtnh console` — attach to the screen console (Ctrl+A, D to detach).
- `gtnh cmd "say hi"` / `gtnh tps` — RCON.
- Backups: hourly commit+push via systemd timer (Oracle) / launchd (Mac).
  `gtnh backup` runs one manually. The timer no-ops on a machine whose lock
  names the OTHER host; while the lock is `none` (mid-handover) both
  machines' timers run — harmless on a clean tree.
- Server config changes go in `server.properties.template` (the live
  `server.properties` is rendered at start and is gitignored).
- Weekly `gtnh maintenance` (git gc) runs from its own timer; a 🔴 Discord
  alert means gc is failing and the repo will keep growing until fixed.

## Handover (active machine -> the other), both directions

On the ACTIVE machine:        `gtnh handover`
On the machine TAKING OVER:   `gtnh takeover`

`handover` = stop -> final backup -> release lock -> push -> Discord.
`takeover` = pull -> validate lock -> probe peer port 25565 -> claim lock ->
push (the claim only counts once PUBLISHED — nothing starts before it) ->
update DNS -> start -> Discord.

- If handover's push fails: the peer MUST NOT take over. Fix connectivity,
  re-run `gtnh handover` (idempotent — it just retries the publish).
- If takeover's push fails: the claim is rolled back and the server is NOT
  started. Re-run after connectivity returns.
- If takeover aborts on a dirty tree after a previous takeover died
  mid-claim: restore the lock with `git checkout HEAD -- state/active-host.json`
  (HEAD matters: the broken claim may be staged, and plain `checkout --`
  restores from the index, leaving you stuck).
- `--force` (start/takeover) requires typing the host id and notifies
  Discord. Use only when you are CERTAIN the other machine is not running
  the server. Never leave a `--force` prompt sitting unanswered in a
  terminal — a second start elsewhere during that window can split-brain.
- The peer probe trusts "port closed + peer reachable". A GTNH server takes
  minutes to bind the port while booting — if the peer might be mid-boot,
  wait or check it directly before confirming.

## Emergency: origin (GitHub) unreachable

`takeover` needs pull+push, and `start` refuses a `none` lock — so with
GitHub down nobody can claim. If you MUST start anyway (you have verified
the other machine yourself):
1. On the chosen machine: edit `state/active-host.json` to
   `{"active": "<this-host-id>", "since": "<now>", "released_clean": false}`.
2. `git add state/active-host.json && git commit -m "Manual claim (origin down)"`.
3. `gtnh start` (lock now says self).
4. When GitHub returns, `gtnh backup` publishes the claim with the next push.

## Rollback the world to a specific commit (server STOPPED)

1. `gtnh stop` (on the active machine).
2. Find the commit: `git log --oneline | head -30` (hourly "Auto backup"
   commits). Prefer commits taken while the server was STOPPED (handover
   backups). Commits tagged `[TORN:n]` in the message contain n chunks the
   game cannot load; any hot backup taken before 2026-09-02 may contain
   some too. ALWAYS run the scanner after a rollback (see "Torn chunks").
3. **Check what the target commit contains.** Commits older than the gtnh
   tooling (everything before mid-2026-06) do NOT contain `gtnh`, `state/`,
   `deploy/` or this runbook — a full reset to one of those erases the
   tooling from the working tree. For world-only rollback to an old commit,
   restore just the world instead of resetting:
   `git checkout <commit> -- World && git commit -m "Rollback World to <commit>"`
   and skip to step 7.
4. Safety branch: `git branch backup/pre-rollback-$(date +%Y%m%d-%H%M)`.
   Note it is local-only; after the weekly gc it may be the only thing
   keeping the discarded commits alive — push it if you want it safe:
   `git push origin backup/pre-rollback-<stamp>`.
5. `git reset --hard <commit>`.
6. `git push --force-with-lease` (never plain --force).
7. Restart via `gtnh takeover` (NOT plain `gtnh start`): the lock file now
   holds whatever the target commit said — possibly `none` or the other
   host — and `start` will refuse it. `takeover` re-claims, publishes the
   claim, probes the peer and fixes DNS in one go.
8. On the OTHER machine, the rewritten history will break its next
   `git pull --ff-only`: run `git fetch && git reset --hard origin/main`
   there (its tree is clean — it is the inactive host).

## Torn chunks (hot-save NBT corruption) — post-mortem 2026-09-02

**Symptom.** Server crash-loops right after `Done`, always at hh:01–hh:02, with
`NullPointerException ... Chunk.func_76594_o() because "p_147467_3_" is null`
at `WorldServer.func_147456_g:314`. Each crashed boot "fixes" one chunk by
regenerating it as fresh terrain (the crash save writes the new chunk over the
old one), so after N crashes the server boots — with N player chunks erased.

**Mechanism (verified, reproduced 2026-09-02).**
- `save-all flush` over RCON. 1.7.10 DOES honour `flush`: it drains the chunk
  write queue (`AnvilChunkLoader.writeNextIO`) on the command thread while
  the file-IO thread drains the same queue.
- Hodgepodge 2.7.x `speedupChunkCompression` (`MixinAnvilChunkLoader_FastChunkWrite`)
  keeps ONE NBT buffer per chunk loader with no synchronization. Two writers
  reset/write it concurrently -> a chunk record that is valid zlib + valid NBT
  but whose root is an inner fragment (`{Base}`, `{Amount}`, `{}` + junk...)
  with no `Level`. Before the 2026-08-12 modpack update (Hodgepodge 2.6.112)
  the same backup script never tore a chunk (scan of the 2026-08-11 snapshot: 0 bad).
- Forge 1.7.10 `ChunkProviderServer.loadChunk`: header says the chunk exists
  -> async path -> read fails -> `originalLoadChunk` generates a replacement
  into the map but **returns null** -> `provideChunk` null -> NPE in the tick.
- A torn chunk is harmless while it stays loaded (next autosave/unload rewrites
  it). It becomes permanent only if the server stops before that — which the
  hourly crash guaranteed. `stop` does NOT rewrite unmodified chunks.

**Guards now in place.** `gtnh backup` no longer sends `flush`; it waits until
no `.mca` changed for 10s (save-off stops autosave/unloads, so it settles) and
runs `tools/ScanRegions` on the staged region files. Bad chunks -> 🟠 Discord
alert + `[TORN:n]` in the commit message (still committed: history is what the
repair reads from). `config/hodgepodge.cfg` has `speedupChunkCompression=false`.

**Detect (any time, server running or not):**
```
javac -d tools/bin tools/ScanRegions.java
java -cp tools/bin ScanRegions World > /tmp/scan.txt; tail -1 /tmp/scan.txt   # BAD=0 is the goal
```
While the server runs, BAD>0 is only a problem if it persists across scans a
minute apart (loaded chunks self-heal).

**Repair (server STOPPED, ~10 min):**
```
gtnh stop
java -cp tools/bin ScanRegions World > /tmp/scan.txt
python3 tools/repair_chunks.py --scan /tmp/scan.txt            # dry-run: shows the commit each chunk comes from
python3 tools/repair_chunks.py --scan /tmp/scan.txt --apply
java -cp tools/bin ScanRegions World | tail -1                 # BAD=0
git add -A && git commit -m "Repair N torn chunks from history" && git push
gtnh start
```
After a rollback use `--base <the commit you rolled back to>` so the repair
does not pick chunks regenerated by crash boots (they scan as OK but are fresh
terrain). `tools/regen_detect.py <ref>` lists such chunks (InhabitedTime went down).

**Do not** edit `.mca` files while the server runs: `RegionFile` caches the
header in memory and will overwrite your change.

## When a backup fails

- Commit failed / oversized file: changes stay STAGED; the next hourly run
  retries naturally. Nothing is lost.
- Push failed (🟠 Discord alert): the commit is local; the next run pushes
  pending commits even when nothing new changed.
- `git add` failed (🔴 alert): backups are NOT happening — usually disk
  full. Fix immediately.
- Stale `.git/index.lock` is auto-removed when older than 30 minutes.
- If RCON breaks while the server is running (password changed, mcrcon
  gone), a backup may leave the world in `save-off`. The next hourly run
  normally self-heals it; if RCON is permanently broken, run `save-on` in
  the console (`gtnh console`) and fix RCON.
- After a forced start, if the lock does not name this host, the hourly
  backup silently skips (by design — it never commits a world it does not
  own). Check the lock line in `gtnh status` after any --force.

### Oversized staged file (>90MB alert)

GitHub rejects blobs over 100MB; a committed oversized blob breaks every
future push permanently. The backup aborts BEFORE committing. Then:
- Noise file (cache/dump): add it to `.gitignore`, `git rm --cached <file>`.
- World data: this is the long-term-strategy trigger — see below.

## Auto-restart and crashes

- The run-loop restarts the server on crash, max 5 crashes each within 5
  minutes of the previous one; then it gives up with a 🚨 Discord alert.
- Blind spot: a server that crashes AFTER a boot longer than 5 minutes
  resets the counter every cycle — restart-thrashing without ever tripping
  the alert. Symptom: `restart.log` repeating "Starting server..." with the
  crash count stuck at 1. Action: `gtnh stop`, read `crash-reports/`.
- An interrupted `gtnh stop` (Ctrl+C mid-way) can leave a stop sentinel
  behind; a later crash would then stop the loop silently instead of
  restarting. Re-run `gtnh stop` to completion, then `gtnh start`.
- `gtnh clear-crashes` clears the log only; a RUNNING loop keeps its
  in-memory counter.

## Long-term repo growth

`.git` was 50GB on 2026-06-11. Weekly `gtnh maintenance` (git gc) slows
growth but does not stop it. When clone/push pain gets real, pick one:
- **Truncate history**: archive everything to a `git bundle` stored OFF this
  machine, restart history from the current state, keep recent granularity.
- **Self-hosted remote** (no size limits): must NOT live on the machine that
  runs the server, or it stops being a backup against machine loss.

## New machine setup

1. Clone the repo, `cp .env.example .env`, fill it in, `chmod 600 .env`.
2. `./gtnh doctor` and install what it lists.
   - Oracle/Linux: `sudo apt install netcat-openbsd`; mcrcon: see below.
   - Mac: `brew install coreutils` (provides gtimeout — without it,
     `gtnh stop`/RCON calls have NO timeout and can hang on a frozen JVM).
   - Mac mcrcon: NOT in homebrew core anymore — build from source like on
     Oracle (step 4) and `cp /tmp/mcrcon/mcrcon /opt/homebrew/bin/` (no sudo
     needed, skip `make install`).
   - Mac java 21 without sudo (the zulu@21 cask runs a pkg installer that
     prompts for an admin password): `brew install openjdk@21 && ln -sfn
     /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk
     ~/Library/Java/JavaVirtualMachines/openjdk-21.jdk` — java_home scans
     the user-level JVM dir, which is all `gtnh` needs.
3. Schedule backups + maintenance:
   - Linux: `sudo cp deploy/gtnh-backup.* deploy/gtnh-maintenance.* /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now gtnh-backup.timer gtnh-maintenance.timer`
   - The systemd units hardcode `User=ubuntu` and `/home/ubuntu/GTNH_V4` —
     edit them before copying if this machine differs from the Oracle box.
   - Mac: From the repo root: `sed "s|@SERVER_DIR@|$PWD|g" deploy/com.gtnh.backup.plist > ~/Library/LaunchAgents/com.gtnh.backup.plist && launchctl load -w ~/Library/LaunchAgents/com.gtnh.backup.plist` (repeat for `com.gtnh.maintenance.plist`).
4. mcrcon on Oracle: `git clone https://github.com/Tiiffi/mcrcon /tmp/mcrcon && make -C /tmp/mcrcon && sudo make -C /tmp/mcrcon install`.

### Mac-specific caveats

- The schedule units are LaunchAgents: they run only while you are logged
  in. That matches the server itself (screen dies at logout) — but it means
  commits made before a logout may stay unpushed until the next login.
- Sleep stops BOTH the server and the backups. When the Mac is the active
  host, keep it awake — tie it to the run-loop so it self-clears on stop:
  `nohup caffeinate -is -w $(pgrep -f 'gtnh _run-loop') >/dev/null 2>&1 &`.
- The peer probe needs Tailscale RUNNING locally ("Tailscale is stopped" =
  every probe reports unreachable, even when the peer is fine). A relayed
  (DERP) pong counts as reachable — the probe passes `--until-direct=false`.

## Security notes

- RCON (port 25575) has NO bind-address option in MC 1.7.10 — it listens on
  all interfaces. It must stay firewalled: on Oracle, the OCI security list
  and iptables must NOT open 25575; on the Mac, never port-forward it.
- DNS record TTL should stay at 60-120s (gtnh dns-update sets ttl=120).
- The old per-OS scripts (`run*.sh`, `server-control*.sh`, `quick-control-*.sh`,
  `startserver*`, `autobackup.py`, ...) were removed once the gtnh CLI was
  validated — they bypassed the host lock. If you ever need a bare java
  launcher for emergency debugging, recover one from history:
  `git show <old-commit>:startserver-java9.sh`.
