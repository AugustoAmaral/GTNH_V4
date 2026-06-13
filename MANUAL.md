# GTNH V4 — User Manual

Everything is driven by one script at the repo root: **`./gtnh`**. You never
touch `screen`, `git` or Cloudflare by hand for routine operation. This is
the friendly guide; the deep runbook (failure recovery, rollback, emergencies)
lives in [OPERATIONS.md](OPERATIONS.md).

## The mental model (30 seconds)

- The whole server lives in this git repo. **Hourly commits are the backup.**
- The server runs on ONE machine at a time (Oracle or the Mac). A small file,
  `state/active-host.json`, is the **lock** that says who owns it. Every
  command checks it; you move the server between machines with
  `handover`/`takeover`, never by hand.
- Secrets (RCON password, Cloudflare token, Discord webhook) live in `.env`,
  which is gitignored and unique per machine.

## One-time setup on a machine

```
cp .env.example .env && chmod 600 .env   # then fill it in (see below)
./gtnh doctor                            # tells you everything that's missing
```

What each `.env` field is for:

| Field | What it does | Where to get it |
|---|---|---|
| `HOST_ID` | This machine's name in the lock: `oracle` or `mac` | you decide, keep it consistent |
| `DISCORD_WEBHOOK_URL` | Where notifications go (empty = no notifications) | Discord channel → Integrations → Webhooks |
| `RCON_PASSWORD` | Console access for the CLI. **Required to start the server.** No `\| & \` characters | invent a strong one |
| `RCON_PORT` | Leave 25575 | — |
| `CF_API_TOKEN` / `CF_ZONE_ID` / `CF_RECORD_ID` / `CF_RECORD_NAME` | Lets `takeover` repoint the DNS A record to this machine | Cloudflare dashboard → API tokens / zone overview / record |
| `PEER_HOST` | The OTHER machine's tailnet IP or MagicDNS name — used to detect split-brain before takeover | `tailscale status` on either machine |

Schedule the automatic backups (per machine, once):

- **Linux**: `sudo cp deploy/gtnh-backup.* deploy/gtnh-maintenance.* /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now gtnh-backup.timer gtnh-maintenance.timer`
- **Mac** (from the repo root): `sed "s|@SERVER_DIR@|$PWD|g" deploy/com.gtnh.backup.plist > ~/Library/LaunchAgents/com.gtnh.backup.plist && launchctl load -w ~/Library/LaunchAgents/com.gtnh.backup.plist` — repeat for `com.gtnh.maintenance.plist`. Also `brew install mcrcon coreutils`.

## About server.properties (read this once)

You will notice the live `server.properties` has `enable-rcon=false` and no
rcon lines. **That is normal.** The real config is
`server.properties.template` (versioned); every `gtnh start` regenerates the
live file from it, injecting your RCON password from `.env`. That is how the
password stays out of git.

- Want to change a server setting (motd, view-distance, etc.)? **Edit the
  TEMPLATE**, not the live file — live-file edits are overwritten on the next
  start.
- RCON not enabled yet? It will be, automatically, on your first
  `gtnh start`/`takeover` — as long as `RCON_PASSWORD` is filled in `.env`.

## Everyday commands

| Command | What it does |
|---|---|
| `./gtnh status` | Is it running? Port open? Who holds the lock? TPS |
| `./gtnh console` | Attach to the live console (detach: `Ctrl+A`, `D`) |
| `./gtnh cmd "say hi"` | Run any console command via RCON |
| `./gtnh tps` | Forge TPS report |
| `./gtnh stop` / `./gtnh start` / `./gtnh restart` | What they say. `stop` is graceful (30s), then escalates |
| `./gtnh backup` | Manual backup (the timer already does this hourly) |
| `./gtnh logs` | Tail of restart log + server log |
| `./gtnh doctor` | Health check — run whenever something feels off |

The auto-restart loop is built in: if the server crashes, it comes back in
10s, up to 5 times in a 5-minute window, then gives up with a Discord alert.

## Moving the server between machines

On the machine that HAS it:

```
./gtnh handover      # stops, final backup, releases the lock, pushes
```

On the machine that will TAKE it:

```
./gtnh takeover      # pulls, claims the lock, fixes DNS, starts
```

That's the whole migration. Discord gets notified at each step. If `takeover`
asks you to type the host id to confirm, it means it could not positively
verify the other machine is off — go check it before confirming.

First start ever on a machine also uses `./gtnh takeover` (the lock starts
unclaimed, and plain `start` refuses an unclaimed lock — that's intentional).

`--force` (on `start`/`takeover`) bypasses the lock after a typed
confirmation. It exists for emergencies; if you're not SURE the other machine
is off, don't.

## Where are my backups?

```
git log --oneline | head    # "Auto backup - <timestamp>" commits, hourly
```

Rolling the world back to one of them is the one procedure you should do
carefully — follow "Rollback" in [OPERATIONS.md](OPERATIONS.md) step by step
(short version: stop, reset to the commit, force-with-lease push, restart via
`takeover`, resync the other machine).

## When something breaks

1. `./gtnh status` then `./gtnh doctor` — they diagnose most things.
2. Discord emoji legend: 🟢 up / 🔴 down or hard failure / 🟠 backup push
   failed (will retry) / 🚨 needs you now / ⚠️ something was forced or
   degraded / 🔓 lock released / 🌐 DNS updated.
3. Specific failures (backup stuck, oversized file, frozen JVM, GitHub down,
   crash loops): [OPERATIONS.md](OPERATIONS.md) has a section for each.

## What exists and what doesn't (June 2026)

- ✅ Phase 1 — this CLI, the lock system, backups, DNS, Discord, schedule
  units, docs. The old per-OS scripts it replaced have been removed
  (recoverable from git history if you ever need a bare launcher).
- ❌ Phase 2 — the web panel (Bun + ElysiaJS, takeover button in the
  browser) is NOT built yet. It was deliberately scoped to come after Phase 1
  is validated in real use.
