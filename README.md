# wifi-watchdog

Reconnects your Wi-Fi when the negotiated link rate collapses.

Some APs leave a client stuck on a legacy rate: the PHY falls back to 54 Mbit/s during a bad
moment and never climbs back, so throughput stays poor and latency stays high until the client
reassociates. This watches the negotiated rate and performs that reassociation for you, with
debouncing so it does not flap your connection in a loop.

## Requirements

- Linux with NetworkManager (`nmcli`)
- `iw`
- No root: it only needs permission to bring a NetworkManager connection down and up, which a
  normal desktop user has for their own connections.

## Install

```sh
git clone <this repo> ~/Projects/wifi-watchdog
cd ~/Projects/wifi-watchdog
./install.sh
```

That copies:

| From | To |
| --- | --- |
| `bin/wifi-watchdog.sh` | `~/.local/bin/wifi-watchdog.sh` |
| `wifi-watchdog.conf.example` | `~/.config/wifi-watchdog.conf` (never overwrites) |
| `systemd/wifi-watchdog.service` | `~/.config/systemd/user/` |
| `README.md` | `~/.local/share/wifi-watchdog/` |

and enables the systemd **user** service. Use `./install.sh --no-service` to install files only,
or `PREFIX=/usr/local ./install.sh` for a system-wide path.

Without the installer, the script is standalone: `bin/wifi-watchdog.sh --dry-run`.

## Usage

```sh
wifi-watchdog.sh                    # watch, using the config file
wifi-watchdog.sh --dry-run          # log decisions, never touch the link
wifi-watchdog.sh --once             # one sample: rate=81000 signal=-68 ssid=Home
wifi-watchdog.sh --help
```

## Configuration

`~/.config/wifi-watchdog.conf` (see `wifi-watchdog.conf.example`), or `CONF=/etc/...` for another
path. Environment variables of the same name win over the file, so
`MIN_RATE=40000 wifi-watchdog.sh` works without editing anything.

| Key | Default | Meaning |
| --- | --- | --- |
| `IFACE` | first wireless interface | interface to watch |
| `MIN_RATE` | `60000` | reconnect below this rate, in kbit/s |
| `STRIKES` | `2` | consecutive bad samples needed before acting |
| `INTERVAL` | `15` | seconds between samples |
| `IDLE_SKIP` | `30000` | ignore links idle longer than this, in ms |
| `COOLDOWN` | `120` | minimum seconds between reconnects |
| `LOGFILE` | none | append log lines to a file as well as stdout |

## How it decides

Every `INTERVAL` it reads the TX rate from `iw dev <iface> station dump`.

1. Not associated → nothing to do.
2. Rate at or above `MIN_RATE` → reset the strike counter.
3. Rate below `MIN_RATE` → increment strikes, but skip entirely if the interface has been idle
   longer than `IDLE_SKIP` (idle links report stale low rates, and reconnecting an unused link is
   pure churn).
4. Strikes reach `STRIKES` → reconnect, then do not reconnect again for `COOLDOWN` seconds.

The idle check and the cooldown are what keep it from becoming a flapping loop on a link that is
simply weak all the time.

## Choosing a threshold

Do not guess. Sample for a while first:

```sh
for i in $(seq 60); do wifi-watchdog.sh --once; sleep 30; done
```

Then put `MIN_RATE` between your healthy and degraded rates. Example from the network this was
written on — a 2.4 GHz N300 AP:

| State | Signal | TX rate |
| --- | --- | --- |
| healthy | −68 dBm | 81 Mbit/s |
| stuck | −78 dBm | 45 Mbit/s |

`MIN_RATE=60000` catches the stuck state there. If your link normally sits at 45 Mbit/s, 60000
would fire constantly — which means the watchdog is not your problem, coverage is. Confirm the
rate before turning it on for real:

```sh
wifi-watchdog.sh --dry-run
```

## Operating it

```sh
systemctl --user status wifi-watchdog
journalctl --user -u wifi-watchdog -f
systemctl --user restart wifi-watchdog
```

Log lines look like:

```
2026-11-18 08:09:31 degraded 1/1: rate=45000kbit/s signal=-68dBm
2026-11-18 08:09:31 reconnecting (connection: Anyafulu)
2026-11-18 08:09:43 after reconnect: ssid=Anyafulu rate=45000kbit/s signal=-68dBm
```

The `after reconnect` line is the honest bit: it tells you whether the reconnect actually helped.

## Uninstall

```sh
./uninstall.sh           # keeps your config
./uninstall.sh --purge   # removes it too
```

## Limitations

- Reconnecting does not always restore the rate. On the network this was built for, one
  reassociation took the link from 54 → 81 Mbit/s and another left it at 45 Mbit/s minutes later.
  Treat this as a mitigation for a stuck rate adapter, not a fix for weak signal or a slow ISP.
- A link that is genuinely below the threshold all the time will be reconnected once per
  `COOLDOWN` forever. Raise `STRIKES`, lower `MIN_RATE`, or fix the underlying cause.
- NetworkManager only. No `wpa_supplicant`-direct or `systemd-networkd` support.
- The rate is the *negotiated* PHY rate, not measured throughput.

## Tests

```sh
make check
```

The suite runs the real script against fake `iw` and `nmcli` binaries in `tests/fake`, so it
covers parsing, validation, strike counting, idle skipping and cooldown without touching a
network. It does not need a wireless card.
