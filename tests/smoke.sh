#!/usr/bin/env bash
#
# smoke.sh - test wifi-watchdog without touching the real Wi-Fi.
#
# Fake `iw` and `nmcli` are put first on PATH, so the script exercises its real
# parsing and decision logic against canned link data. Nothing here reconnects
# a network.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
wd=$root/bin/wifi-watchdog.sh
fake=$here/fake
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

chmod +x "$fake"/* 2>/dev/null
export PATH=$fake:$PATH
export CONF=$tmp/absent.conf
export FAKE_NMCLI_LOG=$tmp/nmcli.log
: >"$FAKE_NMCLI_LOG"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}
no() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'
}

# assert <description> <haystack> <needle>
assert_has() {
	if grep -qF -- "$3" <<<"$2"; then ok "$1"; else no "$1" "expected to find: $3"$'\n'"output: $2"; fi
}
assert_lacks() {
	if grep -qF -- "$3" <<<"$2"; then no "$1" "did not expect: $3"$'\n'"output: $2"; else ok "$1"; fi
}
assert_rc() {
	if [ "$2" -eq "$3" ]; then ok "$1"; else no "$1" "expected exit $3, got $2"; fi
}

reset_env() {
	unset IFACE MIN_RATE STRIKES INTERVAL IDLE_SKIP COOLDOWN LOGFILE
	unset FAKE_IFACE FAKE_SSID FAKE_RATE FAKE_SIGNAL FAKE_IDLE FAKE_CON
	: >"$FAKE_NMCLI_LOG"
}

echo "== static checks =="
if bash -n "$wd"; then ok "syntax"; else no "syntax"; fi

out=$("$wd" --help 2>&1); rc=$?
assert_rc "--help exits 0" "$rc" 0
assert_has "--help shows usage" "$out" "Usage:"

out=$("$wd" --version 2>&1); rc=$?
assert_rc "--version exits 0" "$rc" 0
assert_has "--version prints a version" "$out" "0.1.0"

out=$("$wd" --nope 2>&1); rc=$?
assert_rc "unknown flag exits 2" "$rc" 2
assert_has "unknown flag explains itself" "$out" "unknown argument"

echo "== config and validation =="
reset_env
out=$(MIN_RATE=fast "$wd" --once 2>&1); rc=$?
assert_rc "non-numeric MIN_RATE rejected" "$rc" 2
assert_has "validation names the bad key" "$out" "MIN_RATE"

reset_env
cat >"$tmp/ok.conf" <<'EOF'
# comment
MIN_RATE = 40000
STRIKES=3

BOGUS_KEY=1
EOF
out=$(CONF=$tmp/ok.conf "$wd" --once 2>&1); rc=$?
assert_rc "config file is accepted" "$rc" 0
out=$(CONF=$tmp/ok.conf MIN_RATE=abc "$wd" --once 2>&1); rc=$?
assert_rc "environment overrides config" "$rc" 2

echo "== sampling =="
reset_env
out=$(FAKE_RATE=81000 FAKE_SIGNAL=-68 "$wd" --once 2>&1); rc=$?
assert_rc "--once on a healthy link exits 0" "$rc" 0
assert_has "--once reports the rate" "$out" "rate=81000"
assert_has "--once reports the signal" "$out" "signal=-68"
assert_has "--once reports the ssid" "$out" "ssid=Anyafulu"

reset_env
out=$(FAKE_SSID= "$wd" --once 2>&1); rc=$?
assert_rc "--once while unassociated exits 1" "$rc" 1
assert_has "--once says it is unassociated" "$out" "not associated"

echo "== decisions (dry-run) =="
reset_env
out=$(MIN_RATE=999999 STRIKES=1 INTERVAL=1 COOLDOWN=60 FAKE_IDLE=10 \
	timeout 5 "$wd" --dry-run 2>&1)
assert_has "low rate triggers a reconnect" "$out" "dry-run: would run nmcli connection down/up 'Anyafulu'"
assert_lacks "dry-run never calls nmcli" "$(cat "$FAKE_NMCLI_LOG")" "connection down"

reset_env
out=$(MIN_RATE=50000 STRIKES=1 INTERVAL=1 timeout 4 "$wd" --dry-run 2>&1)
assert_lacks "healthy rate does not trigger" "$out" "reconnecting"

reset_env
out=$(MIN_RATE=999999 STRIKES=1 INTERVAL=1 IDLE_SKIP=1000 FAKE_IDLE=600000 \
	timeout 5 "$wd" --dry-run 2>&1)
assert_lacks "idle links are skipped" "$out" "degraded"

reset_env
out=$(MIN_RATE=999999 STRIKES=5 INTERVAL=1 COOLDOWN=60 FAKE_IDLE=10 \
	timeout 4 "$wd" --dry-run 2>&1)
assert_lacks "strikes below the threshold do not trigger" "$out" "reconnecting"

echo "== decisions (live, fake nmcli) =="
reset_env
out=$(MIN_RATE=999999 STRIKES=1 INTERVAL=1 COOLDOWN=60 FAKE_IDLE=10 \
	timeout 18 "$wd" 2>&1)
assert_has "live run reconnects the active connection" "$(cat "$FAKE_NMCLI_LOG")" "nmcli connection down Anyafulu"
assert_has "live run brings the connection back up" "$(cat "$FAKE_NMCLI_LOG")" "nmcli connection up Anyafulu"
assert_has "live run reports the post-reconnect rate" "$out" "after reconnect:"

reset_env
out=$(MIN_RATE=999999 STRIKES=1 INTERVAL=1 COOLDOWN=9999 FAKE_IDLE=10 \
	timeout 18 "$wd" 2>&1)
assert_has "cooldown blocks a second reconnect" "$out" "cooldown active"
downs=$(grep -c "connection down" "$FAKE_NMCLI_LOG")
if [ "$downs" -eq 1 ]; then ok "cooldown limited reconnects to exactly one"; else no "cooldown limited reconnects to exactly one" "got $downs down-calls"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
