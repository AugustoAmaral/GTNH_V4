# GTNH Dual-Host Control System — Phase 1 Design

**Date:** 2026-06-11
**Scope:** Phase 1 only — the `gtnh` CLI. Phase 2 (web panel, Bun + ElysiaJS) gets its own spec after Phase 1 is tested.
**Status:** Approved by Augusto (sections 1–4 reviewed interactively).

## Context

GTNH V4 server (Forge 1.7.10 + lwjgl3ify, Java 21) lives entirely in this git repo; commit history is the backup mechanism (intentional, must be preserved). The server runs alternately on two machines, never simultaneously:

- **Oracle**: Ubuntu ARM (aarch64), user `ubuntu`, `/home/ubuntu/GTNH_V4`, Java at `/usr/lib/jvm/java-21-openjdk-arm64/bin/java`. Current hostname is `network` — do not rely on hostnames for identity.
- **Mac**: macOS, Java via `/usr/libexec/java_home -v 21`.

Verified starting state (2026-06-11): server stopped on both machines, remote `main` == local HEAD (`45c817d`, last auto-backup 2026-02-28), working tree clean. Initial lock state is therefore `active: none`.

Current tooling being replaced: per-OS duplicated scripts (`run.sh`/`run-mac.sh`, `server-control.sh`/`server-control-mac.sh`, `quick-control-*.sh`) using `screen`, plus three legacy backup implementations (`autobackup.py` in a screen session, `backupAuto.js`, `autoBackup.sh`). Known pain points: manual host migration (stop → commit → push → pull → start + manual Cloudflare IP change), backup commits failing due to files being written during `git add` and orphaned `.git/index.lock`.

Missing tools on Oracle (install requires sudo, run by Claude with explicit per-block confirmation from Augusto): `tailscale`, `mcrcon`, `nc`. `jq`, `curl`, `git`, `screen`, `python3`, systemd are present. No `crontab` binary — systemd timers are the scheduling mechanism on Linux.

## Approach

Single-file bash CLI (`gtnh`) at the repo root, organized in function sections (env, process, rcon, backup, lock, dns, notify). `jq` for JSON. Rejected alternatives: modular bash (`lib/*.sh`) — marginal testability gain, diverges from the single-script requirement; Python CLI — native JSON/HTTP but adds a runtime to manage on the Mac, and the work is mostly process/screen/git orchestration where bash is more direct.

## Repo layout

```
gtnh                        # the CLI (bash, single file, repo root)
.env.example                # template for per-machine variables (versioned)
.env                        # per-machine secrets/config (gitignored)
state/active-host.json      # active-host lock (versioned)
server.properties.template  # versioned template; real file becomes untracked
deploy/
  gtnh-backup.service       # systemd oneshot (Linux)
  gtnh-backup.timer         # systemd hourly timer (Linux)
  com.gtnh.backup.plist     # launchd agent (Mac)
OPERATIONS.md               # runbook
docs/superpowers/specs/     # this spec
```

## Environment detection and config

Single detection block at the top of the script — zero machine-specific paths elsewhere:

- OS: `uname -s` (Darwin/Linux).
- `SERVER_DIR`: resolved from the script's own location (`dirname "$0"`), like the current mac scripts do.
- Java 21: Linux → `/usr/lib/jvm/java-21-openjdk-arm64/bin/java`; Darwin → `$(/usr/libexec/java_home -v 21)/bin/java`. Missing Java is a hard error with the install command in the message.
- Host identity: `HOST_ID` from `.env` (expected values `oracle`, `mac`), fallback `hostname -s` with a warning. Hostnames are not trusted (Oracle box is named `network`; Mac hostnames change with the network).
- `.env` loading: `set -a; . "$SERVER_DIR/.env"; set +a` if present.

`.env` variables: `HOST_ID`, `DISCORD_WEBHOOK_URL`, `RCON_PASSWORD`, `RCON_PORT` (default 25575), `CF_API_TOKEN`, `CF_ZONE_ID`, `CF_RECORD_ID`, `CF_RECORD_NAME`, `PEER_HOST` (tailnet IP or MagicDNS name of the other machine). `.env.example` documents each one.

## Process commands

Semantics preserved from the current scripts:

- `gtnh start` — validates the lock first (refuses if another host is active; see Lock section), refuses if a `gtnh` screen session or server java process already exists, renders `server.properties` from the template (see RCON section), then `screen -dmS gtnh ./gtnh _run-loop`.
- `gtnh _run-loop` (internal) — the auto-restart loop, absorbed from `run*.sh`: JVM flags preserved byte-for-byte (`-Xms6G -Xmx10G`, tuned G1GC set, `-Dfml.readTimeout=180`, `@java9args.txt`, `-jar lwjgl3ify-forgePatches.jar nogui`), crash counter max 5 within a 5-minute window, 10s pause between restarts, `restart.log` logging. When the counter blows out: Discord notification, loop exits.
- `gtnh stop` — graceful: `stop` via RCON, falling back to `screen -X stuff "stop\r"`; wait up to 30s; then SIGTERM the java process, 5s, SIGKILL; kill the runner loop to prevent ghost auto-restart; clean up the screen session; final verification.
- `gtnh kill` — immediate SIGKILL of runner + java, screen cleanup.
- `gtnh restart` — stop + start.
- `gtnh status` — process PID, screen session, port 25565 (`ss` on Linux / `lsof` on Mac), lock state (who is active, since when), TPS via RCON when the server is up, last `restart.log` lines.
- `gtnh logs` — tail of `restart.log` + `logs/latest.log`.
- `gtnh console` — `screen -r gtnh` with the usual detach warning.
- `gtnh clear-crashes` — resets the crash counter (removes `restart.log`).
- `gtnh doctor` — checks Java 21, `jq`, `mcrcon`, `nc`, `screen`, `.env` presence and required variables; prints exactly what is missing and how to install it per OS. Primary tool for bringing up the Mac side.

## RCON

- `gtnh cmd "<command>"` — runs an arbitrary console command via `mcrcon` against `127.0.0.1:$RCON_PORT`. `gtnh tps` is a shortcut for `forge tps`.
- **server.properties handling (deviation from the briefing, approved):** Minecraft rewrites `server.properties` on boot with `rcon.password` inside; the file is currently tracked, so hourly backups would commit the secret. Therefore: untrack `server.properties` (`git rm --cached` + gitignore), version `server.properties.template` containing `enable-rcon=true`, `rcon.port=@RCON_PORT@`, `rcon.password=@RCON_PASSWORD@` placeholders. `gtnh start` renders the template into `server.properties`, substituting values from `.env`. Server config changes are made in the template (documented in OPERATIONS.md).
- **Exposure:** MC 1.7.10 RCON has no bind-address setting — it listens on all interfaces. Mitigation is firewall + strong password: on Oracle, iptables and the OCI security list block inbound by default (verify 25575 is not open in either layer); on the Mac, NAT without port-forwarding for 25575. RCON is never exposed publicly.

## Backup (`gtnh backup`)

Replaces all three legacy backup implementations. Sequence:

1. **Ownership gate:** read the lock; if `active` is the *other* host, exit 0 silently. The inactive machine never commits the world — this makes it safe to leave the timer enabled on both machines.
2. Remove `.git/index.lock` older than 30 minutes (after checking no live git process owns it).
3. If the server is running: `save-off` → `save-all flush` → sleep 15s, via RCON. A `trap ... EXIT` guarantees `save-on` always runs — on commit failure, Ctrl+C, or script error. If the server is not running, skip the RCON part entirely.
4. `git add -A`; if nothing is staged → exit silently, no empty commit.
5. `git commit -m "Auto backup - <ISO timestamp>"`. On failure: Discord notification, exit 1 (trap has already restored `save-on`); changes remain staged and the next run picks them up naturally (recovery semantics documented in OPERATIONS.md).
6. **Push on every backup** (preserves current behavior; protects against machine loss and keeps the remote fresh for takeover). Push failure is non-fatal: Discord notification, non-zero exit, natural retry next hour.
7. `lastUpdate.txt` is retired: no longer appended (commit timestamps carry that information) and removed from tracking.

**Scheduling** — no screen sessions: Linux → `deploy/gtnh-backup.timer` (hourly, `Persistent=true`) triggering `deploy/gtnh-backup.service` (oneshot, `User=ubuntu`, runs `gtnh backup`); Mac → `deploy/com.gtnh.backup.plist` LaunchAgent with `StartInterval=3600`. Install commands documented in OPERATIONS.md; Linux install is part of the sudo provisioning block.

## .gitignore and tracking cleanup

Add: `.env`, `crash-reports/`, `*.log` (covers `gc.log*`, `.healer.log`, `minetweaker.log`), `.DS_Store`, `*.hprof`, `hs_err_pid*`, `lastUpdate.txt`. Keep existing entries.

Already-tracked noise requires `git rm --cached` (files stay on disk and in history) in a dedicated, revertible commit: `gc.log`, `gc.log.0`, `gc.log.1`, `.healer.log`, `minetweaker.log`, `.DS_Store`, `lastUpdate.txt`, `chunk_report.txt`. `server.properties` is also untracked, but in rollout step 3, together with its template (per the RCON section).

## Lock and handover/takeover

`state/active-host.json`, written via `jq`, committed to the repo:

```json
{ "active": "oracle" | "mac" | "none", "since": "<ISO-8601>", "released_clean": true | false }
```

While a host runs the server: `active=<host>, released_clean=false`. Only a clean handover sets `none + true`. Initial state (committed in Phase 1): `none + true` — verified that the server is stopped on both machines.

**`gtnh handover`** (on the active machine):
1. Graceful stop.
2. Final `gtnh backup` — **if the commit fails, handover aborts**: the lock is never released with an uncommitted world.
3. Write `active: none, released_clean: true` → commit → push.
4. Discord: "🔓 server released by `<host>`".
5. **If the push fails:** prominent terminal error stating the other machine must NOT take over yet, best-effort Discord notification, exit 1. Re-running `gtnh handover` is idempotent (server already stopped, backup is a no-op, it just retries the push).

**`gtnh takeover`** (on the machine assuming the server), in order:
1. Working tree must be clean — dirty tree on an inactive machine is an anomaly to resolve manually; abort.
2. `git pull --ff-only`; divergence → abort with instructions.
3. Lock validation: `active` must be `none` or self (re-takeover is idempotent). If `released_clean=false` (previous owner died without releasing), require `--force`.
4. **Anti-split-brain probe:** `nc -z -w 5 $PEER_HOST 25565`; if the port answers, abort even when the lock says `none`. If `nc` or `PEER_HOST` is unavailable, print a prominent warning and continue (documented limitation).
5. Claim: write `active=<self>, since=now, released_clean=false` → commit → **push, which must succeed before any side effect**. The lock only counts once published. On push failure: remove the local claim commit, restore the previous lock JSON, do NOT start the server, clear error message.
6. `gtnh dns-update` — DNS failure does not block the start (players just resolve the old IP until fixed): warning + Discord, continue.
7. `gtnh start` + Discord "🟢 takeover completed by `<host>`".

**`gtnh start` lock enforcement:** every start validates the lock and refuses with a clear message if another host is active. `--force` (on `start` and `takeover`) requires interactively typing the host name to confirm, and sends "⚠️ FORCED start on `<host>`" to Discord.

## DNS (`gtnh dns-update [--dry-run]`)

- Public IP via `curl https://api.ipify.org` (fallback `ifconfig.me`).
- GET the current A record via Cloudflare API (`CF_API_TOKEN`, `CF_ZONE_ID`, `CF_RECORD_ID`); **PUT only when the IP changed**.
- Log the result; Discord notification on change.
- `--dry-run` prints what would happen without calling the PUT.
- OPERATIONS.md/README note: keep record TTL at 60–120s to minimize the propagation window.
- Called automatically by `takeover`; also available standalone.

## Discord notifications

Single `notify()` function: message format `<emoji> [host] text`, `curl` POST to `DISCORD_WEBHOOK_URL` with 10s timeout, always best-effort (`|| true` — a notification never fails the calling operation), silent skip when the webhook is unset. Used by: backup (failures only), handover, takeover, dns-update (changes/failures), crash-loop blowout, manual start/stop.

## Error handling principles

- Every external call has a timeout: curl 10s, nc 5s, RCON 10s.
- `set -u` plus explicit error checks instead of blanket `set -e` (failure paths are flow control here).
- Traps guarantee `save-on`.
- Lock operations are commit→push with abort-before-side-effects.
- Missing tool (mcrcon, nc, jq) → message naming the exact install command; never a silent failure.

## Testing (all without a running server)

- `shellcheck` on the whole script.
- Lock validation exposed as an internal testable subcommand (`gtnh _lock-check <json>`), exercised against the four states: none / self / other / `released_clean=false`.
- OS/Java detection via `gtnh status` and `gtnh doctor`.
- `gtnh dns-update --dry-run` with the real `.env`.
- Real `gtnh backup` with the server stopped (a commit is harmless — it is the backup mechanism).
- Discord notify test fire only with Augusto's explicit OK (external write).

## Rollout (small incremental commits, in order)

1. `.gitignore` + untrack noise files (dedicated commit).
2. `gtnh` CLI + `.env.example` + initial `state/active-host.json` (`none`).
3. `server.properties.template` + untrack `server.properties`.
4. `deploy/` units (systemd + launchd).
5. `OPERATIONS.md` (daily flow, handover both directions, world rollback to a specific commit with the server stopped, backup-failure runbook).
6. Oracle provisioning, each sudo block with explicit confirmation: `netcat-openbsd`, `mcrcon` (source build or binary), `tailscale` (install + interactive `tailscale up` done by Augusto).
7. Mac side (by Augusto): `git pull`, create `.env`, `gtnh doctor` lists what is missing (`brew install mcrcon` etc.), install the LaunchAgent.

## Legacy and security cleanup

- Old scripts (`run*.sh`, `server-control*.sh`, `quick-control-*.sh`, `autobackup.py`, `autoBackup.sh`, `backupAuto.js`) remain untouched until Phase 1 is tested; removal only after explicit approval.
- **Security finding:** `upload_world.sh` contains a plaintext SFTP password (sshpass against reis.host), committed and present in git history. Proposal: remove the file during rollout; Augusto rotates the credential on reis.host if that service still exists. Pending confirmation at spec review.

## Out of scope

Phase 2 (web panel: Bun + ElysiaJS in `panel/`, Tailscale-bound, wrapping this CLI). The CLI is designed with clean, parseable outputs so the panel can shell out to it.
