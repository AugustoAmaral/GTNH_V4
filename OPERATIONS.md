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
  `gtnh backup` runs one manually. The inactive machine's timer no-ops.
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
  mid-claim: restore the lock with `git checkout -- state/active-host.json`.
- `--force` (start/takeover) requires typing the host id and notifies
  Discord. Use only when you are CERTAIN the other machine is not running
  the server. Never leave a `--force` prompt sitting unanswered in a
  terminal — a second start elsewhere during that window can split-brain.
- The peer probe trusts "port closed + peer reachable". A GTNH server takes
  minutes to bind the port while booting — if the peer might be mid-boot,
  wait or check it directly before confirming.

## Rollback the world to a specific commit (server STOPPED)

1. `gtnh stop` (on the active machine).
2. Find the commit: `git log --oneline | head -30` (hourly "Auto backup"
   commits). Prefer commits taken while the server was STOPPED (handover
   backups) — hot backups of a busy server can contain torn region writes.
3. Safety branch: `git branch backup/pre-rollback-$(date +%Y%m%d)`.
4. `git reset --hard <commit>`.
5. `git push --force-with-lease` (never plain --force).
6. `gtnh start`.

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
  the alert. Symptom: `restart.log` repeating "Starting server..." with
  crash count alternating 0/1. Action: `gtnh stop`, read `crash-reports/`.
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
   - Mac: `brew install mcrcon`, and `brew install coreutils` (provides
     gtimeout — without it, `gtnh stop`/RCON calls have NO timeout and can
     hang on a frozen JVM).
3. Schedule backups + maintenance:
   - Linux: `sudo cp deploy/gtnh-backup.* deploy/gtnh-maintenance.* /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now gtnh-backup.timer gtnh-maintenance.timer`
   - Mac: `sed "s|@SERVER_DIR@|$PWD|g" deploy/com.gtnh.backup.plist > ~/Library/LaunchAgents/com.gtnh.backup.plist && launchctl load -w ~/Library/LaunchAgents/com.gtnh.backup.plist` (repeat for `com.gtnh.maintenance.plist`).
4. mcrcon on Oracle: `git clone https://github.com/Tiiffi/mcrcon /tmp/mcrcon && make -C /tmp/mcrcon && sudo make -C /tmp/mcrcon install`.

### Mac-specific caveats

- The schedule units are LaunchAgents: they run only while you are logged
  in. That matches the server itself (screen dies at logout) — but it means
  commits made before a logout may stay unpushed until the next login.
- Sleep stops BOTH the server and the backups. When the Mac is the active
  host, keep it awake (`caffeinate -is` or Amphetamine).

## Security notes

- RCON (port 25575) has NO bind-address option in MC 1.7.10 — it listens on
  all interfaces. It must stay firewalled: on Oracle, the OCI security list
  and iptables must NOT open 25575; on the Mac, never port-forward it.
- DNS record TTL should stay at 60-120s (gtnh dns-update sets ttl=120).
- The legacy scripts (`run.sh`, `server-control*.sh`, `quick-control-*.sh`,
  `startserver*`) BYPASS the host lock entirely. They are kept only until
  the gtnh CLI is validated — do not use them, and remove them once Phase 1
  is signed off.
