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
t "render rejects sed-hostile password" 1 env GTNH_NO_ENV=1 'RCON_PASSWORD=pa&ss' \
  "$GTNH" _render-properties server.properties.template "$TMPPROP/out3.properties"
t "render with missing template fails" 1 env GTNH_NO_ENV=1 RCON_PASSWORD=s3cret \
  "$GTNH" _render-properties /nonexistent.template "$TMPPROP/out4.properties"
contains "rendered file keeps verbatim lines" "level-name=World" cat "$TMPPROP/out.properties"
t "failed renders leave no output file" 1 test -e "$TMPPROP/out3.properties"
rm -rf "$TMPPROP"

# ── Task 7: rcon ──────────────────────────────────────────────
t "gtnh cmd without args fails"                     1 env GTNH_NO_ENV=1 "$GTNH" cmd
t "gtnh cmd fails cleanly (no mcrcon or no server)" 1 env GTNH_NO_ENV=1 RCON_PASSWORD=x "$GTNH" cmd "list"
t "rcon_cmd unconfigured returns 1 quietly" 1 env GTNH_NO_ENV=1 RCON_PASSWORD= "$GTNH" _rcon list
TMPRCON="$(mktemp -d)"
printf '#!/bin/sh\nexit 42\n' > "$TMPRCON/mcrcon"
chmod +x "$TMPRCON/mcrcon"
t "rcon_cmd propagates mcrcon exit status" 42 env GTNH_NO_ENV=1 RCON_PASSWORD=x PATH="$TMPRCON:$PATH" "$GTNH" _rcon list
rm -rf "$TMPRCON"
TMPRCON2="$(mktemp -d)"
# shellcheck disable=SC2016  # $MCRCON_PASS must reach the shim unexpanded
printf '#!/bin/sh\n[ "$MCRCON_PASS" = "sekret" ] || exit 9\nexit 0\n' > "$TMPRCON2/mcrcon"
chmod +x "$TMPRCON2/mcrcon"
t "rcon_cmd passes password via MCRCON_PASS env" 0 env GTNH_NO_ENV=1 RCON_PASSWORD=sekret PATH="$TMPRCON2:$PATH" "$GTNH" _rcon list
rm -rf "$TMPRCON2"

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

# ── Task 11: dns ──────────────────────────────────────────────
t "dns-update without config fails" 1 env GTNH_NO_ENV=1 "$GTNH" dns-update --dry-run
contains "dns-update lists missing vars" "CF_API_TOKEN" env GTNH_NO_ENV=1 "$GTNH" dns-update --dry-run
TMPCURL="$(mktemp -d)"
cat > "$TMPCURL/curl" <<'SHIM'
#!/bin/sh
# fake curl for dns tests: ipify -> fixed IP; CF GET -> record JSON; log PUTs
case "$*" in
  *ipify*)            echo "203.0.113.7" ;;
  *-X\ PUT*)          echo "PUT" >> "${CURL_SHIM_LOG:?}"; echo '{"success":true}' ;;
  *cloudflare*)       echo '{"result":{"content":"198.51.100.1"}}' ;;
  *)                  exit 1 ;;
esac
SHIM
chmod +x "$TMPCURL/curl"
contains "dns dry-run reports would-update" "would update mc.test: 198.51.100.1 -> 203.0.113.7" \
  env GTNH_NO_ENV=1 PATH="$TMPCURL:$PATH" CURL_SHIM_LOG="$TMPCURL/puts.log" \
  CF_API_TOKEN=t CF_ZONE_ID=z CF_RECORD_ID=r CF_RECORD_NAME=mc.test \
  "$GTNH" dns-update --dry-run
t "dns dry-run never PUTs" 1 test -f "$TMPCURL/puts.log"
t "dns rejects unknown flag" 1 env GTNH_NO_ENV=1 PATH="$TMPCURL:$PATH" \
  CF_API_TOKEN=t CF_ZONE_ID=z CF_RECORD_ID=r CF_RECORD_NAME=mc.test \
  "$GTNH" dns-update --dry
rm -rf "$TMPCURL"

# ── Task 12: handover/takeover guards ─────────────────────────
contains "probe without PEER_HOST says no-config" "no-config" env GTNH_NO_ENV=1 PEER_HOST= "$GTNH" _probe-peer

# ── Task 13: maintenance ──────────────────────────────────────
TMPGC="$(mktemp -d)"
# shellcheck disable=SC2016  # $1/$@ must reach the shim unexpanded
printf '#!/bin/sh\nif [ "$1" = "gc" ]; then echo "fatal: gc shim"; exit 128; fi\nexec /usr/bin/git "$@"\n' > "$TMPGC/git"
printf '#!/bin/sh\nprintf "50G\\t.git\\n"\n' > "$TMPGC/du"
chmod +x "$TMPGC/git" "$TMPGC/du"
t "maintenance fails loudly when gc fails" 1 env GTNH_NO_ENV=1 DISCORD_WEBHOOK_URL= PATH="$TMPGC:$PATH" "$GTNH" maintenance
rm -rf "$TMPGC"

echo "---"
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
