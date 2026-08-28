#!/system/bin/sh
# action.sh — the manager's Action button. Quick "re-apply after reboot"
# tap. For everything else (driver selection, mode, per-app, status,
# logs) use the WebUI.
MODDIR=$(cd "$(dirname "$0")" && pwd)
CFG="$MODDIR/config"
PERAPP_PKGS=""
[ -f "$CFG" ] && . "$CFG"

if [ "${1:-}" = "unmount" ]; then
  sh "$MODDIR/bin/perapp.sh" stop >/dev/null 2>&1
  GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" unmount >/dev/null 2>&1
  echo "Stock driver restored. Restart apps to fall back."
  exit 0
fi

sh "$MODDIR/bin/autostart.sh" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  echo "Driver applied ✓"
  echo "Restart apps to pick it up."
else
  echo "Apply FAILED — run doctor:"
  echo "  su -c sh $MODDIR/bin/webui_ctl.sh doctor"
fi
