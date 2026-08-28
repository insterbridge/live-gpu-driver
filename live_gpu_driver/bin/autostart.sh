#!/system/bin/sh
# autostart.sh — one entry point for every activation path (service.sh,
# late-load.sh, boot-completed.sh, WebUI "Apply"). Makes the CURRENTLY
# configured mode active:
#   PERAPP_PKGS set -> drop any global mounts, start the per-app watcher
#   otherwise       -> apply the global mount
# Safe to call repeatedly; everything is idempotent.
# Output goes to engine.log; the EXIT CODE tells callers whether the
# mounts actually landed (the engine verifies each mount).
MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." && pwd)}
CFG="$MODDIR/config"
PERAPP_PKGS=""
[ -f "$CFG" ] && . "$CFG"

if [ -n "$PERAPP_PKGS" ]; then
  # stale global mounts would leak the driver to ALL apps — drop them
  # first (no-op when nothing is mounted), then run the watcher
  GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" unmount >>"$MODDIR/engine.log" 2>&1
  sh "$MODDIR/bin/perapp.sh" start >>"$MODDIR/engine.log" 2>&1
else
  GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" mount >>"$MODDIR/engine.log" 2>&1
  rc=$?
  if [ "$rc" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: global mount FAILED (exit $rc) — driver NOT active" >> "$MODDIR/engine.log"
    exit "$rc"
  fi
fi
exit 0
