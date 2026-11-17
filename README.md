# Roblox ARM64 Launcher

A lightweight, locked-down Linux launcher and `.deb` installer package for
ARM64 (aarch64) single-board computers and mini-PCs running **Ubuntu**,
**Debian**, **Armbian** or **Raspberry Pi OS (64-bit)**, with an
**install.sh fallback for Arch-based distros** such as Orange Pi OS (Arch).

It runs the official **Android Roblox client** inside a hidden, debloated,
Google-free **VANILLA Waydroid** container, wrapped in **gamescope** for true
PC mouse-locking and full-screen scaling. No Google account is ever needed:
**Aurora Store in anonymous mode** installs and silently auto-updates the
official ARM64 Roblox split-APKs from Google's servers without wiping login
tokens. The container is kept **unrooted** for anti-cheat compatibility, and
Android UI mode is forced to **normal** so it never glitches into a
console/TV UI.

## Feature map (blueprint coverage)

| # | Blueprint item | Where |
|---|---|---|
| 1 | Hardware/OS gatekeeper: aarch64 + ARMv8.2+/v9 cores (Cortex-A76/A78/A715/A720; RK3588, A733, BCM2712/Pi 5, CIX P1), Qualcomm/Adreno blocked, A53/A55 warning, Waydroid apt repo, Pi 16K->4K page kernel switch | `src/lib/gatekeeper.sh`, `src/lib/distro.sh` |
| 2 | Hidden debloated VANILLA Android: `waydroid init -s VANILLA`, hidden `~/.local/share/.roblox-runtime/`, no Android UI/icons, extended debloat, image read-only (`--hard`), only `/data/data/com.roblox.client` preserved | `src/lib/waydroid_init.sh`, `src/lib/debloat.sh` |
| 3 | Anonymous auto-updates via Aurora Store | `src/lib/aurora.sh` |
| 4 | PC mode: `fake_touch ""`, `uevent true`, DPI 160, `cursor_on_subsurface true`, gamescope wrap with mouse-lock, HDMI-CEC | `src/lib/waydroid_init.sh`, `src/lib/run.sh`, `src/lib/cec.sh` |
| 5 | Bridges: `~/Pictures/Roblox` -> `/sdcard/Pictures/Roblox`, PipeWire audio, `roblox` + `roblox-player` scheme handlers | `src/lib/distro.sh`, `src/lib/waydroid_init.sh`, `packaging/` |
| 6 | BIOS-style perf mode: CPU + GPU (Mali/Panfrost/Panthor devfreq) + DDR governors -> performance, `cmd power set-fixed-performance-mode-enabled true`, PID monitor, full revert to schedutil + container stop on exit | `src/lib/perf.sh`, `src/lib/run.sh` |
| 7 | Clean `.deb` (roblox-arm64-launcher.deb) with a single plain monochrome Roblox icon in the app menu | `packaging/`, `build-deb.sh` |

## Quickstart (Debian family)

```bash
# on the SBC
sudo apt install ./roblox-arm64-launcher.deb   # or: ./install.sh
roblox-launcher setup                          # one-time, ~10-20 min
roblox-launcher play                           # or click "Roblox" in the app menu
```

First run: if Roblox is not installed yet, Aurora Store opens automatically.
Sign in happens **anonymously** (no Google account); search "Roblox",
install it, and the game starts by itself. For silent background updates
enable *Settings -> Updates -> Automatic app updates* in Aurora once.

**Raspberry Pi 5 note:** setup detects the 16K-page kernel, switches
`/boot/firmware/config.txt` to `kernel=kernel8.img` (4K pages, required by
the Android binder) and demands a reboot before playing.

## Quickstart (Arch-based: Orange Pi OS Arch, Arch Linux ARM)

```bash
./install.sh        # pacman: gamescope, libcec, pipewire; AUR: waydroid
roblox-launcher setup
roblox-launcher play
```

## Browser integration ("Play" button on roblox.com)

The package registers `x-scheme-handler/roblox` and
`x-scheme-handler/roblox-player`. Clicking **Play** on the Roblox website
launches the game directly:

```bash
xdg-open "roblox-player:1+launchtime:..."   # what the website triggers
roblox-launcher play "roblox-player:..."    # equivalent, manual form
```

## Commands

| Command | Purpose |
|---|---|
| `roblox-launcher setup [--hard]` | One-time gated setup (resumable per stage) |
| `roblox-launcher play [URI]` | Start session (deep link supported) |
| `roblox-launcher stop` | Stop session + container, revert governors |
| `roblox-launcher status` | Container/session/PID/perf snapshot |
| `roblox-launcher doctor` | Full diagnostics report |
| `roblox-launcher update` | Open Aurora Store (anonymous) |
| `roblox-launcher app install F.apk [F2.apk ...]` | Sideload APKs (splits OK) |
| `roblox-launcher config set KEY VAL` | Tune runtime (see `--help`) |
| `roblox-launcher reset-data` | Wipe all app data except Roblox + Aurora |
| `roblox-launcher reset-container` | Re-initialize VANILLA from scratch |
| `roblox-launcher debloat-restore` | Undo reversible debloating |
| `roblox-launcher uninstall [--purge-android]` | Remove runtime (and Android) |

## Design notes

- **Zero background processes.** `waydroid-container.service` is disabled at
  boot; the launcher starts it on demand and stops it when the Roblox PID
  exits. CPU/GPU/DDR governors are saved, locked to `performance`, and
  reverted (default `schedutil`) on every exit path, including crashes
  (EXIT/INT/TERM traps + supervisor sweep).
- **Hidden by design.** Runtime state lives in `~/.local/share/.roblox-runtime/`
  (state, backups, logs, cache). No Android home screen, no Waydroid icons:
  desktop entries are masked and only `com.roblox.client` (plus Aurora for
  updates) is ever launched.
- **Unrooted container.** `ro.debuggable=0`, `ro.secure=1`,
  `ro.build.tags=release-keys`, no `su` binary, no root-granting apps; the
  launcher never enables adb-root. Anti-cheat systems (e.g. in Rivals) see a
  plain user build. No tool can *guarantee* passing every anti-cheat check,
  but the environment stays as clean as a stock user image.
- **UI mode.** `cmd uimode type normal` + `cmd uimode night no` run at every
  session start, so Android never switches into TV/console UI mode.
- **Display auto-detect.** gamescope nested inside a Wayland session,
  gamescope from X11 (best effort), gamescope DRM from a TTY (true console
  mode), or a direct Waydroid window as fallback. Mouse-lock uses
  `--force-grab-cursor` when the installed gamescope supports it; XWayland is
  disabled when possible (Waydroid is Wayland-native).
- **Gamescope flags are version-guarded**: the runner queries
  `gamescope --help` and only passes flags your build understands.

## Configuration

`roblox-launcher config set KEY VALUE` - keys (defaults):

```
DPI=160              RESOLUTION=auto      FPS=auto
GAMESCOPE=auto       FULLSCREEN=1         VRR=0
CEC_ON_LAUNCH=0      CEC_STANDBY_EXIT=0   CEC_DEVICE=auto
KEEP_CONTAINER_SERVICE=0
```

Example: lock the gamescope buffer to 1080p/60 and turn on TV standby on
exit:

```bash
roblox-launcher config set RESOLUTION 1920x1080
roblox-launcher config set FPS 60
roblox-launcher config set CEC_STANDBY_EXIT 1
```

### Fullscreen

Fullscreen is the default (`FULLSCREEN=1`):

- **With gamescope** (installed automatically by `setup` on Debian and by
  `install.sh` on Arch): the session runs in a true borderless fullscreen
  gamescope window, scaled to your display. From a TTY, gamescope's DRM
  backend takes over the whole screen.
- **Without gamescope** (direct Waydroid window): the Android window is
  chrome-less; maximize it with your compositor's shortcut (GNOME/KDE:
  Super+Up), or install gamescope to get automatic borderless fullscreen.

Run windowed instead: `roblox-launcher config set FULLSCREEN 0`.

## Troubleshooting

- **`gamescope` exits immediately**: you are on X11 without nested support,
  or lack DRM/seat permissions from a TTY. Use a Wayland session, or check
  `roblox-launcher doctor` and logs in `~/.local/share/.roblox-runtime/logs/`.
- **No audio**: ensure `pipewire-pulse` is active (`pactl info` shows
  PipeWire). Waydroid talks to the PulseAudio compatibility socket.
- **Screenshots not appearing**: the bind-mount is verified during setup;
  re-check with `roblox-launcher doctor` under "Host bridges".
- **Roblox never appears after Aurora install**: keep the window open; the
  launcher polls for up to 30 minutes. Check `logs/roblox-crash.log` if the
  game closes within seconds.
- **binder errors on Pi 5**: confirm 4K pages (`getconf PAGE_SIZE` ->
  4096) after the reboot.

## Uninstall

```bash
roblox-launcher uninstall --purge-android   # removes runtime + Android data
sudo dpkg -r roblox-arm64-launcher          # remove the package (deb path)
sudo apt purge waydroid                     # optional: remove Waydroid itself
```

## License

MIT - see `packaging/copyright` (installed under
`/usr/share/doc/roblox-arm64-launcher/copyright`).
