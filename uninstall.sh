#!/usr/bin/env bash
#
# uninstall.sh - remove wifi-watchdog.
#
#   ./uninstall.sh            remove the service and files, keep the config
#   ./uninstall.sh --purge    also delete the config file
set -euo pipefail

PREFIX=${PREFIX:-$HOME/.local}
CONFDIR=${XDG_CONFIG_HOME:-$HOME/.config}
UNITDIR=$CONFDIR/systemd/user
PURGE=0

for arg in "$@"; do
	case $arg in
	--purge) PURGE=1 ;;
	-h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)
		echo "unknown argument: $arg" >&2
		exit 2
		;;
	esac
done

if command -v systemctl >/dev/null 2>&1; then
	systemctl --user disable --now wifi-watchdog.service >/dev/null 2>&1 || true
fi

rm -f "$UNITDIR/wifi-watchdog.service" "$PREFIX/bin/wifi-watchdog.sh"
rm -rf "$PREFIX/share/wifi-watchdog"

if command -v systemctl >/dev/null 2>&1; then
	systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

if [ "$PURGE" -eq 1 ]; then
	rm -f "$CONFDIR/wifi-watchdog.conf"
	echo "removed files and config"
else
	echo "removed files; kept $CONFDIR/wifi-watchdog.conf (use --purge to delete it)"
fi
