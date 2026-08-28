#!/system/bin/sh
# uninstall.sh — cleanly undo runtime mounts + stop the watcher before
# the module is removed. Never fails the uninstall.
MODDIR=${MODDIR:-$(cd "$(dirname "$0")" && pwd)}
sh "$MODDIR/bin/perapp.sh" stop >/dev/null 2>&1
GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" unmount >/dev/null 2>&1
exit 0
