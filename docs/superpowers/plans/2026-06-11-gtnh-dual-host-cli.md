# gtnh Dual-Host Control CLI — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single bash CLI (`gtnh`) that controls the GTNH V4 Minecraft server on both hosts (Oracle/Ubuntu-ARM and Mac), with safe git backups, a published-lock handover/takeover protocol against split-brain, Cloudflare DNS updates, and Discord notifications.

**Architecture:** One bash script at the repo root, organized in function sections (env detection → helpers → notify → lock → properties render → RCON → process → backup → DNS → handover/takeover → maintenance → dispatch). Pure-logic units are exposed as `_`-prefixed internal subcommands so an offline test suite (`tests/run-tests.sh`) can exercise them without a server. Scheduling via systemd timers (Linux) and launchd (Mac), no screen sessions for backups.

**Tech Stack:** bash (must stay **bash 3.2 compatible** — the Mac ships 3.2: no associative arrays, no `|&`, no `${var,,}`), `jq` (JSON), `curl`, `screen`, `mcrcon`, `nc`, systemd/launchd.

**Spec:** `docs/superpowers/specs/2026-06-11-gtnh-dual-host-control-design.md` — read it before starting.

**Conventions for this repo:** commit directly to `main` (repo history is the backup; this is the established pattern). Commit messages in English, no Co-Authored-By. Do NOT push during implementation unless a task says so — the user pushes via the normal backup flow. The server is STOPPED on both hosts; nothing in this plan starts it. Steps marked **GATE** require Augusto's explicit confirmation before running (sudo / file removal) — the orchestrator asks, never a subagent.

**Current facts (verified 2026-06-11):** repo at `/home/ubuntu/GTNH_V4`, branch `main`, this is the Oracle machine (`aarch64`, hostname `network`, user `ubuntu`), Java 21 at `/usr/lib/jvm/java-21-openjdk-arm64/bin/java`, `.git` is 50GB, server stopped on both machines, remote `git@github.com:AugustoAmaral/GTNH_V4.git` in sync with local HEAD. `jq`, `curl`, `git`, `screen`, `python3` installed; `shellcheck`, `nc`, `mcrcon`, `tailscale` NOT installed.

---

## File Structure

| File | Responsibility |
|---|---|
| `gtnh` (create) | The whole CLI. Single file by design (approved in spec). |
| `tests/run-tests.sh` (create) | Offline test suite; grows by appending test calls per task; runs without a server. |
| `.gitignore` (modify) | Noise + secrets + sentinel. |
| `state/active-host.json` (create) | The host lock, versioned. |
| `server.properties.template` (create) | Versioned config; real `server.properties` becomes untracked and rendered at start. |
| `.env.example` (create) | Documented template for per-machine secrets. |
| `deploy/gtnh-backup.{service,timer}` (create) | Hourly backup on Linux. |
| `deploy/gtnh-maintenance.{service,timer}` (create) | Weekly `git gc` on Linux. |
| `deploy/com.gtnh.{backup,maintenance}.plist` (create) | Same for Mac (with `@SERVER_DIR@` placeholder). |
| `OPERATIONS.md` (create) | Runbook. |

Old scripts (`run*.sh`, `server-control*.sh`, `quick-control-*.sh`, `autobackup.py`, `autoBackup.sh`, `backupAuto.js`) are NOT touched.

---

### Task 1: Provisioning block A — shellcheck (GATE)

`shellcheck` is used as the lint gate in every later task.

- [ ] **Step 1: GATE — ask Augusto for confirmation to run:**

```bash
sudo apt-get update && sudo apt-get install -y shellcheck
```

Show him exactly this command block and wait for an explicit OK before executing. If he declines, skip shellcheck steps in later tasks and note it in the final summary.

- [ ] **Step 2: Verify**

Run: `shellcheck --version`
Expected: version output (any version).

No commit (nothing in the repo changed).

---

### Task 2: .gitignore + untrack noise files

**Files:**
- Modify: `/home/ubuntu/GTNH_V4/.gitignore`

- [ ] **Step 1: Rewrite `.gitignore`** with this exact content (preserves all current entries, adds the new ones):

```gitignore
backup/
backups/
logs/
config/galacticgreg/GalacticGreg.cfg
*.cache
restart.log
backup.log
*.pyc
__pycache__/
World*.zip
.env
crash-reports/
*.log
.DS_Store
*.hprof
hs_err_pid*
lastUpdate.txt
.stop-requested
```

- [ ] **Step 2: Untrack already-tracked noise** (files stay on disk and in history):

```bash
cd /home/ubuntu/GTNH_V4
git rm -r --cached --quiet gc.log gc.log.0 gc.log.1 .healer.log minetweaker.log lastUpdate.txt chunk_report.txt coretweaks/cache
git ls-files -z | grep -z '\.DS_Store$' | xargs -0 -r git rm --cached --quiet --
git ls-files -z 'crash-reports' | xargs -0 -r git rm --cached --quiet --
```

- [ ] **Step 3: Verify** — `git status --short` shows only `D ` (staged deletions) plus `M .gitignore`; `git ls-files '*.log' 'coretweaks/cache'` prints nothing; the files still exist on disk (`ls gc.log coretweaks/cache/ | head`).

- [ ] **Step 4: Commit**

```bash
git add .gitignore
git commit -m "Stop tracking logs, caches and other noise; expand .gitignore"
```

- [ ] **Step 5: GATE — upload_world.sh removal.** Ask Augusto: "Removo o `upload_world.sh` agora (senha SFTP em texto plano)? A credencial do reis.host fica por sua conta rotacionar." If yes:

```bash
git rm upload_world.sh
git commit -m "Remove upload_world.sh (plaintext SFTP credential)"
```

If no, skip and note in the final summary.

---

### Task 3: CLI skeleton — env detection, helpers, doctor, dispatch + test harness

**Files:**
- Create: `/home/ubuntu/GTNH_V4/gtnh`
- Create: `/home/ubuntu/GTNH_V4/tests/run-tests.sh`

- [ ] **Step 1: Write the test harness** `tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Offline test suite for the gtnh CLI. Runs WITHOUT a server.
# Tests call gtnh with GTNH_NO_ENV=1 so the real .env never leaks in.
set -u
cd "$(dirname "$0")/.." || exit 1
GTNH=./gtnh
PASS=0; FAIL=0

t() { # t <description> <expected-exit-code> <cmd...>
  local desc="$1" want="$2"; shift 2
  local out got
  out="$("$@" 2>&1)"; got=$?
  if [ "$got" -eq "$want" ]; then
    PASS=$((PASS+1)); echo "ok: $desc"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $desc (exit $got, wanted $want)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

contains() { # contains <description> <needle> <cmd...>
  local desc="$1" needle="$2"; shift 2
  local out
  out="$("$@" 2>&1)"
  if printf '%s' "$out" | grep -qF "$needle"; then
    PASS=$((PASS+1)); echo "ok: $desc"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $desc (output missing: $needle)"
    printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# ── Task 3: skeleton ──────────────────────────────────────────
t "help exits 0"            0 env GTNH_NO_ENV=1 "$GTNH" help
t "unknown command exits 1" 1 env GTNH_NO_ENV=1 "$GTNH" frobnicate
contains "help lists takeover" "takeover" env GTNH_NO_ENV=1 "$GTNH" help

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails** — `bash tests/run-tests.sh` → expected: FAIL (`./gtnh` does not exist).

- [ ] **Step 3: Write the skeleton** `gtnh`:

```bash
#!/usr/bin/env bash
# gtnh — unified control CLI for the GTNH V4 dual-host Minecraft server.
# Single file by design. Must stay bash 3.2 compatible (the Mac ships 3.2).
# Spec: docs/superpowers/specs/2026-06-11-gtnh-dual-host-control-design.md
set -u

### ── Environment detection (the ONLY machine-specific block) ──
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SERVER_DIR="$(dirname "$SCRIPT_PATH")"
OS="$(uname -s)" # Linux | Darwin

# Per-machine config and secrets. GTNH_NO_ENV=1 skips it (used by tests).
if [ -z "${GTNH_NO_ENV:-}" ] && [ -f "$SERVER_DIR/.env" ]; then
  set -a
  . "$SERVER_DIR/.env"
  set +a
fi

HOST_ID="${HOST_ID:-$(hostname -s)}"
RCON_PORT="${RCON_PORT:-25575}"
MC_PORT=25565
SCREEN_NAME="gtnh"
SERVER_JAR="lwjgl3ify-forgePatches.jar"
RESTART_LOG="$SERVER_DIR/restart.log"
LOCK_FILE="$SERVER_DIR/state/active-host.json"
STOP_SENTINEL="$SERVER_DIR/.stop-requested"
PROPERTIES_TEMPLATE="$SERVER_DIR/server.properties.template"
PROPERTIES_FILE="$SERVER_DIR/server.properties"
MAINTENANCE_LOG="$SERVER_DIR/maintenance.log"

### ── Helpers ──────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "$*"; }
has()  { command -v "$1" >/dev/null 2>&1; }
tmo()  { # run with a 10s timeout where a timeout binary exists (Linux); plain otherwise (Mac)
  if has timeout; then timeout 10 "$@"; elif has gtimeout; then gtimeout 10 "$@"; else "$@"; fi
}

java_bin() {
  if [ "$OS" = "Darwin" ]; then
    local home
    home="$(/usr/libexec/java_home -v 21 2>/dev/null)" || return 1
    echo "$home/bin/java"
  else
    echo "/usr/lib/jvm/java-21-openjdk-arm64/bin/java"
  fi
}

### ── Low-level process helpers ────────────────────────────────
screen_exists()  { screen -list 2>/dev/null | grep -qE "[0-9]+\.${SCREEN_NAME}[[:space:]]"; }
server_pids()    { pgrep -f "$SERVER_JAR" 2>/dev/null; }
runner_pids()    { pgrep -f "gtnh _run-loop" 2>/dev/null | grep -v "^$$\$" || true; }
server_running() { [ -n "$(server_pids)" ]; }
screen_stuff()   { screen -S "$SCREEN_NAME" -X stuff "$1$(printf '\r')"; }

### ── doctor ───────────────────────────────────────────────────
cmd_doctor() {
  local rc=0 jb v val
  echo "gtnh doctor — host '$HOST_ID' ($OS)"
  if jb="$(java_bin)" && [ -x "$jb" ]; then
    echo "  ok       java 21: $jb"
  else
    if [ "$OS" = "Darwin" ]; then
      echo "  MISSING  java 21 — brew install --cask zulu@21"
    else
      echo "  MISSING  java 21 — sudo apt install openjdk-21-jdk"
    fi
    rc=1
  fi
  for v in jq screen git curl; do
    if has "$v"; then echo "  ok       $v"; else echo "  MISSING  $v (required)"; rc=1; fi
  done
  if has mcrcon; then echo "  ok       mcrcon"; else
    if [ "$OS" = "Darwin" ]; then
      echo "  missing  mcrcon — brew install mcrcon (RCON commands unavailable until installed)"
    else
      echo "  missing  mcrcon — build from github.com/Tiiffi/mcrcon, see OPERATIONS.md"
    fi
  fi
  if has nc; then echo "  ok       nc"; else
    echo "  missing  nc — sudo apt install netcat-openbsd (takeover peer probe degraded)"
  fi
  if has tailscale; then echo "  ok       tailscale"; else
    echo "  missing  tailscale — https://tailscale.com/install.sh (peer reachability check degraded)"
  fi
  if [ -f "$SERVER_DIR/.env" ]; then
    echo "  ok       .env present"
    for v in HOST_ID DISCORD_WEBHOOK_URL RCON_PASSWORD PEER_HOST CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID CF_RECORD_NAME; do
      eval "val=\${$v:-}"
      if [ -n "$val" ]; then echo "  ok       .env: $v"; else echo "  missing  .env: $v"; fi
    done
  else
    echo "  MISSING  .env — cp .env.example .env and fill it in"
    rc=1
  fi
  if jq -e . "$LOCK_FILE" >/dev/null 2>&1; then
    echo "  ok       lock: $(jq -c . "$LOCK_FILE")"
  else
    echo "  BROKEN   lock file missing/invalid: $LOCK_FILE"
    rc=1
  fi
  return "$rc"
}

### ── usage / dispatch ─────────────────────────────────────────
usage() {
  cat <<'EOF'
gtnh — GTNH V4 dual-host server control

Process:  start [--force] | stop | restart | kill | status | logs | console | clear-crashes
RCON:     cmd "<command>" | tps
Backup:   backup | maintenance
Hosts:    handover | takeover [--force] | dns-update [--dry-run]
Setup:    doctor

See OPERATIONS.md for the runbook.
EOF
}

case "${1:-help}" in
  help|-h|--help) usage ;;
  doctor)         cmd_doctor ;;
  *)              usage; exit 1 ;;
esac
```

- [ ] **Step 4: Make it executable and run the tests**

```bash
chmod +x gtnh
bash tests/run-tests.sh
```

Expected: `passed: 3, failed: 0`.

- [ ] **Step 5: Lint** — `shellcheck gtnh tests/run-tests.sh` → no errors (info/style notes acceptable; fix warnings and errors).

- [ ] **Step 6: Commit**

```bash
git add gtnh tests/run-tests.sh
git commit -m "Add gtnh CLI skeleton: env detection, helpers, doctor, test harness"
```

---

### Task 4: Discord notify()

**Files:**
- Modify: `gtnh` (add section after helpers), `tests/run-tests.sh` (append tests)

- [ ] **Step 1: Append tests** to `tests/run-tests.sh` (before the final `echo "---"` block):

```bash
# ── Task 4: notify ────────────────────────────────────────────
t "notify without webhook is a silent no-op" 0 env GTNH_NO_ENV=1 "$GTNH" _notify "test"
```

- [ ] **Step 2: Run to verify it fails** — `bash tests/run-tests.sh` → FAIL (`_notify` unknown → exit 1).

- [ ] **Step 3: Implement.** Add after the `java_bin` function in `gtnh`:

```bash
### ── Discord notifications ────────────────────────────────────
notify() { # notify <emoji> <message> — best-effort; NEVER fails the caller
  [ -n "${DISCORD_WEBHOOK_URL:-}" ] || return 0
  curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    -d "$(jq -n --arg c "$1 [$HOST_ID] $2" '{content: $c}')" \
    "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}
```

And add to the dispatch case (before `*)`):

```bash
  _notify)        notify "🔧" "${2:-test message from gtnh}" ;;
```

- [ ] **Step 4: Run tests** — `bash tests/run-tests.sh` → `passed: 4, failed: 0`.
- [ ] **Step 5: Lint** — `shellcheck gtnh`.
- [ ] **Step 6: Commit** — `git add gtnh tests/run-tests.sh && git commit -m "Add best-effort Discord notify()"`

---

### Task 5: Lock — state file, lock_state, lock_write, _lock-check

**Files:**
- Create: `state/active-host.json`
- Modify: `gtnh`, `tests/run-tests.sh`

- [ ] **Step 1: Append tests:**

```bash
# ── Task 5: lock ──────────────────────────────────────────────
TMPLOCK="$(mktemp -d)"
printf '{"active":"none","since":"2026-06-11T00:00:00Z","released_clean":true}'   > "$TMPLOCK/free.json"
printf '{"active":"oracle","since":"2026-06-11T00:00:00Z","released_clean":false}' > "$TMPLOCK/oracle.json"
printf 'not json' > "$TMPLOCK/broken.json"
t "lock free"                     0 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/free.json" oracle
contains "lock free prints free" "free" env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/free.json" oracle
t "lock self"                     0 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" oracle
contains "lock self prints self" "self" env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" oracle
t "lock held by other exits 1"    1 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" mac
contains "lock held names holder" "held oracle" env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" mac
t "broken lock exits 2"           2 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/broken.json" oracle
rm -rf "$TMPLOCK"
```

- [ ] **Step 2: Run to verify failure** — `bash tests/run-tests.sh` → the 7 new tests FAIL.

- [ ] **Step 3: Implement.** Add after the notify section in `gtnh`:

```bash
### ── Host lock (state/active-host.json) ───────────────────────
lock_state() { # lock_state <file> <host-id>
  # prints: "free" | "self" | "held <holder> <released_clean>" | "invalid"
  # exit:    0        0        1                                  2
  local file="$1" host="$2" active released
  active="$(jq -r '.active' "$file" 2>/dev/null)" || { echo "invalid"; return 2; }
  case "$active" in ""|null) echo "invalid"; return 2 ;; esac
  if [ "$active" = "none" ]; then echo "free"; return 0; fi
  if [ "$active" = "$host" ]; then echo "self"; return 0; fi
  released="$(jq -r '.released_clean' "$file" 2>/dev/null)"
  echo "held $active $released"
  return 1
}

lock_write() { # lock_write <active> <released_clean true|false> <commit-message>
  local tmp
  tmp="$(mktemp)" || return 1
  jq -n --arg a "$1" --argjson r "$2" \
    '{active: $a, since: (now | todate), released_clean: $r}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$LOCK_FILE" || return 1
  git -C "$SERVER_DIR" add "$LOCK_FILE" \
    && git -C "$SERVER_DIR" commit -m "$3" -- "$LOCK_FILE" >/dev/null
}
```

Dispatch case:

```bash
  _lock-check)    lock_state "${2:?usage: gtnh _lock-check <file> <host-id>}" "${3:?host-id required}" ;;
```

- [ ] **Step 4: Run tests** — all pass.

- [ ] **Step 5: Create the initial lock file** (server verified stopped on both hosts):

```bash
mkdir -p state
printf '{\n  "active": "none",\n  "since": "2026-06-11T00:00:00Z",\n  "released_clean": true\n}\n' > state/active-host.json
jq . state/active-host.json
```

Expected: valid JSON echoed back.

- [ ] **Step 6: Lint + commit**

```bash
shellcheck gtnh
git add gtnh tests/run-tests.sh state/active-host.json
git commit -m "Add host lock: state file, lock_state/lock_write, _lock-check"
```

---

### Task 6: server.properties.template + render

**Files:**
- Create: `server.properties.template`
- Modify: `gtnh`, `tests/run-tests.sh`, `.gitignore`

- [ ] **Step 1: Append tests:**

```bash
# ── Task 6: properties render ─────────────────────────────────
TMPPROP="$(mktemp -d)"
t "render with password succeeds" 0 env GTNH_NO_ENV=1 RCON_PASSWORD=s3cret RCON_PORT=25575 \
  "$GTNH" _render-properties server.properties.template "$TMPPROP/out.properties"
contains "rendered file has the password" "rcon.password=s3cret" cat "$TMPPROP/out.properties"
contains "rendered file enables rcon"     "enable-rcon=true"     cat "$TMPPROP/out.properties"
contains "rendered file has the port"     "rcon.port=25575"      cat "$TMPPROP/out.properties"
t "render without password fails" 1 env GTNH_NO_ENV=1 "$GTNH" _render-properties server.properties.template "$TMPPROP/out2.properties"
rm -rf "$TMPPROP"
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Create `server.properties.template`** — the current `server.properties` content with RCON enabled and placeholders (exact content):

```properties
#Minecraft server properties
#Rendered by 'gtnh start' from server.properties.template — edit the TEMPLATE, not this file.
allow-flight=true
allow-nether=true
announce-player-achievements=true
difficulty=3
enable-command-block=true
enable-query=false
enable-rcon=true
rcon.port=@RCON_PORT@
rcon.password=@RCON_PASSWORD@
force-gamemode=false
gamemode=0
generate-structures=true
generator-settings=
hardcore=false
level-name=World
level-seed=whyamidoingthistomyself
level-type=rwg
max-build-height=256
max-players=10
max-tick-time=300000
motd=Seja bem vindo ao nosso servidor de GTNH\! V2.7.4
network-compression-threshold=256
online-mode=false
op-permission-level=2
pause-when-empty-seconds=0
player-idle-timeout=0
pvp=true
resource-pack=
server-id=unnamed
server-ip=0.0.0.0
server-name=GTNH - V2.7.4
server-port=25565
snooper-enabled=true
spawn-animals=true
spawn-monsters=true
spawn-npcs=true
spawn-protection=1
texture-pack=
view-distance=10
white-list=true
```

- [ ] **Step 4: Implement render.** Add to `gtnh` after the lock section:

```bash
### ── server.properties rendering ──────────────────────────────
render_properties() { # render_properties [template] [output]
  local tmpl="${1:-$PROPERTIES_TEMPLATE}" out="${2:-$PROPERTIES_FILE}"
  [ -f "$tmpl" ] || die "template not found: $tmpl"
  [ -n "${RCON_PASSWORD:-}" ] || die "RCON_PASSWORD not set (.env) — refusing to render server.properties"
  sed -e "s|@RCON_PORT@|$RCON_PORT|g" -e "s|@RCON_PASSWORD@|$RCON_PASSWORD|g" "$tmpl" > "$out"
}
```

Dispatch case:

```bash
  _render-properties) render_properties "${2:-}" "${3:-}" ;;
```

- [ ] **Step 5: Run tests** — all pass. **Lint.**

- [ ] **Step 6: Untrack the live file** (it will contain the real password from now on):

```bash
echo "server.properties" >> .gitignore
git rm --cached --quiet server.properties
```

Verify: `git ls-files server.properties` prints nothing; the file still exists on disk.

- [ ] **Step 7: Commit**

```bash
git add gtnh tests/run-tests.sh server.properties.template .gitignore
git commit -m "Render server.properties from template; keep RCON password out of git"
```

---

### Task 7: RCON commands (cmd, tps)

**Files:**
- Modify: `gtnh`, `tests/run-tests.sh`

- [ ] **Step 1: Append tests** (offline; the server is down — test the guard rails). Assert exit codes, not messages: the first guard hit changes once mcrcon gets installed in Task 15, and the suite must stay green after that.

```bash
# ── Task 7: rcon ──────────────────────────────────────────────
t "gtnh cmd without args fails"                     1 env GTNH_NO_ENV=1 "$GTNH" cmd
t "gtnh cmd fails cleanly (no mcrcon or no server)" 1 env GTNH_NO_ENV=1 RCON_PASSWORD=x "$GTNH" cmd "list"
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** Add after the render section:

```bash
### ── RCON ─────────────────────────────────────────────────────
can_rcon() { has mcrcon && [ -n "${RCON_PASSWORD:-}" ]; }

rcon_cmd() { # rcon_cmd <command> — against localhost; returns mcrcon's status
  can_rcon || return 1
  tmo mcrcon -H 127.0.0.1 -P "$RCON_PORT" -p "$RCON_PASSWORD" "$1" 2>/dev/null
}

cmd_cmd() {
  [ -n "${1:-}" ] || die 'usage: gtnh cmd "<command>"'
  has mcrcon || die "mcrcon not installed — run 'gtnh doctor' for instructions"
  [ -n "${RCON_PASSWORD:-}" ] || die "RCON_PASSWORD not set in .env"
  server_running || die "server is not running"
  rcon_cmd "$1" || die "RCON command failed — is the server fully started with RCON enabled?"
}
```

Dispatch cases:

```bash
  cmd)            shift; cmd_cmd "${1:-}" ;;
  tps)            cmd_cmd "forge tps" ;;
```

- [ ] **Step 4: Run tests; lint; commit** — `git add gtnh tests/run-tests.sh && git commit -m "Add RCON cmd/tps via mcrcon"`

---

### Task 8: start, _run-loop, stop sentinel, confirm_typed

**Files:**
- Modify: `gtnh`

This task has no offline-runnable test (it touches screen/java). Verification is `shellcheck` + the refusal path exercised in Task 12's tests + the manual checklist at the end. **Do NOT run `gtnh start`.**

- [ ] **Step 1: Implement.** Add after the RCON section:

```bash
### ── Typed confirmation (force paths, unverifiable peer) ──────
confirm_typed() { # confirm_typed <warning-text>
  echo "" >&2
  echo "$1" >&2
  printf "Type this host's id (%s) to proceed: " "$HOST_ID" >&2
  local ans
  read -r ans
  [ "$ans" = "$HOST_ID" ] || die "confirmation mismatch — aborting"
}

### ── start / run-loop ─────────────────────────────────────────
cmd_start() {
  local force="${1:-}"
  has screen || die "screen not installed"
  screen_exists && die "server already running in screen '$SCREEN_NAME'"
  server_running && die "server java process already running (PID: $(server_pids | tr '\n' ' ')) — use 'gtnh stop' or 'gtnh kill'"

  local state rc
  state="$(lock_state "$LOCK_FILE" "$HOST_ID")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$state" = "self" ]; then
    : # we own the lock — normal start
  elif [ "$rc" -eq 0 ] && [ "$state" = "free" ]; then
    die "lock is unclaimed (active=none) — run 'gtnh takeover' to claim it before starting"
  else
    if [ "$force" = "--force" ]; then
      confirm_typed "Lock state is '$state'. Forcing a start here risks SPLIT-BRAIN (two hosts writing the world)."
      notify "⚠️" "FORCED start (lock: $state)"
    else
      die "lock state is '$state' — run 'gtnh handover' on the active host first, or 'gtnh start --force'"
    fi
  fi

  render_properties
  rm -f "$STOP_SENTINEL"
  cd "$SERVER_DIR" || die "cd failed"
  screen -dmS "$SCREEN_NAME" "$SCRIPT_PATH" _run-loop
  sleep 3
  if screen_exists; then
    info "server starting in screen '$SCREEN_NAME' — 'gtnh console' to attach"
    notify "🟢" "server starting"
  else
    die "failed to start — check $RESTART_LOG"
  fi
}

log_restart() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESTART_LOG"; }

cmd_run_loop() {
  cd "$SERVER_DIR" || exit 1
  local jb
  jb="$(java_bin)" && [ -x "$jb" ] || { log_restart "ERROR: java 21 not found"; exit 1; }
  rm -f "$STOP_SENTINEL" # stale sentinel from a previous unclean sequence
  # Crash counter: max 5 crashes, where each crash within 5 minutes of the
  # previous one increments the count. (The old run.sh updated last_crash_time
  # before measuring the window, so the counter never reset — this implements
  # the intended 5-in-a-5-minute-window semantics.)
  local max_crashes=5 crash_window=300 crash_count=0 last_crash_time=0
  local exit_code now
  log_restart "=== gtnh run-loop starting on $HOST_ID (PID $$, java: $jb) ==="
  while true; do
    log_restart "Starting server... (crash count: $crash_count)"
    "$jb" \
        -Xms6G -Xmx10G \
        -XX:+UseG1GC \
        -XX:+UnlockExperimentalVMOptions \
        -XX:G1NewSizePercent=30 \
        -XX:G1MaxNewSizePercent=40 \
        -XX:G1HeapRegionSize=16M \
        -XX:G1ReservePercent=20 \
        -XX:G1HeapWastePercent=5 \
        -XX:G1MixedGCCountTarget=4 \
        -XX:InitiatingHeapOccupancyPercent=20 \
        -XX:G1MixedGCLiveThresholdPercent=90 \
        -XX:MaxGCPauseMillis=130 \
        -XX:SurvivorRatio=32 \
        -XX:MaxTenuringThreshold=1 \
        -XX:+AlwaysPreTouch \
        -XX:+UseStringDeduplication \
        -XX:+ParallelRefProcEnabled \
        -XX:+PerfDisableSharedMem \
        -XX:+DisableExplicitGC \
        -XX:+UseCompressedOops \
        -Dfml.readTimeout=180 \
        @java9args.txt \
        -jar "$SERVER_JAR" nogui
    exit_code=$?
    if [ -f "$STOP_SENTINEL" ]; then
      log_restart "Stop requested — exiting run-loop (java exit code: $exit_code)."
      rm -f "$STOP_SENTINEL"
      break
    fi
    if [ "$exit_code" -eq 0 ]; then
      log_restart "Server exited normally. Ending run-loop."
      break
    fi
    now=$(date +%s)
    if [ $((now - last_crash_time)) -gt "$crash_window" ]; then crash_count=0; fi
    crash_count=$((crash_count + 1))
    last_crash_time=$now
    log_restart "CRASH detected! Exit code: $exit_code (crash #$crash_count)"
    if [ "$crash_count" -ge "$max_crashes" ]; then
      log_restart "Too many consecutive crashes ($crash_count). Auto-restart stopped."
      notify "🚨" "auto-restart gave up after $crash_count crashes — server is DOWN"
      break
    fi
    log_restart "Restarting in 10s..."
    sleep 10
  done
  log_restart "=== run-loop finished ==="
}
```

Dispatch cases:

```bash
  start)          cmd_start "${2:-}" ;;
  _run-loop)      cmd_run_loop ;;
```

- [ ] **Step 2: Lint** — `shellcheck gtnh` (the literal JVM flag block will be clean; fix anything it flags).
- [ ] **Step 3: Run the suite** — `bash tests/run-tests.sh` still fully green (no regressions).
- [ ] **Step 4: Commit** — `git add gtnh && git commit -m "Add start with lock enforcement and _run-loop with stop sentinel"`

---

### Task 9: stop, kill, restart, status, logs, console, clear-crashes

**Files:**
- Modify: `gtnh`

- [ ] **Step 1: Implement.** Add after the run-loop section:

```bash
### ── stop / kill / status / logs / console ───────────────────
cmd_stop() {
  if ! server_running && ! screen_exists; then
    info "server is not running"
    rm -f "$STOP_SENTINEL"
    return 0
  fi
  # Sentinel FIRST: from this point the run-loop will not restart java,
  # no matter how java exits. This closes the inherited stop/auto-restart race.
  touch "$STOP_SENTINEL"
  info "stopping server..."
  if server_running; then
    if can_rcon && rcon_cmd "stop" >/dev/null 2>&1; then
      info "sent 'stop' via RCON"
    elif screen_exists; then
      screen_stuff "stop"
      info "sent 'stop' via screen console"
    fi
    local i
    for i in $(seq 1 30); do
      server_running || break
      sleep 1
    done
  fi
  if server_running; then
    warn "java still alive after 30s — sending SIGTERM"
    kill $(server_pids) 2>/dev/null
    sleep 5
    if server_running; then
      warn "no response — sending SIGKILL"
      kill -9 $(server_pids) 2>/dev/null
      sleep 2
    fi
  fi
  # Cleanup only: java is dead and the sentinel already prevents restarts.
  local rp
  rp="$(runner_pids)"
  [ -n "$rp" ] && kill $rp 2>/dev/null
  sleep 1
  screen_exists && screen -S "$SCREEN_NAME" -X quit 2>/dev/null
  rm -f "$STOP_SENTINEL"
  server_running && die "could not stop the server — use 'gtnh kill'"
  info "server stopped"
  notify "🔴" "server stopped"
}

cmd_kill() {
  touch "$STOP_SENTINEL"
  local rp sp
  rp="$(runner_pids)"; sp="$(server_pids)"
  if [ -z "$rp" ] && [ -z "$sp" ]; then
    info "no server processes found"
  else
    [ -n "$rp" ] && kill -9 $rp 2>/dev/null
    [ -n "$sp" ] && kill -9 $sp 2>/dev/null
    sleep 2
    info "processes killed"
    notify "🔴" "server force-killed"
  fi
  screen_exists && screen -S "$SCREEN_NAME" -X quit 2>/dev/null
  rm -f "$STOP_SENTINEL"
}

cmd_status() {
  echo "=== GTNH status — host '$HOST_ID' ==="
  local sp tps
  sp="$(server_pids | tr '\n' ' ')"
  if [ -n "$sp" ]; then
    echo "server: RUNNING (PID: $sp)"
    if screen_exists; then echo "screen: $SCREEN_NAME"; else echo "screen: MISSING (started manually?)"; fi
    if [ "$OS" = "Darwin" ]; then
      if lsof -iTCP:"$MC_PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $MC_PORT: OPEN"; else echo "port $MC_PORT: closed (still starting?)"; fi
    else
      if ss -tuln 2>/dev/null | grep -q ":$MC_PORT "; then echo "port $MC_PORT: OPEN"; else echo "port $MC_PORT: closed (still starting?)"; fi
    fi
    if can_rcon && tps="$(rcon_cmd 'forge tps' 2>/dev/null)"; then
      echo "tps:"; printf '%s\n' "$tps" | head -8
    fi
  elif screen_exists; then
    echo "server: screen '$SCREEN_NAME' exists but java is not running (starting or crashed)"
  else
    echo "server: STOPPED"
  fi
  if jq -e . "$LOCK_FILE" >/dev/null 2>&1; then
    echo "lock: $(jq -r '"active=\(.active) since=\(.since) released_clean=\(.released_clean)"' "$LOCK_FILE")"
  else
    echo "lock: UNREADABLE ($LOCK_FILE)"
  fi
  if [ -f "$RESTART_LOG" ]; then
    echo "--- restart.log (last 5) ---"
    tail -5 "$RESTART_LOG"
  fi
}

cmd_logs() {
  if [ -f "$RESTART_LOG" ]; then
    echo "=== restart.log ==="; tail -20 "$RESTART_LOG"; echo ""
  fi
  echo "=== logs/latest.log ==="
  if [ -f "$SERVER_DIR/logs/latest.log" ]; then
    tail -20 "$SERVER_DIR/logs/latest.log"
  else
    echo "(no server log found)"
  fi
}

cmd_console() {
  if screen_exists; then
    info "attaching — Ctrl+A, D to detach without stopping the server"
    screen -r "$SCREEN_NAME"
  else
    warn "no screen session '$SCREEN_NAME'"
    server_running && warn "server is running OUTSIDE screen (PID: $(server_pids | tr '\n' ' '))"
    exit 1
  fi
}

cmd_clear_crashes() {
  if [ -f "$RESTART_LOG" ]; then
    rm "$RESTART_LOG"
    info "restart log cleared — crash counter effectively reset"
  else
    info "no restart log found"
  fi
}
```

Dispatch cases:

```bash
  stop)           cmd_stop ;;
  kill)           cmd_kill ;;
  restart)        cmd_stop; sleep 5; cmd_start "${2:-}" ;;
  status)         cmd_status ;;
  logs)           cmd_logs ;;
  console)        cmd_console ;;
  clear-crashes)  cmd_clear_crashes ;;
```

- [ ] **Step 2: Safe runtime verification** (server is stopped; these are read-only/no-op paths):

```bash
./gtnh status        # expected: "server: STOPPED" + lock line active=none
./gtnh stop          # expected: "server is not running", exit 0
bash tests/run-tests.sh
```

- [ ] **Step 3: Lint + commit** — `git add gtnh && git commit -m "Add stop/kill/restart/status/logs/console/clear-crashes"`

---

### Task 10: backup

**Files:**
- Modify: `gtnh`, `tests/run-tests.sh`

- [ ] **Step 1: Append tests:**

```bash
# ── Task 10: backup units ─────────────────────────────────────
TMPREPO="$(mktemp -d)"
( cd "$TMPREPO" && git init -q . && git config user.email t@t && git config user.name t \
  && echo small > small.txt && git add small.txt )
t "size guard passes small files" 0 env GTNH_NO_ENV=1 sh -c "cd '$TMPREPO' && '$PWD/gtnh' _staged-guard"
( cd "$TMPREPO" && truncate -s 100M big.bin && git add big.bin )
t "size guard rejects >90MB file" 1 env GTNH_NO_ENV=1 sh -c "cd '$TMPREPO' && '$PWD/gtnh' _staged-guard"
contains "size guard names the file" "big.bin" env GTNH_NO_ENV=1 sh -c "cd '$TMPREPO' && '$PWD/gtnh' _staged-guard"
mkdir -p "$TMPREPO/lockdir/.git"
touch "$TMPREPO/lockdir/.git/index.lock"
touch -t 202601010000 "$TMPREPO/lockdir/.git/index.lock"
t "stale index.lock removed"     0 env GTNH_NO_ENV=1 "$GTNH" _clean-index-lock "$TMPREPO/lockdir"
t "stale index.lock is gone"     1 test -f "$TMPREPO/lockdir/.git/index.lock"
touch "$TMPREPO/lockdir/.git/index.lock"
t "fresh index.lock kept"        0 env GTNH_NO_ENV=1 "$GTNH" _clean-index-lock "$TMPREPO/lockdir"
t "fresh index.lock still there" 0 test -f "$TMPREPO/lockdir/.git/index.lock"
rm -rf "$TMPREPO"
```

(Note: `truncate` creates a sparse file — instant, no disk cost. If `truncate` is missing on the Mac later, these two tests may be skipped there; they run on Oracle.)

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** Add after the process section:

```bash
### ── backup ───────────────────────────────────────────────────
clean_stale_index_lock() { # clean_stale_index_lock [repo-dir]
  local dir="${1:-$SERVER_DIR}" lock
  lock="$dir/.git/index.lock"
  [ -f "$lock" ] || return 0
  if pgrep -x git >/dev/null 2>&1; then
    warn "a git process is running — leaving index.lock alone"
    return 0
  fi
  if [ -n "$(find "$lock" -mmin +30 2>/dev/null)" ]; then
    warn "removing stale .git/index.lock (older than 30 minutes)"
    rm -f "$lock"
  fi
}

staged_size_guard() { # checks staged files in CWD repo; fails if any exceeds 90MB
  local limit=$((90 * 1024 * 1024)) f size bad=""
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    if [ "$OS" = "Darwin" ]; then size=$(stat -f %z "$f"); else size=$(stat -c %s "$f"); fi
    [ "$size" -gt "$limit" ] && bad="$bad $f ($((size / 1024 / 1024))MB)"
  done < <(git diff --cached --name-only -z)
  [ -z "$bad" ] && return 0
  echo "ERROR: staged file(s) over 90MB:$bad" >&2
  echo "GitHub rejects blobs over 100MB — committing would break every future push." >&2
  echo "See OPERATIONS.md ('Oversized staged file')." >&2
  return 1
}

cmd_backup() {
  cd "$SERVER_DIR" || die "cd failed"
  local active
  active="$(jq -r '.active' "$LOCK_FILE" 2>/dev/null || echo none)"
  if [ "$active" != "none" ] && [ "$active" != "null" ] && [ "$active" != "$HOST_ID" ]; then
    exit 0 # another host owns the world — never commit from here
  fi
  clean_stale_index_lock
  SAVED_OFF=0
  # The trap fires save-on ONLY if this run issued save-off — a stopped-server
  # backup never touches RCON, including on exit.
  trap 'if [ "${SAVED_OFF:-0}" = "1" ]; then rcon_cmd "save-on" >/dev/null 2>&1 || true; fi' EXIT
  if server_running && can_rcon; then
    if rcon_cmd "save-off" >/dev/null 2>&1; then
      SAVED_OFF=1
      rcon_cmd "save-all flush" >/dev/null 2>&1 || true
      sleep 15
    else
      warn "save-off failed — backing up without pausing saves"
    fi
  fi
  git add -A
  if git diff --cached --quiet; then
    exit 0 # nothing to back up
  fi
  if ! staged_size_guard; then
    notify "🚨" "backup ABORTED before commit: staged file over 90MB — see OPERATIONS.md"
    die "backup aborted — changes remain staged for the next run"
  fi
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M')"
  if ! git commit -m "Auto backup - $ts" >/dev/null; then
    notify "🔴" "backup commit FAILED — changes remain staged"
    die "git commit failed — changes remain staged for the next run"
  fi
  info "backup committed: $(git rev-parse --short HEAD)"
  if ! git push >/dev/null 2>&1; then
    notify "🟠" "backup committed locally but push FAILED — retrying next run"
    warn "push failed — the commit exists locally only"
    exit 1
  fi
  info "pushed"
}
```

Dispatch cases:

```bash
  backup)             cmd_backup ;;
  _staged-guard)      staged_size_guard ;;
  _clean-index-lock)  clean_stale_index_lock "${2:-}" ;;
```

- [ ] **Step 4: Run tests** — all green. **Lint.**

- [ ] **Step 5: Real-world verification** — run `./gtnh backup` once. Server is stopped, lock is `none`: it should commit any pending working-tree changes (or exit silently if clean) and push. This is the production code path — a real commit is the mechanism working, not a side effect. Verify with `git log --oneline -2`.

- [ ] **Step 6: Commit** — `git add gtnh tests/run-tests.sh && git commit -m "Add safe backup: ownership gate, stale-lock cleanup, save-off trap, size guard"`

---

### Task 11: dns-update

**Files:**
- Modify: `gtnh`, `tests/run-tests.sh`

- [ ] **Step 1: Append tests:**

```bash
# ── Task 11: dns ──────────────────────────────────────────────
t "dns-update without config fails" 1 env GTNH_NO_ENV=1 "$GTNH" dns-update --dry-run
contains "dns-update lists missing vars" "CF_API_TOKEN" env GTNH_NO_ENV=1 "$GTNH" dns-update --dry-run
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** Add after the backup section:

```bash
### ── Cloudflare DNS ───────────────────────────────────────────
cmd_dns_update() { # [--dry-run]
  local dry=0 missing="" v val ip api current body resp
  [ "${1:-}" = "--dry-run" ] && dry=1
  for v in CF_API_TOKEN CF_ZONE_ID CF_RECORD_ID CF_RECORD_NAME; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || missing="$missing $v"
  done
  [ -z "$missing" ] || die "missing in .env:$missing"
  ip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null)" \
    || ip="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null)" \
    || die "could not discover the public IP"
  api="https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID"
  current="$(curl -fsS --max-time 10 -H "Authorization: Bearer $CF_API_TOKEN" "$api" | jq -r '.result.content')" \
    || die "could not read the current DNS record from Cloudflare"
  if [ "$current" = "$ip" ]; then
    info "DNS already current: $CF_RECORD_NAME -> $ip"
    return 0
  fi
  if [ "$dry" -eq 1 ]; then
    info "[dry-run] would update $CF_RECORD_NAME: $current -> $ip"
    return 0
  fi
  body="$(jq -n --arg name "$CF_RECORD_NAME" --arg ip "$ip" \
    '{type: "A", name: $name, content: $ip, ttl: 120, proxied: false}')"
  resp="$(curl -fsS --max-time 10 -X PUT \
    -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' \
    -d "$body" "$api")" || die "Cloudflare API PUT failed"
  printf '%s' "$resp" | jq -e '.success' >/dev/null || die "Cloudflare returned failure: $resp"
  info "DNS updated: $CF_RECORD_NAME $current -> $ip"
  notify "🌐" "DNS updated: $CF_RECORD_NAME -> $ip"
}
```

Dispatch case:

```bash
  dns-update)     cmd_dns_update "${2:-}" ;;
```

(Sets `ttl: 120` on update, matching the 60–120s recommendation in the spec.)

- [ ] **Step 4: Run tests; lint; commit** — `git add gtnh tests/run-tests.sh && git commit -m "Add Cloudflare dns-update with --dry-run"`

---

### Task 12: handover and takeover

**Files:**
- Modify: `gtnh`, `tests/run-tests.sh`

- [ ] **Step 1: Append tests** (offline-safe paths only — the lock-guard logic is `lock_state`, already covered by Task 5's tests; full handover/takeover flows are in the manual checklist):

```bash
# ── Task 12: handover/takeover guards ─────────────────────────
contains "probe without PEER_HOST says no-config" "no-config" env GTNH_NO_ENV=1 "$GTNH" _probe-peer
```

- [ ] **Step 2: Run to verify failure.**

- [ ] **Step 3: Implement.** Add after the DNS section:

```bash
### ── handover / takeover ──────────────────────────────────────
probe_peer() { # prints: open | closed | unreachable | no-config | no-tool
  [ -n "${PEER_HOST:-}" ] || { echo "no-config"; return 0; }
  has nc || { echo "no-tool"; return 0; }
  if nc -z -w 5 "$PEER_HOST" "$MC_PORT" >/dev/null 2>&1; then
    echo "open"
    return 0
  fi
  if has tailscale && tailscale ping -c 1 --timeout 3s "$PEER_HOST" >/dev/null 2>&1; then
    echo "closed" # peer reachable AND port closed — positively safe
    return 0
  fi
  echo "unreachable" # port didn't answer but we can't prove the peer is down
}

cmd_handover() {
  cd "$SERVER_DIR" || die "cd failed"
  local state
  state="$(lock_state "$LOCK_FILE" "$HOST_ID")" || true
  case "$state" in
    self) : ;;
    free) info "lock already released — re-running the publish steps (idempotent)" ;;
    *)    die "this host does not hold the lock ($state) — nothing to hand over" ;;
  esac
  if server_running || screen_exists; then
    cmd_stop
  fi
  info "running final backup..."
  "$SCRIPT_PATH" backup \
    || die "final backup FAILED — lock NOT released. Fix the backup, then re-run 'gtnh handover'."
  if [ "$state" = "self" ]; then
    lock_write "none" true "Handover: release by $HOST_ID" || die "could not commit the lock release"
  fi
  if ! git push; then
    notify "🔴" "handover push FAILED on $HOST_ID — peer must NOT take over yet"
    {
      echo ""
      echo "#############################################################"
      echo "# PUSH FAILED — the release is NOT published.               #"
      echo "# The other machine must NOT run 'gtnh takeover' yet.       #"
      echo "# Fix connectivity and re-run 'gtnh handover' (idempotent). #"
      echo "#############################################################"
    } >&2
    exit 1
  fi
  info "handover complete — the peer may now take over"
  notify "🔓" "server released by $HOST_ID"
}

cmd_takeover() {
  local force=0 state holder released
  [ "${1:-}" = "--force" ] && force=1
  cd "$SERVER_DIR" || die "cd failed"
  [ -z "$(git status --porcelain)" ] \
    || die "working tree is dirty — an inactive host should be clean; resolve manually before takeover"
  git pull --ff-only || die "git pull --ff-only failed (history diverged?) — resolve manually"

  state="$(lock_state "$LOCK_FILE" "$HOST_ID")" || true
  case "$state" in
    free) : ;;
    self) info "lock already held by this host — continuing (idempotent takeover)" ;;
    held*)
      holder="$(printf '%s' "$state" | awk '{print $2}')"
      released="$(printf '%s' "$state" | awk '{print $3}')"
      if [ "$force" -eq 1 ]; then
        confirm_typed "Lock is held by '$holder' (released_clean=$released). Forcing takeover risks SPLIT-BRAIN."
        notify "⚠️" "FORCED takeover (lock was held by $holder)"
      else
        die "lock held by '$holder' (released_clean=$released) — run 'gtnh handover' there, or 'gtnh takeover --force'"
      fi ;;
    *) die "lock file unreadable — fix $LOCK_FILE manually" ;;
  esac

  case "$(probe_peer)" in
    open)
      die "peer ($PEER_HOST) is LISTENING on port $MC_PORT — split-brain prevented; aborting even though the lock allows takeover" ;;
    closed)
      info "peer reachable, port $MC_PORT closed — safe to proceed" ;;
    unreachable)
      warn "peer (${PEER_HOST:-?}) is UNREACHABLE on the tailnet — cannot verify it is not running the server."
      confirm_typed "Verify MANUALLY that the other machine is not running the server." ;;
    no-config)
      warn "PEER_HOST is not set in .env — peer probe skipped."
      confirm_typed "Verify MANUALLY that the other machine is not running the server." ;;
    no-tool)
      warn "nc is not installed — peer probe skipped (sudo apt install netcat-openbsd / it ships with macOS)."
      confirm_typed "Verify MANUALLY that the other machine is not running the server." ;;
  esac

  if [ "$state" != "self" ]; then
    lock_write "$HOST_ID" false "Takeover: claim by $HOST_ID" || die "could not commit the lock claim"
    if ! git push; then
      # The claim only counts once published. Undo it entirely — safe by
      # construction: the tree was clean, the commit is ours and unpushed,
      # and it touches only the lock file.
      git reset --hard HEAD~1
      notify "🔴" "takeover push FAILED on $HOST_ID — claim rolled back, server NOT started"
      die "push failed — claim NOT published and rolled back; fix connectivity and re-run takeover"
    fi
  fi

  "$SCRIPT_PATH" dns-update || {
    warn "dns-update failed — players may still resolve the old IP"
    notify "⚠️" "dns-update failed during takeover"
  }
  cmd_start
  notify "🟢" "takeover completed by $HOST_ID"
}
```

Dispatch cases:

```bash
  handover)       cmd_handover ;;
  takeover)       cmd_takeover "${2:-}" ;;
  _probe-peer)    probe_peer ;;
```

- [ ] **Step 4: Run tests; lint.**
- [ ] **Step 5: Commit** — `git add gtnh tests/run-tests.sh && git commit -m "Add handover/takeover with published-lock claim and peer probe"`

---

### Task 13: maintenance + deploy units

**Files:**
- Modify: `gtnh`
- Create: `deploy/gtnh-backup.service`, `deploy/gtnh-backup.timer`, `deploy/gtnh-maintenance.service`, `deploy/gtnh-maintenance.timer`, `deploy/com.gtnh.backup.plist`, `deploy/com.gtnh.maintenance.plist`

- [ ] **Step 1: Implement `cmd_maintenance`.** Add after the takeover section:

```bash
### ── maintenance (weekly git gc) ──────────────────────────────
cmd_maintenance() {
  cd "$SERVER_DIR" || die "cd failed"
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] maintenance start"
    git gc 2>&1
    echo "repo size: $(du -sh .git | cut -f1)"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] maintenance done"
  } >> "$MAINTENANCE_LOG" 2>&1
  tail -4 "$MAINTENANCE_LOG"
}
```

Dispatch case:

```bash
  maintenance)    cmd_maintenance ;;
```

- [ ] **Step 2: Create the systemd units** (Linux/Oracle — fixed paths are correct here):

`deploy/gtnh-backup.service`:

```ini
[Unit]
Description=GTNH V4 hourly git backup
After=network-online.target

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=/home/ubuntu/GTNH_V4
ExecStart=/home/ubuntu/GTNH_V4/gtnh backup
```

`deploy/gtnh-backup.timer`:

```ini
[Unit]
Description=Run GTNH backup hourly

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
```

`deploy/gtnh-maintenance.service`:

```ini
[Unit]
Description=GTNH V4 weekly git gc

[Service]
Type=oneshot
User=ubuntu
WorkingDirectory=/home/ubuntu/GTNH_V4
ExecStart=/home/ubuntu/GTNH_V4/gtnh maintenance
```

`deploy/gtnh-maintenance.timer`:

```ini
[Unit]
Description=Run GTNH maintenance weekly

[Timer]
OnCalendar=Sun 06:00
Persistent=true

[Install]
WantedBy=timers.target
```

(06:00 UTC = 03:00 BRT — quiet hour, avoids contending with a backup for git locks.)

- [ ] **Step 3: Create the launchd plists** (Mac — `@SERVER_DIR@` is rendered at install time, see OPERATIONS.md):

`deploy/com.gtnh.backup.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gtnh.backup</string>
  <key>ProgramArguments</key>
  <array>
    <string>@SERVER_DIR@/gtnh</string>
    <string>backup</string>
  </array>
  <key>WorkingDirectory</key><string>@SERVER_DIR@</string>
  <key>StartInterval</key><integer>3600</integer>
  <key>StandardOutPath</key><string>@SERVER_DIR@/backup.log</string>
  <key>StandardErrorPath</key><string>@SERVER_DIR@/backup.log</string>
</dict>
</plist>
```

`deploy/com.gtnh.maintenance.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gtnh.maintenance</string>
  <key>ProgramArguments</key>
  <array>
    <string>@SERVER_DIR@/gtnh</string>
    <string>maintenance</string>
  </array>
  <key>WorkingDirectory</key><string>@SERVER_DIR@</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>0</integer>
    <key>Hour</key><integer>3</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>@SERVER_DIR@/maintenance.log</string>
  <key>StandardErrorPath</key><string>@SERVER_DIR@/maintenance.log</string>
</dict>
</plist>
```

- [ ] **Step 4: Verify**

```bash
systemd-analyze verify ./deploy/gtnh-backup.service ./deploy/gtnh-maintenance.service 2>&1 | head
bash tests/run-tests.sh
shellcheck gtnh
```

Expected: no errors from systemd-analyze (warnings about the timer not being loaded are fine); tests green.

- [ ] **Step 5: Commit** — `git add gtnh deploy/ && git commit -m "Add weekly maintenance command and systemd/launchd schedule units"`

---

### Task 14: .env.example + OPERATIONS.md

**Files:**
- Create: `.env.example`, `OPERATIONS.md`

- [ ] **Step 1: Create `.env.example`:**

```bash
# Per-machine configuration for the gtnh CLI. Copy to .env and fill in.
# .env is gitignored — NEVER commit it.

# Identity of this machine in state/active-host.json: "oracle" or "mac".
HOST_ID=oracle

# Discord webhook for notifications. Empty = notifications silently skipped.
DISCORD_WEBHOOK_URL=

# RCON. The password is injected into server.properties by 'gtnh start';
# the live server.properties is gitignored so the secret never reaches git.
RCON_PASSWORD=
RCON_PORT=25575

# Cloudflare — the A record updated on takeover.
# Keep the record TTL at 60-120s so DNS propagation is fast after a takeover.
CF_API_TOKEN=
CF_ZONE_ID=
CF_RECORD_ID=
CF_RECORD_NAME=

# Tailnet IP or MagicDNS name of the OTHER machine (anti-split-brain probe).
PEER_HOST=
```

- [ ] **Step 2: Create `OPERATIONS.md`:**

```markdown
# GTNH V4 — Operations Runbook

The CLI is `./gtnh` (run `./gtnh help`). Per-machine config lives in `.env`
(copy `.env.example`). `./gtnh doctor` tells you what is missing on a machine.

## Daily flow

- The server runs on ONE machine at a time. `state/active-host.json` says which.
- `gtnh status` — process, port, lock, TPS.
- `gtnh console` — attach to the screen console (Ctrl+A, D to detach).
- `gtnh cmd "say hi"` / `gtnh tps` — RCON.
- Backups: hourly commit+push via systemd timer (Oracle) / launchd (Mac).
  `gtnh backup` runs one manually. The inactive machine's timer no-ops.
- Server config changes go in `server.properties.template` (the live
  `server.properties` is generated at start and is gitignored).

## Handover (active machine -> the other), both directions

On the ACTIVE machine:        `gtnh handover`
On the machine TAKING OVER:   `gtnh takeover`

`handover` = stop -> final backup -> release lock -> push -> Discord.
`takeover` = pull -> validate lock -> probe peer port 25565 -> claim lock ->
push (must succeed BEFORE anything starts) -> update DNS -> start -> Discord.

- If handover's push fails: the peer MUST NOT take over. Fix connectivity,
  re-run `gtnh handover` (idempotent — it just retries the publish).
- If takeover's push fails: the claim is rolled back and the server is NOT
  started. Re-run after connectivity returns.
- `--force` (start/takeover) requires typing the host id and notifies Discord.
  Use only when you are CERTAIN the other machine is not running the server.

## Rollback the world to a specific commit (server STOPPED)

1. `gtnh stop` (on the active machine).
2. Find the commit: `git log --oneline | head -30` (hourly "Auto backup" commits).
3. Safety branch: `git branch backup/pre-rollback-$(date +%Y%m%d)`.
4. `git reset --hard <commit>`.
5. `git push --force-with-lease` (never plain --force).
6. `gtnh start`.

## When a backup fails

- Commit failed / oversized file: changes stay STAGED; the next hourly run
  retries naturally. Nothing is lost.
- Push failed (orange Discord alert): the commit is local; next run retries.
- Stale `.git/index.lock` is auto-removed when older than 30 minutes.

### Oversized staged file (>90MB alert)

GitHub rejects blobs over 100MB; a committed oversized blob breaks every
future push permanently. The backup aborts BEFORE committing. Then:
- Noise file (cache/dump): add it to `.gitignore`, `git rm --cached <file>`.
- World data: this is the long-term-strategy trigger — see below.

## Long-term repo growth

`.git` was 50GB on 2026-06-11. Weekly `gtnh maintenance` (git gc) slows
growth but does not stop it. When clone/push pain gets real, pick one:
- **Truncate history**: archive everything to a `git bundle` stored OFF this
  machine, restart history from the current state, keep recent granularity.
- **Self-hosted remote** (no size limits): must NOT live on the machine that
  runs the server, or it stops being a backup against machine loss.

## New machine setup

1. Clone the repo, `cp .env.example .env`, fill it in.
2. `./gtnh doctor` and install what it lists
   (Mac: `brew install mcrcon`; Oracle: see deploy notes below).
3. Schedule backups:
   - Linux: `sudo cp deploy/gtnh-backup.* deploy/gtnh-maintenance.* /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now gtnh-backup.timer gtnh-maintenance.timer`
   - Mac: `sed "s|@SERVER_DIR@|$PWD|g" deploy/com.gtnh.backup.plist > ~/Library/LaunchAgents/com.gtnh.backup.plist && launchctl load -w ~/Library/LaunchAgents/com.gtnh.backup.plist` (same for `com.gtnh.maintenance.plist`).
4. mcrcon on Oracle: `git clone https://github.com/Tiiffi/mcrcon /tmp/mcrcon && make -C /tmp/mcrcon && sudo make -C /tmp/mcrcon install`.

## Security notes

- RCON (port 25575) has NO bind-address option in MC 1.7.10 — it listens on
  all interfaces. It must stay firewalled: on Oracle, the OCI security list
  and iptables must NOT open 25575; on the Mac, never port-forward it.
- DNS record TTL should stay at 60-120s (set to 120 by `gtnh dns-update`).
```

- [ ] **Step 3: Commit** — `git add .env.example OPERATIONS.md && git commit -m "Add .env.example and operations runbook"`

---

### Task 15: Provisioning block B — nc, mcrcon, tailscale (GATE)

- [ ] **Step 1: GATE — ask Augusto for confirmation, showing this exact block:**

```bash
sudo apt-get install -y netcat-openbsd build-essential
git clone https://github.com/Tiiffi/mcrcon /tmp/mcrcon && make -C /tmp/mcrcon && sudo make -C /tmp/mcrcon install
curl -fsSL https://tailscale.com/install.sh | sh
```

Run only after his OK (each line can be approved/declined independently). `tailscale up` is NOT run by Claude — Augusto runs it himself (interactive auth): suggest he types `! sudo tailscale up`.

- [ ] **Step 2: Verify** — `nc -h 2>&1 | head -1`, `mcrcon -v 2>&1 | head -1`, `tailscale version`. Then run `./gtnh doctor` — only `.env` items should remain missing (Augusto creates `.env`).

- [ ] **Step 3 (with Augusto): create `.env`** — he copies `.env.example`, fills HOST_ID=oracle + secrets. Confirm `./gtnh doctor` goes fully green. Verify `.env` is ignored: `git status --short` must NOT list `.env`.

- [ ] **Step 4: Firewall verification (read-only):**

```bash
sudo iptables -L INPUT -n | grep -E '25575|25565' || echo "no explicit rules"
```

Report findings: 25565 must be reachable publicly (existing setup), 25575 must NOT be. If 25575 looks exposed, flag to Augusto with the exact rule to add — do not change firewall rules without a GATE.

No commit (nothing in the repo changed).

---

### Task 16: Final verification + manual test checklist

- [ ] **Step 1: Full offline suite** — `bash tests/run-tests.sh` → all green. `shellcheck gtnh tests/run-tests.sh` → clean.

- [ ] **Step 2: Safe end-to-end checks on Oracle (server stays down):**

```bash
./gtnh doctor          # green except anything Augusto deferred
./gtnh status          # STOPPED + lock active=none
./gtnh backup          # commits/pushes pending changes or exits silently
./gtnh dns-update --dry-run   # shows current vs would-be IP, no PUT
./gtnh _probe-peer     # with PEER_HOST set: "unreachable" or "closed" (Mac off/on)
```

- [ ] **Step 3: GATE — Discord notify test.** Ask Augusto before firing: `./gtnh _notify "teste de notificação"` (external write).

- [ ] **Step 4: Hand Augusto the manual test checklist** (he drives; Claude observes):

1. **Oracle first start:** `./gtnh takeover` → expect: pull ok, lock free, probe (typed confirm if Mac unreachable), claim pushed, DNS updated, server starts. Watch with `./gtnh console`, `./gtnh status` (TPS via RCON once up).
2. **RCON:** `./gtnh cmd "list"`, `./gtnh tps`.
3. **Hot backup:** with the server running, `./gtnh backup` → commit appears, `save-on` restored (check `./gtnh cmd "save-on"` is a no-op / world keeps saving).
4. **Stop/start race check:** `./gtnh stop` → confirm in `restart.log` that the loop logged "Stop requested" and did NOT restart; `./gtnh start` brings it back.
5. **Crash counter:** optional — `./gtnh kill` then check the loop is gone (kill also writes the sentinel; no ghost restart).
6. **Handover to Mac:** Oracle `./gtnh handover`; Mac: clone/pull, `.env`, `./gtnh doctor`, `brew install mcrcon`, `./gtnh takeover` → DNS flips, server up on Mac. Then hand back to Oracle the same way.
7. **Timers:** enable both timers (OPERATIONS.md commands), check `systemctl list-timers | grep gtnh` and next-hour commit.

- [ ] **Step 5: Final summary to Augusto** — what passed, what was deferred (declined GATEs), and the reminder that old scripts are still in place until he approves removal.

---

## Out of scope

Phase 2 (web panel). Old-script removal (separate approval). History truncation / remote migration (documented options only).
