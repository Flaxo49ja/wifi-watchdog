#!/usr/bin/env bash
#
# wifi-watchdog.sh - reconnect Wi-Fi when the negotiated link rate collapses.
#
# Watches the negotiated TX rate and forces a reassociation when it falls below
# a threshold, because some APs leave the client stuck on a legacy rate and
# never let it climb back on its own.
#
# Usage:
#   wifi-watchdog.sh              watch with settings from the config file
#   wifi-watchdog.sh --dry-run    log what it would do, never touch the link
#   wifi-watchdog.sh --once       print one sample and exit (for tuning)
#   wifi-watchdog.sh --help
#
# Environment overrides the config file:
#   CONF       config file   (default: $XDG_CONFIG_HOME/wifi-watchdog.conf)
#   IFACE      interface     (default: first wireless interface found)
#   MIN_RATE   kbit/s        (default: 60000)
#   STRIKES    bad samples   (default: 2)
#   INTERVAL   seconds       (default: 15)
#   IDLE_SKIP  idle ms       (default: 30000)
#   COOLDOWN   seconds       (default: 120)
#   LOGFILE    append log    (default: none)

set -uo pipefail

VERSION=0.1.0
PROG=${0##*/}
CONF=${CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/wifi-watchdog.conf}
DRY_RUN=0
ONCE=0

usage() {
	cat <<'EOF'
Watch the Wi-Fi link rate and reconnect when it falls below a threshold.

Usage:
  wifi-watchdog.sh [options]

Options:
  --dry-run     log what would happen, never reconnect
  --once        print one sample as "rate=... signal=... ssid=..." and exit
  -h, --help    show this help
  -V, --version show version

Settings come from the config file (see wifi-watchdog.conf.example) and can be
overridden by environment variables of the same name.
EOF
}

for arg in "$@"; do
	case $arg in
	--dry-run) DRY_RUN=1 ;;
	--once) ONCE=1 ;;
	-h | --help) usage; exit 0 ;;
	-V | --version) echo "$PROG $VERSION"; exit 0 ;;
	*)
		echo "unknown argument: $arg (try --help)" >&2
		exit 2
		;;
	esac
done

# Only these keys may be set from a config file, and a value already present in
# the environment always wins.
load_conf() {
	local f=$1 line k v
	[ -r "$f" ] || return 0
	while IFS= read -r line; do
		case $line in '' | '#'*) continue ;; esac
		k=${line%%=*}
		v=${line#*=}
		k=${k//[[:space:]]/}
		v=${v%$'\r'}
		v=${v#"${v%%[![:space:]]*}"}
		v=${v%"${v##*[![:space:]]}"}
		case $k in
		IFACE | MIN_RATE | STRIKES | INTERVAL | IDLE_SKIP | COOLDOWN | LOGFILE) ;;
		*) continue ;;
		esac
		eval "[ -n \"\${$k:-}\" ]" && continue
		eval "$k=\$v"
	done <"$f"
}

load_conf "$CONF"

MIN_RATE=${MIN_RATE:-60000}
STRIKES=${STRIKES:-2}
INTERVAL=${INTERVAL:-15}
IDLE_SKIP=${IDLE_SKIP:-30000}
COOLDOWN=${COOLDOWN:-120}
LOGFILE=${LOGFILE:-}
IFACE=${IFACE:-}

for pair in "MIN_RATE:$MIN_RATE" "STRIKES:$STRIKES" "INTERVAL:$INTERVAL" \
	"IDLE_SKIP:$IDLE_SKIP" "COOLDOWN:$COOLDOWN"; do
	case ${pair#*:} in
	'' | *[!0-9]*)
		echo "error: ${pair%%:*} must be a whole number (got '${pair#*:}')" >&2
		exit 2
		;;
	esac
done
if [ "$MIN_RATE" -le 0 ] || [ "$STRIKES" -le 0 ] || [ "$INTERVAL" -le 0 ]; then
	echo "error: MIN_RATE, STRIKES and INTERVAL must be greater than zero" >&2
	exit 2
fi

log() {
	local line
	line="$(date '+%Y-%m-%d %T') $*"
	printf '%s\n' "$line"
	[ -n "$LOGFILE" ] && printf '%s\n' "$line" >>"$LOGFILE"
}

for tool in iw nmcli; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		if [ "$tool" = iw ]; then
			echo "error: iw not found (install the 'iw' package)" >&2
		else
			echo "error: nmcli not found (this script drives NetworkManager)" >&2
		fi
		exit 1
	fi
done

IFACE=${IFACE:-$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')}
if [ -z "$IFACE" ]; then
	echo "error: no wireless interface found" >&2
	exit 1
fi

TX_RATE=0
SIGNAL="?"
INACTIVE=0
SSID=""

# iw prints "<label>:\t<value>", so strip the label and take the first field.
sample() {
	local link dump
	link=$(iw dev "$IFACE" link 2>/dev/null)
	SSID=$(printf '%s\n' "$link" | sed -n 's/^[[:space:]]*SSID: //p' | head -1)
	dump=$(iw dev "$IFACE" station dump 2>/dev/null)

	# "tx bitrate:\t81.0 MBit/s MCS 4 40MHz" -> 81000
	TX_RATE=$(printf '%s\n' "$dump" | awk '
		/tx bitrate:/ { sub(/.*tx bitrate:[ \t]+/, ""); split($0, a, " "); printf "%.0f", a[1] * 1000; exit }')
	# "signal:  \t-74 [-74, -78] dBm" -> -74
	SIGNAL=$(printf '%s\n' "$dump" | awk '
		/signal:/ { sub(/.*signal:[ \t]+/, ""); split($0, a, " "); print a[1]; exit }')
	# "inactive time:\t1735 ms" -> 1735
	INACTIVE=$(printf '%s\n' "$dump" | awk '
		/inactive time:/ { sub(/.*inactive time:[ \t]+/, ""); split($0, a, " "); printf "%.0f", a[1]; exit }')

	: "${TX_RATE:=0}"
	: "${SIGNAL:=?}"
	: "${INACTIVE:=0}"
}

reconnect() {
	local con
	con=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null |
		awk -F: -v d="$IFACE" '$2 == d { print $1; exit }')

	log "reconnecting (connection: ${con:-$SSID})"
	if [ "$DRY_RUN" -eq 1 ]; then
		log "dry-run: would run nmcli connection down/up '${con:-$SSID}'"
		return 0
	fi

	if [ -n "${con:-}" ]; then
		nmcli connection down "$con" >/dev/null 2>&1
		sleep 3
		nmcli connection up "$con" >/dev/null 2>&1
	else
		nmcli device disconnect "$IFACE" >/dev/null 2>&1
		sleep 3
		nmcli device connect "$IFACE" >/dev/null 2>&1
	fi

	sleep 8
	sample
	log "after reconnect: ssid=${SSID:-?} rate=${TX_RATE}kbit/s signal=${SIGNAL}dBm"
}

if [ "$ONCE" -eq 1 ]; then
	sample
	if [ -z "$SSID" ]; then
		echo "not associated on $IFACE" >&2
		exit 1
	fi
	echo "rate=${TX_RATE} signal=${SIGNAL} ssid=${SSID} inactive=${INACTIVE}"
	exit 0
fi

mode=live
[ "$DRY_RUN" -eq 1 ] && mode=dry-run
log "watching $IFACE: reconnect below ${MIN_RATE} kbit/s after $STRIKES bad samples (interval ${INTERVAL}s, cooldown ${COOLDOWN}s, idle skip ${IDLE_SKIP}ms, $mode)"

strikes=0
last_action=0
sample
log "start: ssid=${SSID:-?} rate=${TX_RATE}kbit/s signal=${SIGNAL}dBm"

trap 'log "stopped"; exit 0' INT TERM

while :; do
	sleep "$INTERVAL"
	now=$(date +%s)
	sample

	if [ -z "$SSID" ]; then
		log "not associated on $IFACE"
		strikes=0
		continue
	fi

	if [ "$TX_RATE" -gt 0 ] && [ "$TX_RATE" -lt "$MIN_RATE" ]; then
		if [ "$INACTIVE" -gt "$IDLE_SKIP" ]; then
			# Idle links report stale/low rates; reconnecting would be noise.
			strikes=0
			continue
		fi
		strikes=$((strikes + 1))
		log "degraded $strikes/$STRIKES: rate=${TX_RATE}kbit/s signal=${SIGNAL}dBm"
	else
		strikes=0
	fi

	if [ "$strikes" -ge "$STRIKES" ]; then
		if [ $((now - last_action)) -lt "$COOLDOWN" ]; then
			log "cooldown active ($((COOLDOWN - (now - last_action)))s left), not reconnecting"
			strikes=0
			continue
		fi
		reconnect
		last_action=$(date +%s)
		strikes=0
	fi
done
