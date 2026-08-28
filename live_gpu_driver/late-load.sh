#!/system/bin/sh
# late-load.sh — KernelSU late-load mode's replacement for
# post-fs-data.sh (runs during `ksud late-load`, before OverlayFS).
# No-op if your solution never runs module scripts.
MODDIR=${MODDIR:-$(cd "$(dirname "$0")" && pwd)}
sh "$MODDIR/bin/autostart.sh" >/dev/null 2>&1
exit 0
