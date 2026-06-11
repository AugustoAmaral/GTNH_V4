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
