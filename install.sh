#!/usr/bin/env bash
#
# install.sh - install wifi-watchdog for the current user.
#
#   ./install.sh               install and enable the systemd user service
#   ./install.sh --no-service  install files only, do not touch systemd
#   PREFIX=/usr/local ./install.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PREFIX=${PREFIX:-$HOME/.local}
BIN=$PREFIX/bin
CONFDIR=${XDG_CONFIG_HOME:-$HOME/.config}
UNITDIR=$CONFDIR/systemd/user
DOCDIR=$PREFIX/share/wifi-watchdog
SERVICE=1

for arg in "$@"; do
	case $arg in
	--no-service) SERVICE=0 ;;
	-h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)
		echo "unknown argument: $arg" >&2
		exit 2
		;;
	esac
done

for tool in iw nmcli; do
	command -v "$tool" >/dev/null 2>&1 || echo "warning: $tool not found; the watchdog needs it at runtime" >&2
done

install -d "$BIN" "$UNITDIR" "$DOCDIR"
install -m 755 "$here/bin/wifi-watchdog.sh" "$BIN/wifi-watchdog.sh"
install -m 644 "$here/README.md" "$DOCDIR/README.md"
install -m 644 "$here/systemd/wifi-watchdog.service" "$UNITDIR/wifi-watchdog.service"

if [ -e "$CONFDIR/wifi-watchdog.conf" ]; then
	echo "keeping existing $CONFDIR/wifi-watchdog.conf"
else
	install -m 644 "$here/wifi-watchdog.conf.example" "$CONFDIR/wifi-watchdog.conf"
	echo "created $CONFDIR/wifi-watchdog.conf (edit MIN_RATE before trusting it)"
fi

echo "installed $BIN/wifi-watchdog.sh"

if [ "$SERVICE" -eq 1 ]; then
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user daemon-reload
		systemctl --user enable --now wifi-watchdog.service
		echo "service enabled; follow it with: journalctl --user -u wifi-watchdog -f"
	else
		echo "systemctl not found; run the script by hand or under your own supervisor" >&2
	fi
else
	echo "start it with: $BIN/wifi-watchdog.sh --dry-run"
fi
