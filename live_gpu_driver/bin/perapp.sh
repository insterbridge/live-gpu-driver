#!/system/bin/sh
#
# perapp.sh — per-app GPU driver watcher for live_gpu_driver
#
# Keeps the STOCK driver everywhere except the packages you list in
# config (PERAPP_PKGS). Whenever one of those apps starts, the custom
# driver is bind-mounted into THAT process's private mount namespace
# only. Unlisted apps (launcher, camera, banking, ...) are never
# touched. Mounts die with the process — nothing to clean up.
#
# How it catches process starts without Zygisk:
#   * an initial sweep mounts into already-running target processes
#   * `logcat` is watched for "Start proc <pid>:<pkg>/..." lines, which
#     system_server emits for every process AMS brings up; the mount is
#     applied right after the process gets its private mount namespace
#     (apps unshare their namespace during zygote specialization).
#   * the engine refuses to mount into any process still sharing
#     init/zygote's namespace, so a race can never leak the driver
#     globally.
#
# If the app loads its GPU driver before the mount lands (slow device,
# flooded logcat), you get a log note — restart the app. Zygisk
# (ReZygisk/OnyxZygisk, ptrace-based, late-load compatible) is the
# perfect-timing alternative if you want zero races.
#
# Subcommands: start | stop | restart | status | sweep | loop
#
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
CFG="$MODDIR/config"
PERAPP_PKGS=""
[ -f "$CFG" ] && . "$CFG"
LOG="$MODDIR/engine.log"
PIDFILE="$MODDIR/.watcher.pid"
ENGINE="$MODDIR/bin/gpu_mount.sh"
STAGE="$MODDIR/.staging"
GM_ROOT=${GM_ROOT:-}

pa_log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watcher] $*" >> "$LOG"; }

# first payload file (from the engine's payload list) + the source file
# the engine would actually serve (payload or staged copy)
pa_probe() { # -> "src|dst"
  [ -f "$MODDIR/.saved.mlist" ] || { sed -n '1p' "$MODDIR/.list" 2>/dev/null; return; }
  gm_first=$(sed -n '1p' "$MODDIR/.list" 2>/dev/null)
  [ -n "$gm_first" ] || return 0
  gm_src=${gm_first%%|*}; gm_dst=${gm_first#*|}
  while IFS='|' read -r s d k; do
    [ "$k" = "dir" ] || continue
    case "$gm_dst" in "$d"/*)
      gm_src="$STAGE$(echo "$d" | sed 's|/|_|g')/${gm_dst#"$d"/}"
      break ;;
    esac
  done < "$MODDIR/.saved.mlist"
  echo "$gm_src|$gm_dst"
}

# does pid $1 currently SEE the custom driver? (compare the payload
# file with the one visible through the pid's mount namespace)
pa_has_driver() { # $1=pid
  gm_p=$(pa_probe)
  [ -n "$gm_p" ] || return 1
  gm_src=${gm_p%%|*}; gm_dst=${gm_p#*|}
  [ -n "$gm_src" ] || return 1
  cmp -s "$gm_src" "/proc/$1/root${GM_ROOT}${gm_dst}" 2>/dev/null
}


pa_alive() { # pid
  [ -n "$1" ] && [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null
}

pa_zyns() { # echo readable init/zygote mount-namespace ids
  gm_out=""
  for z in 1 $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null); do
    n=$(readlink "/proc/$z/ns/mnt" 2>/dev/null) && gm_out="$gm_out $n"
  done
  echo "$gm_out"
}

pa_mount_pid() { # $1=pid  $2=label(package name)
  pid=$1; pkg=$2
  [ -d "/proc/$pid" ] || return 0
  zns=$(pa_zyns)
  # wait for the process to leave the zygote namespace (up to ~2s)
  i=0
  while [ $i -lt 40 ]; do
    [ -d "/proc/$pid" ] || return 0
    pns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || return 0
    case "$zns" in *" $pns "*) sleep 0.05; i=$((i+1)); continue ;; esac
    break
  done
  pns=$(readlink "/proc/$pid/ns/mnt" 2>/dev/null) || return 0
  case "$zns" in *" $pns "*)
    pa_log "skip $pkg/$pid: no private mount namespace (not an app process?)"
    return 0
    ;;
  esac
  # heads-up if the app already mapped a GPU driver (mount came too late)
  if grep -qE "vulkan\.|libEGL_" "/proc/$pid/maps" 2>/dev/null; then
    pa_log "note $pkg/$pid: GPU libs already mapped — restart the app to fully apply"
  fi
  GM_QUIET=1 sh "$ENGINE" ns "$pid" >/dev/null 2>&1
  if pa_has_driver "$pid"; then
    pa_log "driver mounted for $pkg (pid $pid)"
  else
    pa_log "FAILED mounting driver for $pkg (pid $pid) — see engine.log"
  fi
}

pa_handle_line() { # $1 = one logcat line
  line=$1
  case "$line" in *"Start proc "*) ;; *) return 0 ;; esac
  rest=${line#*Start proc }
  pid=${rest%%:*}
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  pkgfull=${rest#*:}; pkgfull=${pkgfull%%/*}
  pkg=${pkgfull%%:*}
  case " $PERAPP_PKGS " in *" $pkg "*) pa_mount_pid "$pid" "$pkgfull" ;; esac
}

pa_pkg_match() { # $1=cmdline  $2=pkg -> true if process belongs to pkg
  first=${1%% *}
  case "$first" in "$2"|"$2":*) return 0 ;; esac
  return 1
}

pa_sweep() { # mount into already-running target processes
  [ -n "$PERAPP_PKGS" ] || return 0
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    cmd=$({ tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null) || continue
    [ -n "$cmd" ] || continue
    for pkg in $PERAPP_PKGS; do
      pa_pkg_match "$cmd" "$pkg" && pa_mount_pid "$p" "$pkg"
    done
  done
}

pa_loop() {
  echo $$ > "$PIDFILE"
  rm -f "$MODDIR/.sweep.done"
  pa_log "watcher started for:$(echo $PERAPP_PKGS | sed 's/ /, /g')"
  pa_sweep
  : > "$MODDIR/.sweep.done"
  LOGCAT=$(command -v logcat || echo /system/bin/logcat)
  # -T 1: only events from now on; -v raw: message text only
  "$LOGCAT" -T 1 -v raw 2>/dev/null | while IFS= read -r line; do
    pa_handle_line "$line"
  done
  pa_log "watcher loop exited (logcat died?) — restart with: perapp.sh start"
  rm -f "$PIDFILE" "$MODDIR/.sweep.done"
}

pa_start() {
  [ -n "$PERAPP_PKGS" ] || { echo "PERAPP_PKGS is empty — set it in $CFG"; exit 1; }
  pa_stop >/dev/null 2>&1
  rm -f "$MODDIR/.sweep.done"
  setsid sh "$0" loop >/dev/null 2>&1 &
  # wait for the watcher to come up AND finish its initial sweep, so
  # callers (WebUI set-pkgs) see accurate state on return
  i=0
  while [ $i -lt 60 ]; do
    if [ -f "$PIDFILE" ] && pa_alive "$(cat "$PIDFILE")"; then
      [ -f "$MODDIR/.sweep.done" ] && break
    else
      # died before finishing the sweep
      [ $i -gt 10 ] && break
    fi
    sleep 0.1
    i=$((i+1))
  done
  if [ -f "$PIDFILE" ] && pa_alive "$(cat "$PIDFILE")"; then
    echo "watcher running (pid $(cat "$PIDFILE")) for: $(echo $PERAPP_PKGS | sed 's/ /, /g')"
  else
    echo "watcher failed to start — see $LOG"
    exit 1
  fi
}

pa_stop() {
  if [ -f "$PIDFILE" ]; then
    w=$(cat "$PIDFILE")
    kill -TERM -- "-$w" 2>/dev/null   # whole group incl. logcat child
    kill -TERM "$w" 2>/dev/null
    rm -f "$PIDFILE"
    echo "watcher stopped"
    return 0
  fi
  for p in $(pgrep -f "perapp.sh loop" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    kill -TERM -- "-$p" 2>/dev/null
    kill -TERM "$p" 2>/dev/null
  done
  echo "watcher not running"
  return 0
}

pa_status() {
  if [ -f "$PIDFILE" ] && pa_alive "$(cat "$PIDFILE")"; then
    echo "watcher: RUNNING (pid $(cat "$PIDFILE")) targets: $(echo $PERAPP_PKGS | sed 's/ /, /g')"
  else
    echo "watcher: not running"
  fi
  # show which target-app processes currently SEE the custom driver
  # (mountinfo can't be used: bind sources are recorded fs-relative)
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    cmd=$({ tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null) || continue
    [ -n "$cmd" ] || continue
    for pkg in $PERAPP_PKGS; do
      if pa_pkg_match "$cmd" "$pkg"; then
        if pa_has_driver "$p"; then
          echo "  $p  ${cmd%% *}  [custom driver]"
        else
          echo "  $p  ${cmd%% *}  [stock driver]"
        fi
      fi
    done
  done
}

case "${1:-}" in
  start)   pa_start ;;
  stop)    pa_stop ;;
  restart) pa_stop >/dev/null 2>&1; pa_start ;;
  status)  pa_status ;;
  sweep)   pa_sweep; echo "sweep done" ;;
  loop)    pa_loop ;;
  *) echo "usage: perapp.sh start|stop|restart|status|sweep"; exit 1 ;;
esac
exit 0
