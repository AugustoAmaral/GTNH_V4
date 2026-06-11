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

# ── Task 4: notify ────────────────────────────────────────────
t "notify without webhook is a silent no-op" 0 env GTNH_NO_ENV=1 DISCORD_WEBHOOK_URL= "$GTNH" _notify "test"
t "notify with failing webhook never fails caller" 0 env GTNH_NO_ENV=1 DISCORD_WEBHOOK_URL=http://127.0.0.1:9/ "$GTNH" _notify "test"

# ── Task 5: lock ──────────────────────────────────────────────
TMPLOCK="$(mktemp -d)"
printf '{"active":"none","since":"2026-06-11T00:00:00Z","released_clean":true}'   > "$TMPLOCK/free.json"
printf '{"active":"oracle","since":"2026-06-11T00:00:00Z","released_clean":false}' > "$TMPLOCK/oracle.json"
printf 'not json' > "$TMPLOCK/broken.json"
printf '{"since":"2026-06-11T00:00:00Z","released_clean":true}' > "$TMPLOCK/nokey.json"
printf '{"active":"","since":"2026-06-11T00:00:00Z","released_clean":true}' > "$TMPLOCK/empty.json"
t "lock free"                     0 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/free.json" oracle
contains "lock free prints free" "free" env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/free.json" oracle
t "lock self"                     0 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" oracle
contains "lock self prints self" "self" env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" oracle
t "lock held by other exits 1"    1 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" mac
contains "lock held names holder" "held oracle" env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" mac
t "broken lock exits 2"           2 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/broken.json" oracle
t "lock missing active key exits 2"  2 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/nokey.json" oracle
t "lock empty active exits 2"        2 env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/empty.json" oracle
contains "lock held includes released_clean" "held oracle false" env GTNH_NO_ENV=1 "$GTNH" _lock-check "$TMPLOCK/oracle.json" mac
rm -rf "$TMPLOCK"

# ── Task 6: properties render ─────────────────────────────────
TMPPROP="$(mktemp -d)"
t "render with password succeeds" 0 env GTNH_NO_ENV=1 RCON_PASSWORD=s3cret RCON_PORT=25575 \
  "$GTNH" _render-properties server.properties.template "$TMPPROP/out.properties"
contains "rendered file has the password" "rcon.password=s3cret" cat "$TMPPROP/out.properties"
contains "rendered file enables rcon"     "enable-rcon=true"     cat "$TMPPROP/out.properties"
contains "rendered file has the port"     "rcon.port=25575"      cat "$TMPPROP/out.properties"
t "render without password fails" 1 env GTNH_NO_ENV=1 RCON_PASSWORD= "$GTNH" _render-properties server.properties.template "$TMPPROP/out2.properties"
rm -rf "$TMPPROP"

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
