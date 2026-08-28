#!/system/bin/sh
# customize.sh — KernelSU/APatch/Magisk module installer script.
# Runs at INSTALL time (from the manager app), which works fine even
# with late-loaded KernelSU: module installation only needs a root
# shell, not boot-time magic mount.

SKIPUNZIP=0

command -v ui_print >/dev/null 2>&1 || ui_print() {
  echo "ui_print $1" > /proc/self/fd/${OUTFD:-1}
  echo "ui_print "   > /proc/self/fd/${OUTFD:-1}
}

MODID_NEW=live_gpu_driver
OLD_DIR=/data/adb/modules/$MODID_NEW

ui_print "************************************"
ui_print " Live GPU Driver Mount"
ui_print " runtime bind-mount driver swapper"
ui_print "************************************"
ui_print " Detected: ro.hardware.egl      = $(getprop ro.hardware.egl)"
ui_print " Detected: ro.hardware.vulkan   = $(getprop ro.hardware.vulkan)"
ui_print " arch=$ARCH sdk=$API"

chmod 0755 "$MODPATH"/*.sh "$MODPATH/bin/"*.sh 2>/dev/null

# --- migrate payload/ (driver drop-zone) into system/ mirror -------------
if [ -d "$MODPATH/payload" ]; then
  (
    cd "$MODPATH/payload" || exit 1
    find . \( -type f -o -type l \) | while IFS= read -r f; do
      f=${f#./}
      case "$f" in README*|*.txt|*.md) continue ;; esac
      mkdir -p "$MODPATH/system/$(dirname "$f")"
      cp -f "$MODPATH/payload/$f" "$MODPATH/system/$f" || ui_print " ! copy failed: $f"
      ui_print " + driver file: /$f"
    done
  )
  rm -rf "$MODPATH/payload"
fi

# --- sanity: does the payload reference paths that exist? ----------------
FILES=$(cd "$MODPATH" && { [ -d system ] && cd system && find . \( -type f -o -type l \); } 2>/dev/null | grep -v -E '^\./(\.placeholder|.*\.(txt|md|log))$' | wc -l)
if [ "$FILES" = "0" ]; then
  ui_print " No driver embedded — normal for this module now."
  ui_print " Open the module WebUI and pick a driver zip from"
  ui_print " /sdcard/Download (any AdrenoToolsDrivers package:"
  ui_print " Turnip or Qualcomm). Swap drivers anytime, no reflash."
else
  ui_print " Payload: $FILES file(s)"
  sh "$MODPATH/bin/gpu_mount.sh" plan 2>/dev/null | sed 's/^/  /' | while IFS= read -r l; do ui_print "$l"; done
fi

# --- stop previous watcher + undo previous mounts ------------------------
if [ -d "$OLD_DIR" ]; then
  ui_print " Cleaning up previous installation..."
  sh "$OLD_DIR/bin/perapp.sh" stop >/dev/null 2>&1
  GM_QUIET=1 sh "$OLD_DIR/bin/gpu_mount.sh" unmount >/dev/null 2>&1
fi

# --- activate NOW so a reboot isn't even needed ---------------------------
PERAPP_PKGS=""
[ -f "$MODPATH/config" ] && . "$MODPATH/config"
if [ "$FILES" != "0" ]; then
  if [ -n "$PERAPP_PKGS" ]; then
    ui_print " Per-app mode: starting watcher for:"
    for p in $PERAPP_PKGS; do ui_print "    $p"; done
    sh "$MODPATH/bin/perapp.sh" start 2>/dev/null | while IFS= read -r l; do ui_print "$l"; done
    ui_print " (launch/restart those apps to pick up the driver)"
  else
    ui_print " Global mode: applying mounts..."
    sh "$MODPATH/bin/gpu_mount.sh" mount 2>/dev/null | while IFS= read -r l; do ui_print "$l"; done
  fi
fi

ui_print ""
ui_print " IMPORTANT — late-loaded KernelSU notes:"
ui_print "  * After EVERY reboot (once KSU is loaded) re-apply:"
ui_print "      tap 'Action' in the manager, or"
ui_print "      su -c sh /data/adb/modules/$MODID_NEW/action.sh"
ui_print "  * Running apps keep the old driver until restarted."
ui_print "  * Restore stock driver: action.sh unmount"
