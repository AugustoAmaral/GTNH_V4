# GTNH V4

GregTech: New Horizons modded Minecraft server (Forge 1.7.10 + lwjgl3ify, Java 21).

The entire server — world, mods, configs, tooling — lives in this repo.
Hourly git commits are the backup; rollback to any point is a `git reset`.

## How it works

The server runs on **one machine at a time** (an Oracle Cloud ARM instance or
a Mac), controlled by a single bash CLI: **`./gtnh`**. A lock file
(`state/active-host.json`) tracks which host owns the world. Moving the
server between machines is two commands (`handover` + `takeover`); DNS
updates automatically via Cloudflare.

```
./gtnh status       # who owns it, is it running, TPS
./gtnh takeover     # claim the lock, start the server
./gtnh handover     # stop, backup, release the lock
./gtnh doctor       # health check — tells you what's missing
```

## Quick start

```bash
cp .env.example .env && chmod 600 .env   # fill in your secrets
./gtnh doctor                            # shows what tools are missing
./gtnh takeover                          # claim + start (first time)
```

## Repository layout

```
gtnh                          The CLI (everything you need day-to-day)
.env.example                  Template for per-machine secrets (→ .env)
.env                          Your secrets (gitignored, never committed)
state/active-host.json        Host lock — who owns the world right now
server.properties.template    Server config (edit THIS, not server.properties)
server.properties             Generated at start from the template (gitignored)

World/                        The Minecraft world (region files, etc.)
mods/                         GTNH mod jars
config/                       Mod configs
libraries/                    Forge libraries
lwjgl3ify-forgePatches.jar    Patched Forge launcher (Java 9+)
java9args.txt                 JVM module-system flags

deploy/                       Schedule units (install once per machine)
  gtnh-backup.service/timer     Hourly backup (systemd, Linux)
  gtnh-maintenance.service/timer Weekly git gc (systemd, Linux)
  com.gtnh.backup.plist          Hourly backup (launchd, Mac)
  com.gtnh.maintenance.plist     Weekly git gc (launchd, Mac)

tests/run-tests.sh            Offline test suite (43 tests, no server needed)

MANUAL.md                     User manual — setup, daily ops, migration
OPERATIONS.md                 Deep runbook — failure recovery, rollback, emergencies
```

## Documentation

| Doc | What it covers |
|---|---|
| **[MANUAL.md](MANUAL.md)** | Setup guide, `.env` fields explained, everyday commands, how to move the server between machines, backup & restore, troubleshooting |
| **[OPERATIONS.md](OPERATIONS.md)** | Failure recovery (backup stuck, oversized files, RCON broken, GitHub down), world rollback procedure, crash-loop diagnosis, long-term repo growth strategy, new-machine setup with Mac-specific caveats, security notes |

## Key features

- **Dual-host lock** — only one machine can run the server; anti-split-brain
  probe checks the peer's port before takeover
- **Hourly git backup** — `save-off` via RCON, size guard (>90MB = abort
  before commit), push with retry, Discord alerts on failure
- **Auto-restart** — crash loop with circuit breaker (5 crashes / 5 min),
  stop sentinel prevents the old restart-during-stop race
- **Cloudflare DNS** — A record updated on takeover so players resolve the
  new host automatically
- **Discord notifications** — start/stop, backup failures, handover,
  takeover, crash alerts, forced actions
- **RCON** — `gtnh cmd "say ..."` / `gtnh tps`, password via env (not argv)

## Previous iterations

This is the fourth iteration of the server repo:
- [V1](https://github.com/AugustoAmaral/GTNH) — original
- [V2](https://github.com/AugustoAmaral/GTNH_V2) — attempted LFS (too expensive)
- [V3](https://github.com/AugustoAmaral/GTNH_V3) — without LFS
- **V4** (this repo) — unified CLI, dual-host control, automated backups
