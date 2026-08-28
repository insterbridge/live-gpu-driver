#!/system/bin/sh
#
# gpu_mount.sh — live GPU-driver replacement engine
#
# Replaces vendor GPU driver files at RUNTIME with bind mounts.
# No OverlayFS / Magic Mount / boot-time KernelSU required — this is
# designed for LATE-LOADED KernelSU (or APatch/Magisk-style late root),
# where module system files never get magic-mounted.
#
# How it works:
#   * driver payload lives in   $MODDIR/system/<mirror-of-real-path>
#     e.g.  system/vendor/lib64/hw/vulkan.adreno.so
#   * each payload file is bind-mounted over its real path
#   * payload files that do NOT exist yet on the real filesystem are
#     handled by staging a merged copy of the parent directory
#     (originals + payload) in $MODDIR/.staging and bind-mounting that
#     dir over the real dir — no overlayfs needed
#   * mounts are applied INSIDE the mount namespaces of init (pid 1),
#     zygote/zygote64 and surfaceflinger, so every process forked
#     afterwards (all apps fork from zygote) resolves the new files.
#     With --all, mounts are also pushed into every running namespace.
#   * SELinux labels are cloned from the original files so app
#     processes keep permission to map/execute the replacement
#
# Subcommands: mount | unmount | status | plan     (default: mount)
# Option:       --all   enter every running mount namespace, not just
#                      init/zygote/surfaceflinger
#
# Testing overrides (not needed on a real device):
#   GM_ROOT       prefix for all real paths (default "")
#   GM_TEST_PIDS  replace the target pid set (default: 1 + zygotes + sf)
#   GM_MARKER     mountinfo marker that identifies our mounts
#                 (default: module id)
# ---------------------------------------------------------------------------

MODDIR=$(cd "$(dirname "$0")/.." && pwd) || exit 1
LOG="$MODDIR/engine.log"
STAGE="$MODDIR/.staging"
PAY="$MODDIR/system"
MODID=live_gpu_driver
GM_ROOT=${GM_ROOT:-}
GM_TEST_PIDS=${GM_TEST_PIDS:-}
GM_MARKER=${GM_MARKER:-$MODID}
GM_QUIET=${GM_QUIET:-0}

# defaults; $MODDIR/config may override
ALL_NS=0
RESTART_SF=0
CFG="$MODDIR/config"
[ -f "$CFG" ] && . "$CFG"

CMD=mount
GM_NS_PID=""
gm_prev=""
for gm_arg in "$@"; do
  if [ "$gm_prev" = "ns" ]; then
    GM_NS_PID=$gm_arg
    gm_prev=""
    continue
  fi
  case "$gm_arg" in
    mount|unmount|status|plan|ns|selftest) CMD=$gm_arg; gm_prev=$gm_arg ;;
    --all) ALL_NS=1 ;;
  esac
done

if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  : > "$LOG"
fi

gm_log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
  [ "$GM_QUIET" = 1 ] || echo "$*"
}
gm_warn() { gm_log "WARN: $*"; }
gm_die()  { gm_log "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------ tools --
gm_tool_dirs="/system/bin /system/xbin /vendor/bin /data/adb/ksu/bin /data/adb/ap/bin /data/adb/magisk /sbin /usr/bin /usr/local/bin /bin"
gm_which() {
  for gm_c in "$@"; do
    for gm_d in $gm_tool_dirs; do
      [ -x "$gm_d/$gm_c" ] && { echo "$gm_d/$gm_c"; return 0; }
    done
    gm_p=$(command -v "$gm_c" 2>/dev/null)
    [ -n "$gm_p" ] && { echo "$gm_p"; return 0; }
  done
  return 1
}

GM_MOUNT=$(gm_which mount)    || gm_die "mount not found"
GM_UMOUNT=$(gm_which umount)  || GM_UMOUNT=""
GM_NSENTER=$(gm_which nsenter) || GM_NSENTER=""
GM_BB=$(gm_which busybox)     || GM_BB=""
GM_CP=$(gm_which cp)          || gm_die "cp not found"
GM_FIND=$(gm_which find)      || gm_die "find not found"
GM_LS=$(gm_which ls)          || gm_die "ls not found"
GM_STAT=$(gm_which stat)      || GM_STAT=""
GM_CHCON=$(gm_which chcon)    || GM_CHCON=""
GM_GREP=$(gm_which grep)      || gm_die "grep not found"
GM_DIRNAME=$(gm_which dirname) || gm_die "dirname not found"
GM_PIDOF=$(gm_which pidof)    || GM_PIDOF=""
GM_PGREP=$(gm_which pgrep)    || GM_PGREP=""
GM_MV=$(gm_which mv)          || gm_die "mv not found"
GM_CMP=$(gm_which cmp)        || GM_CMP=""

if [ -z "$GM_NSENTER" ] && [ -z "$GM_BB" ]; then
  [ "$CMD" = plan ] || gm_die "no nsenter binary found (need toybox nsenter or busybox)"
fi

# run a shell command inside the mount namespace of pid $1
gm_ns_run() { # $1=pid  $2=shell-command
  if [ -n "$GM_NSENTER" ]; then
    "$GM_NSENTER" -t "$1" -m -- sh -c "$2"
  elif [ -n "$GM_BB" ]; then
    "$GM_BB" nsenter -t "$1" -m -- sh -c "$2"
  else
    return 1
  fi
}

[ "$(id -u 2>/dev/null)" = "0" ] || gm_die "must run as root (su)"

# ---------------------------------------------------------------- payload --
# State files are shared across CONCURRENT engine invocations (mount /
# status / watcher). All writes are atomic (tmp file + mv) so a reader
# always sees either the old or the new content — never a truncated file.
LIST="$MODDIR/.list"
gm_tmp="$MODDIR/.list.tmp.$$"
: > "$gm_tmp"
if [ -d "$PAY" ]; then
  ( cd "$PAY" && "$GM_FIND" . \( -type f -o -type l \) ) 2>/dev/null \
  | while IFS= read -r gm_r; do
      [ -n "$gm_r" ] || continue
      gm_r=${gm_r#./}
      case "$gm_r" in
        .placeholder|.placeholder/*|*.md|*.txt|*.log|*.bak) continue ;;
      esac
      echo "$PAY/$gm_r|/$gm_r" >> "$gm_tmp"
    done
fi
mv -f "$gm_tmp" "$LIST"
GM_COUNT=$(wc -l < "$LIST" 2>/dev/null || echo 0)

# ------------------------------------------------------------------ plan ---
# classify payload: per-file binds (target exists) vs staged dirs
# (target missing -> merged copy of nearest existing parent dir)
GM_FPLAN="$MODDIR/.plan.files"
GM_SPLAN="$MODDIR/.plan.dirs"

gm_build_plan() {
  # atomic: write to tmp, then mv — concurrent status calls also touch
  # these files and a torn write would corrupt the plan
  gm_ftmp="$GM_FPLAN.tmp.$$"; gm_stmp="$GM_SPLAN.tmp.$$"
  : > "$gm_ftmp"; : > "$gm_stmp"
  gm_orph=""
  while IFS='|' read -r gm_src gm_dst; do
    [ -n "$gm_src" ] || continue
    if [ -e "${GM_ROOT}${gm_dst}" ] || [ -L "${GM_ROOT}${gm_dst}" ]; then
      echo "$gm_src|$gm_dst" >> "$gm_ftmp"
    else
      gm_d=$("$GM_DIRNAME" "$gm_dst")
      gm_guard=0
      while [ -n "$gm_d" ] && [ ! -d "${GM_ROOT}${gm_d}" ]; do
        gm_d=$("$GM_DIRNAME" "$gm_d")
        gm_guard=$((gm_guard+1)); [ $gm_guard -gt 12 ] && { gm_d=""; break; }
      done
      [ -n "$gm_d" ] && gm_orph="$gm_orph $gm_d"
    fi
  done < "$LIST"

  # unique
  gm_uniq=""
  for gm_d in $gm_orph; do
    case " $gm_uniq " in *" $gm_d "*) ;; *) gm_uniq="$gm_uniq $gm_d" ;; esac
  done
  # keep only outermost dirs (drop dirs nested inside another staged dir)
  gm_final=""
  for gm_d in $gm_uniq; do
    gm_nested=0
    for gm_e in $gm_uniq; do
      [ "$gm_d" = "$gm_e" ] && continue
      case "$gm_d" in "$gm_e"/*) gm_nested=1; break ;; esac
    done
    [ $gm_nested = 0 ] && gm_final="$gm_final $gm_d"
  done
  # drop per-file entries already covered by a staged dir
  if [ -n "$gm_final" ]; then
    gm_ptmp="$MODDIR/.plan.tmp2.$$"; : > "$gm_ptmp"
    while IFS='|' read -r gm_src gm_dst; do
      gm_cov=0
      for gm_d in $gm_final; do
        case "$gm_dst" in "$gm_d"/*) gm_cov=1; break ;; esac
      done
      [ $gm_cov = 0 ] && echo "$gm_src|$gm_dst" >> "$gm_ptmp"
    done < "$gm_ftmp"
    mv -f "$gm_ptmp" "$gm_ftmp"
    for gm_d in $gm_final; do echo "$gm_d" >> "$gm_stmp"; done
  fi
  mv -f "$gm_ftmp" "$GM_FPLAN"
  mv -f "$gm_stmp" "$GM_SPLAN"
}

# ordered mount list: staged dirs first, then per-file binds.
# line format:  src|dst|kind   (kind = "dir" for staged dirs, "file" otherwise)
gm_mount_list() {
  GM_MLIST="$MODDIR/.mlist"
  gm_mtmp="$MODDIR/.mlist.tmp.$$"
  : > "$gm_mtmp"
  while IFS= read -r gm_d; do
    [ -n "$gm_d" ] || continue
    echo "$STAGE$(echo "$gm_d" | sed 's|/|_|g')|$gm_d|dir" >> "$gm_mtmp"
  done < "$GM_SPLAN"
  while IFS='|' read -r gm_src gm_dst; do
    [ -n "$gm_src" ] || continue
    echo "$gm_src|$gm_dst|file" >> "$gm_mtmp"
  done < "$GM_FPLAN"
  mv -f "$gm_mtmp" "$GM_MLIST"
}

# ----------------------------------------------------- persistent plan -----
# The plan is saved and reused as long as the payload is unchanged.
# This keeps re-runs idempotent: classification must NEVER be redone on a
# view that already contains our mounts (a staged dir makes new payload
# files look like "existing" ones). When the payload changed, old mounts
# are undone first so classification sees the pristine filesystem.
GM_SAVED=0
gm_state_same_list() { # is saved.list identical to current LIST?
  [ -f "$MODDIR/.saved.list" ] || return 1
  if [ -n "$GM_CMP" ]; then
    "$GM_CMP" -s "$MODDIR/.saved.list" "$LIST"
  else
    [ "$(cat "$MODDIR/.saved.list" 2>/dev/null)" = "$(cat "$LIST" 2>/dev/null)" ]
  fi
}
gm_state_load() { # reuse saved mlist; fills GM_SPLAN/GM_FPLAN/GM_MLIST
  gm_state_same_list || return 1
  [ -s "$MODDIR/.saved.mlist" ] || return 1
  gm_ftmp="$GM_FPLAN.tmp.$$"; gm_stmp="$GM_SPLAN.tmp.$$"
  : > "$gm_ftmp"; : > "$gm_stmp"
  while IFS='|' read -r gm_src gm_dst gm_kind; do
    [ -n "$gm_dst" ] || continue
    if [ "$gm_kind" = "dir" ]; then
      echo "$gm_dst" >> "$gm_stmp"
    else
      echo "$gm_src|$gm_dst" >> "$gm_ftmp"
    fi
  done < "$MODDIR/.saved.mlist"
  mv -f "$gm_ftmp" "$GM_FPLAN"
  mv -f "$gm_stmp" "$GM_SPLAN"
  GM_MLIST="$MODDIR/.saved.mlist"
  GM_SAVED=1
  return 0
}
gm_state_save() {
  "$GM_CP" -f "$LIST" $MODDIR/.saved.list.tmp.$$
  "$GM_CP" -f "$GM_MLIST" $MODDIR/.saved.mlist.tmp.$$
  mv -f $MODDIR/.saved.list.tmp.$$ "$MODDIR/.saved.list"
  mv -f $MODDIR/.saved.mlist.tmp.$$ "$MODDIR/.saved.mlist"
}
gm_prepare_plan() { # mount flow entry: reuse or (unmount +) rebuild
  if gm_state_load; then
    gm_log "reusing saved mount plan (payload unchanged)"
    return 0
  fi
  if [ -s "$MODDIR/.saved.mlist" ]; then
    gm_log "payload changed — undoing previous mounts first"
    GM_MLIST="$MODDIR/.saved.mlist"
    gm_unmount
  fi
  gm_build_plan
  gm_mount_list
  gm_state_save
}

# ------------------------------------------------------------ selinux ------
gm_is_label() {
  case "$1" in
    u:object_r:*:*|*:*:s[0-9]*|*:*:c[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}
gm_label_of() { # path -> label or "" (ls -Z with stat -c %C fallback)
  gm_l=$("$GM_LS" -Z "$1" 2>/dev/null | awk 'NR==1{print $1}')
  gm_is_label "$gm_l" || gm_l=""
  if [ -z "$gm_l" ] && [ -n "$GM_STAT" ]; then
    gm_l=$("$GM_STAT" -c '%C' "$1" 2>/dev/null)
    gm_is_label "$gm_l" || gm_l=""
  fi
  echo "$gm_l"
}
gm_sibling_label() { # logical dir -> label of first sibling file, or ""
  for gm_f in "${GM_ROOT}$1"/*; do
    [ -e "$gm_f" ] || [ -L "$gm_f" ] || continue
    gm_l=$(gm_label_of "$gm_f")
    [ -n "$gm_l" ] && { echo "$gm_l"; return 0; }
    return 1
  done
  return 1
}

# clone original labels onto payload sources; make every payload file
# world-readable (zip-stored modes are untrustworthy: an unreadable .so
# makes apps' dlopen fail -> "no vulkan device"); verify chcon stuck.
GM_WANT="$MODDIR/.want"
gm_label_fail=0
gm_relabel_payload() {
  gm_wtmp="$MODDIR/.want.tmp.$$"
  : > "$gm_wtmp"
  gm_def="u:object_r:same_process_hal_file:s0"
  while IFS='|' read -r gm_src gm_dst; do
    [ -n "$gm_src" ] || continue
    chmod a+rX "$gm_src" 2>/dev/null
    # label priority: exact original > known GPU lib in same dir > HAL default.
    # NEVER fall back to a random sibling: many /vendor/lib64 files carry the
    # generic vendor_file label, which the sphal linker DENIES for HAL
    # loading -> "library not found" -> "no vulkan device" (the exact bug
    # that made every Qualcomm driver package fail system-wide)
    gm_l=$(gm_label_of "${GM_ROOT}${gm_dst}")
    if [ -z "$gm_l" ]; then
      # try a KNOWN GPU library in the same directory (not any sibling)
      for gm_ref in libgsl.so libadreno_utils.so libCB.so; do
        gm_l=$(gm_label_of "${GM_ROOT}$("$GM_DIRNAME" "$gm_dst")/$gm_ref")
        [ -n "$gm_l" ] && break
      done
    fi
    # if still empty or generic vendor_file, use the HAL label — every file
    # we ship is a GPU HAL library that apps must be able to dlopen
    if [ -z "$gm_l" ] || [ "$gm_l" = "u:object_r:vendor_file:s0" ]; then
      gm_l="$gm_def"
    fi
    if [ -n "$GM_CHCON" ]; then
      "$GM_CHCON" "$gm_l" "$gm_src" 2>>"$LOG" \
        || gm_warn "chcon failed on $gm_src — apps may be denied access"
      # VERIFY: a label that didn't stick is a guaranteed app-side
      # dlopen failure — detect it instead of shipping it silently
      gm_now=$(gm_label_of "$gm_src")
      if [ -n "$gm_now" ] && [ "$gm_now" != "$gm_l" ]; then
        gm_label_fail=$((gm_label_fail+1))
        gm_warn "label mismatch on $(basename "$gm_src"): wanted $gm_l, got $gm_now"
      fi
    fi
    echo "$gm_src|$gm_dst|$gm_l" >> "$gm_wtmp"
  done < "$LIST"
  mv -f "$gm_wtmp" "$GM_WANT"
  if [ "$gm_label_fail" -gt 0 ]; then
    gm_warn "$gm_label_fail payload file(s) have WRONG labels — apps may"
    gm_warn "  fail to load the driver (\"no vulkan device\")."
    gm_warn "  the module's sepolicy.rule fallback covers this once loaded:"
    gm_warn "  reboot once after installing the module if you haven't, then"
    gm_warn "  re-apply. (No need to set the device permissive.)"
  fi
}

# ------------------------------------------------------------ staging ------
gm_build_staging() {
  rm -rf "$STAGE" 2>/dev/null
  [ -s "$GM_SPLAN" ] || return 0
  mkdir -p "$STAGE" || gm_die "cannot create $STAGE"
  while IFS= read -r gm_d; do
    [ -n "$gm_d" ] || continue
    gm_s="$STAGE$(echo "$gm_d" | sed 's|/|_|g')"
    mkdir -p "$gm_s"
    gm_log "staging merged dir for $gm_d (payload introduces new filenames)"
    if [ -d "${GM_ROOT}${gm_d}" ]; then
      "$GM_CP" -a "${GM_ROOT}${gm_d}/." "$gm_s/" 2>>"$LOG" \
        || gm_warn "copying contents of $gm_d failed"
    fi
    # overlay payload files that belong to this dir
    while IFS='|' read -r gm_src gm_dst; do
      case "$gm_dst" in "$gm_d"/*) ;; *) continue ;; esac
      gm_sub=${gm_dst#"$gm_d"/}
      mkdir -p "$gm_s/$(dirname "$gm_sub")"
      "$GM_CP" -f "$gm_src" "$gm_s/$gm_sub" 2>>"$LOG" \
        || gm_warn "copying payload $gm_src failed"
    done < "$LIST"
    # fix permissions + labels on ALL staged files:
    # - chmod a+rX: zip-stored modes are often 0600 (root-only) which
    #   makes apps' dlopen fail with "library not found" (THE bug that
    #   broke every Qualcomm package system-wide)
    # - chcon: new files get same_process_hal_file (the label apps need
    #   to load GPU HAL libs); originals keep their stock labels
    gm_dl=$(gm_label_of "${GM_ROOT}${gm_d}")
    if [ -n "$gm_dl" ] && [ -n "$GM_CHCON" ]; then
      "$GM_CHCON" "$gm_dl" "$gm_s" 2>/dev/null
    fi
    gm_hal="u:object_r:same_process_hal_file:s0"
    ( cd "$gm_s" && "$GM_FIND" . \( -type f -o -type l \) ) 2>/dev/null \
    | while IFS= read -r gm_r; do
        gm_r=${gm_r#./}
        chmod a+rX "$gm_s/$gm_r" 2>/dev/null
        gm_ol=$(gm_label_of "${GM_ROOT}${gm_d}/$gm_r")
        if [ -z "$gm_ol" ] || [ "$gm_ol" = "u:object_r:vendor_file:s0" ]; then
          gm_ol="$gm_hal"
        fi
        if [ -n "$GM_CHCON" ]; then
          "$GM_CHCON" "$gm_ol" "$gm_s/$gm_r" 2>/dev/null
        fi
      done
  done < "$GM_SPLAN"
  touch "$STAGE/.done" 2>/dev/null
}

# Post-mount label fix: chcon through the MOUNTED path (which we've
# verified works on real devices) instead of the /data staging path
# (where the f2fs filesystem can silently drop the label). Runs after
# gm_apply so the mounts are live and the paths resolve through them.
gm_fix_labels_post_mount() {
  [ -n "$GM_CHCON" ] || return 0
  gm_hal="u:object_r:same_process_hal_file:s0"
  while IFS='|' read -r gm_src gm_dst; do
    [ -n "$gm_src" ] || continue
    gm_phys="${GM_ROOT}${gm_dst}"
    gm_now=$(gm_label_of "$gm_phys")
    if [ -n "$gm_now" ] && [ "$gm_now" != "$gm_hal" ] \
       && [ "$gm_now" != "u:object_r:same_process_hal_file:s0" ]; then
      # only fix labels that are WRONG (vendor_file, system_data_file,
      # etc.) — not ones that are already correct or purpose-set
      case "$gm_now" in
        u:object_r:vendor_file:s0|u:object_r:system_data_file:s0|u:object_r:adb_data_file:s0)
          "$GM_CHCON" "$gm_hal" "$gm_phys" 2>>"$LOG" \
            && gm_log "post-mount label fix: $gm_dst -> same_process_hal_file"
          ;;
      esac
    fi
  done < "$LIST"
  # also fix the staged dir contents through the mounted path
  while IFS= read -r gm_d; do
    [ -n "$gm_d" ] || continue
    gm_phys="${GM_ROOT}${gm_d}"
    # only check payload files inside this staged dir
    while IFS='|' read -r gm_src gm_dst; do
      case "$gm_dst" in "$gm_d"/*) ;; *) continue ;; esac
      gm_fp="${GM_ROOT}${gm_dst}"
      gm_now=$(gm_label_of "$gm_fp")
      case "$gm_now" in
        u:object_r:vendor_file:s0|u:object_r:system_data_file:s0|u:object_r:adb_data_file:s0|"")
          "$GM_CHCON" "$gm_hal" "$gm_fp" 2>>"$LOG" \
            && gm_log "post-mount label fix: $gm_dst -> same_process_hal_file"
          ;;
      esac
    done < "$LIST"
  done < "$GM_SPLAN"
}

# --------------------------------------------------------- namespaces ------
GM_NS_PIDS=""
GM_NS_COUNT=0
gm_collect_ns() {
  gm_pids=""
  if [ -n "$GM_TEST_PIDS" ]; then
    gm_pids="$GM_TEST_PIDS"
  else
    gm_pids="1"
    for gm_n in zygote64 zygote surfaceflinger; do
      gm_pp=""
      if [ -n "$GM_PIDOF" ]; then
        gm_pp=$("$GM_PIDOF" "$gm_n" 2>/dev/null)
      fi
      if [ -z "$gm_pp" ] && [ -n "$GM_PGREP" ]; then
        gm_pp=$("$GM_PGREP" -x "$gm_n" 2>/dev/null)
      fi
      gm_pids="$gm_pids $gm_pp"
    done
    if [ "$ALL_NS" = "1" ]; then
      for gm_pd in /proc/[0-9]*; do
        gm_pids="$gm_pids ${gm_pd#/proc/}"
      done
    fi
  fi
  gm_seen=""; GM_NS_PIDS=""; GM_NS_COUNT=0
  for gm_p in $gm_pids; do
    case "$gm_p" in ''|*[!0-9]*) continue ;; esac
    [ -d "/proc/$gm_p" ] || continue
    gm_nsl=$(readlink "/proc/$gm_p/ns/mnt" 2>/dev/null) || continue
    case " $gm_seen " in *" $gm_nsl "*) continue ;; esac
    gm_seen="$gm_seen $gm_nsl"
    GM_NS_PIDS="$GM_NS_PIDS $gm_p"
    GM_NS_COUNT=$((GM_NS_COUNT+1))
  done
}

# -------------------------------------------------------------- apply ------
# STRICT: every namespace must confirm each attempted mount with a
# MOUNT_OK line. A namespace that returns nothing (nsenter binary
# missing/broken, setns denied by SELinux) is a FAILURE, never success.
gm_mount_serves() { # $1=pid $2=phys $3=src -> 0 when pid's mount at phys serves src
  "$GM_GREP" -qF " $2 " "/proc/$1/mountinfo" 2>/dev/null || return 1
  [ -n "$GM_STAT" ] || return 0   # no stat: assume presence = ours
  gm_a=$("$GM_STAT" -c '%d:%i' "$3" 2>/dev/null)
  gm_b=$(gm_ns_run "$1" "$GM_STAT -c '%d:%i' '$2'" 2>/dev/null)
  [ -n "$gm_a" ] && [ "$gm_a" = "$gm_b" ]
}

gm_apply() {
  gm_ok=0
  gm_done=0
  gm_ns_fail=0
  for gm_p in $GM_NS_PIDS; do
    gm_cmds=""
    gm_want=0
    while IFS='|' read -r gm_src gm_dst gm_kind; do
      [ -n "$gm_src" ] || continue
      gm_phys="${GM_ROOT}${gm_dst}"
      if gm_mount_serves "$gm_p" "$gm_phys" "$gm_src"; then
        continue   # already serving THIS payload — do not stack
      fi
      if "$GM_GREP" -qF " $gm_phys " "/proc/$gm_p/mountinfo" 2>/dev/null; then
        # STALE mount: present but serving an older/deleted payload
        # (e.g. after a failed unmount or a driver swap). Lazy-detach
        # it first or the new driver can never take its place.
        gm_cmds="$gm_cmds $GM_UMOUNT -l '$gm_phys' 2>/dev/null;"
        gm_log "ns[$gm_p] replacing stale mount at $gm_dst"
      fi
      gm_want=$((gm_want+1))
      gm_cmds="$gm_cmds $GM_MOUNT -o bind '$gm_src' '$gm_phys' >/dev/null 2>&1 && echo MOUNT_OK:'$gm_phys' || echo MOUNT_FAIL:'$gm_phys';"
    done < "$GM_MLIST"
    if [ "$gm_want" = "0" ]; then
      gm_ok=$((gm_ok+1))
      continue
    fi
    gm_out=$(gm_ns_run "$gm_p" "$gm_cmds" 2>>"$LOG")
    echo "$gm_out" >> "$LOG"
    gm_okn=$(printf '%s\n' "$gm_out" | "$GM_GREP" -c '^MOUNT_OK:')
    gm_failn=$(printf '%s\n' "$gm_out" | "$GM_GREP" -c '^MOUNT_FAIL:')
    if [ "$gm_okn" = "$gm_want" ]; then
      gm_ok=$((gm_ok+1))
    else
      gm_ns_fail=$((gm_ns_fail+1))
      if [ -z "$gm_out" ]; then
        gm_warn "ns[$gm_p]: NO OUTPUT from nsenter ($gm_want mount(s) attempted) —"
        gm_warn "  nsenter binary broken or setns() denied (SELinux?)."
        gm_warn "  check: ls /system/bin/nsenter; see doctor (selftest)"
      else
        gm_warn "ns[$gm_p]: only $gm_okn/$gm_want mounts landed, $gm_failn failed"
      fi
    fi
    gm_done=$((gm_done+1))
    echo "$gm_out" | while IFS= read -r gm_l; do
      case "$gm_l" in
        MOUNT_OK:*)   gm_log "  ns[$gm_p] mounted ${gm_l#MOUNT_OK:}" ;;
        MOUNT_FAIL:*) gm_log "  ns[$gm_p] FAILED  ${gm_l#MOUNT_FAIL:}" ;;
      esac
    done
  done
  gm_log "applied to $gm_ok/$GM_NS_COUNT namespace(s), $gm_done needed changes"
  [ "$gm_ns_fail" = "0" ]
}

# ------------------------------------------------------------ unmount ------
gm_unmount() {
  gm_rev="$MODDIR/.rev"
  gm_rtmp="$MODDIR/.rev.tmp.$$"
  if [ -s "$GM_MLIST" ]; then
    awk '{a[NR]=$0} END{for(i=NR;i>=1;i--) print a[i]}' "$GM_MLIST" > "$gm_rtmp"
  else
    : > "$gm_rtmp"
  fi
  mv -f "$gm_rtmp" "$gm_rev"
  # sweep every namespace (we may have mounted with --all earlier)
  if [ -n "$GM_TEST_PIDS" ]; then
    gm_sweep="$GM_TEST_PIDS $$"
  else
    gm_sweep="1"
    for gm_pd in /proc/[0-9]*; do gm_sweep="$gm_sweep ${gm_pd#/proc/}"; done
  fi
  gm_seen=""; gm_spids=""
  for gm_p in $gm_sweep; do
    case "$gm_p" in ''|*[!0-9]*) continue ;; esac
    [ -d "/proc/$gm_p" ] || continue
    gm_nsl=$(readlink "/proc/$gm_p/ns/mnt" 2>/dev/null) || continue
    case " $gm_seen " in *" $gm_nsl "*) continue ;; esac
    gm_seen="$gm_seen $gm_nsl"; gm_spids="$gm_spids $gm_p"
  done
  for gm_p in $gm_spids; do
    while IFS='|' read -r gm_src gm_dst gm_kind; do
      [ -n "$gm_dst" ] || continue
      gm_phys="${GM_ROOT}${gm_dst}"
      gm_n=0
      while \
        "$GM_GREP" -qF " $gm_phys " "/proc/$gm_p/mountinfo" 2>/dev/null && \
        "$GM_GREP" -F " $gm_phys " "/proc/$gm_p/mountinfo" 2>/dev/null | "$GM_GREP" -qF "$GM_MARKER"
      do
        # LAZY umount: a plain umount fails EBUSY whenever any process
        # in the namespace still holds the file open/mapped (running
        # apps do!) and the mount would stick forever. Lazy detach
        # removes it from the namespace immediately; running processes
        # keep their mapped inode, new lookups see the underlying file.
        if [ -n "$GM_UMOUNT" ]; then
          gm_ns_run "$gm_p" "$GM_UMOUNT '$gm_phys' 2>/dev/null || $GM_UMOUNT -l '$gm_phys'" >/dev/null 2>&1
        elif [ -n "$GM_BB" ]; then
          "$GM_BB" umount -l "$gm_phys" >/dev/null 2>&1
        else
          break
        fi
        gm_n=$((gm_n+1))
        [ $gm_n -gt 8 ] && break
      done
      [ $gm_n -gt 0 ] && gm_log "ns[$gm_p] unmounted $gm_dst (x$gm_n)"
    done < "$gm_rev"
  done
  # self-healing scan: remove ANY mount carrying our marker, even ones
  # the plan doesn't know about (stale state after driver-clear, a
  # killed apply, a corrupted plan). Repeated passes handle stacking.
  gm_pass=0
  while [ $gm_pass -lt 3 ]; do
    gm_found=0
    for gm_p in $gm_spids; do
      gm_mps=$("$GM_GREP" -F "$GM_MARKER" "/proc/$gm_p/mountinfo" 2>/dev/null | awk '{print $5}' | sort -u)
      for gm_mp in $gm_mps; do
        [ -n "$gm_mp" ] || continue
        gm_found=1
        if [ -n "$GM_UMOUNT" ]; then
          gm_ns_run "$gm_p" "$GM_UMOUNT -l '$gm_mp'" >/dev/null 2>&1
        elif [ -n "$GM_BB" ]; then
          "$GM_BB" umount -l "$gm_mp" >/dev/null 2>&1
        fi
        gm_log "ns[$gm_p] scan-detached stale mount $gm_mp"
      done
    done
    [ "$gm_found" = "0" ] && break
    gm_pass=$((gm_pass+1))
  done
  rm -rf "$STAGE" 2>/dev/null
  gm_log "unmount finished — vendor filesystem was never modified"
}

# -------------------------------------------------------------- status -----
gm_status() {
  gm_first=$(echo $GM_NS_PIDS | awk '{print $1}')
  echo "== payload ($GM_COUNT file(s)) =="
  while IFS='|' read -r gm_src gm_dst; do
    [ -n "$gm_src" ] || continue
    # kind from the saved plan when available: probing the live view is
    # wrong once our own mounts are in place
    gm_kind=""
    if [ "$GM_SAVED" = "1" ] && [ -f "$MODDIR/.saved.mlist" ]; then
      if "$GM_GREP" -qF "|$gm_dst|file" "$MODDIR/.saved.mlist"; then
        gm_kind="replace"
      else
        gm_kind="new-file (staged)"
      fi
    fi
    if [ -z "$gm_kind" ]; then
      if [ -e "${GM_ROOT}${gm_dst}" ] || [ -L "${GM_ROOT}${gm_dst}" ]; then
        gm_kind="replace"
      else
        gm_kind="new-file"
      fi
    fi
    gm_mc=0
    # files served via a staged dir: the DIR is the mountpoint
    gm_mpt="$gm_dst"
    while IFS= read -r gm_d; do
      [ -n "$gm_d" ] || continue
      case "$gm_dst" in "$gm_d"/*) gm_mpt="$gm_d"; break ;; esac
    done < "$GM_SPLAN"
    for gm_p in $GM_NS_PIDS; do
      "$GM_GREP" -qF " ${GM_ROOT}${gm_mpt} " "/proc/$gm_p/mountinfo" 2>/dev/null \
        && gm_mc=$((gm_mc+1))
    done
    gm_eff=""
    if [ -n "$GM_STAT" ] && [ -n "$gm_first" ]; then
      # files served through a staged dir must be compared against the
      # staged COPY, not the payload source
      gm_chk="$gm_src"
      while IFS= read -r gm_d; do
        [ -n "$gm_d" ] || continue
        case "$gm_dst" in "$gm_d"/*)
          gm_chk="$STAGE$(echo "$gm_d" | sed 's|/|_|g')/${gm_dst#"$gm_d"/}"
          break
          ;;
        esac
      done < "$GM_SPLAN"
      gm_a=$("$GM_STAT" -c '%d:%i' "$gm_chk" 2>/dev/null)
      gm_b=$(gm_ns_run "$gm_first" "$GM_STAT -c '%d:%i' '${GM_ROOT}${gm_dst}'" 2>/dev/null)
      if [ -n "$gm_a" ] && [ "$gm_a" = "$gm_b" ]; then
        gm_eff=" ACTIVE"
      fi
    fi
    echo "  $gm_dst  [$gm_kind] mounted-in:$gm_mc/$GM_NS_COUNT ns$gm_eff"
  done < "$LIST"
  while IFS= read -r gm_d; do
    [ -n "$gm_d" ] || continue
    echo "  (staged merged dir: $gm_d)"
  done < "$GM_SPLAN"
  echo "== target namespaces =="
  echo "  $GM_NS_COUNT: $GM_NS_PIDS"
}

gm_print_plan() {
  echo "== plan ($GM_COUNT payload file(s)) =="
  while IFS='|' read -r gm_src gm_dst; do
    [ -n "$gm_src" ] || continue
    if [ -e "${GM_ROOT}${gm_dst}" ] || [ -L "${GM_ROOT}${gm_dst}" ]; then
      echo "  bind file:  $gm_dst"
    else
      echo "  NEW file:   $gm_dst"
    fi
  done < "$LIST"
  while IFS= read -r gm_d; do
    [ -n "$gm_d" ] || continue
    echo "  stage dir:  $gm_d (merged copy, bind-mounted over original)"
  done < "$GM_SPLAN"
  echo "== would apply in namespaces of: 1, zygote64, zygote, surfaceflinger"
  [ "$ALL_NS" = "1" ] && echo "   + every running namespace (--all)"
}

# ---------------------------------------------------------------- main -----
case "$CMD" in
  mount)
    [ "$GM_COUNT" -gt 0 ] || gm_die "no payload files under $MODDIR/system — add your driver first (see README.md)"
    gm_log "--- mount: $GM_COUNT payload file(s), ALL_NS=$ALL_NS ---"
    gm_prepare_plan
    gm_relabel_payload
    # rebuild staging only when the plan is new or staging is missing —
    # staging a merged dir can mean copying a LARGE vendor dir, and it
    # persists on /data across reboots (mounts do not)
    if [ "$GM_SAVED" != "1" ] || { [ -s "$GM_SPLAN" ] && [ ! -f "$STAGE/.done" ]; }; then
      gm_build_staging
    fi
    gm_collect_ns
    [ "$GM_NS_COUNT" -gt 0 ] || gm_die "no target namespaces found"
    gm_apply || gm_die "mount FAILED — mounts were NOT applied. See $LOG (tail it: sh $0 doctor via webui_ctl, or: tail -25 $LOG)"
    gm_fix_labels_post_mount
    gm_log "done. Restart apps to load the new driver."
    gm_log "note: mounts are in-memory — re-run after every reboot (action.sh)."
    ;;
  unmount)
    gm_log "--- unmount ---"
    if [ -s "$MODDIR/.saved.mlist" ]; then
      GM_MLIST="$MODDIR/.saved.mlist"   # saved plan reflects reality
    else
      gm_build_plan
      gm_mount_list
    fi
    gm_unmount
    ;;
  status)
    gm_state_load || gm_build_plan
    gm_collect_ns
    gm_status
    ;;
  ns)
    # per-app: apply the plan to exactly ONE pid's mount namespace
    case "$GM_NS_PID" in ''|*[!0-9]*) gm_die "usage: gpu_mount.sh ns <pid>" ;; esac
    [ -d "/proc/$GM_NS_PID" ] || gm_die "pid $GM_NS_PID not found"
    [ "$GM_COUNT" -gt 0 ] || gm_die "no payload files under $MODDIR/system"
    # guard: NEVER mount into an init/zygote namespace — that would leak
    # the driver to every process forked from it (i.e. globally).
    # GM_ZYGOTE_PIDS is a test override for the zygote pid set.
    gm_tns=$(readlink "/proc/$GM_NS_PID/ns/mnt" 2>/dev/null) \
      || gm_die "cannot read mount namespace of pid $GM_NS_PID"
    gm_zpids=${GM_ZYGOTE_PIDS:-}
    if [ -z "$gm_zpids" ]; then
      gm_zpids="1 $("$GM_PIDOF" zygote64 2>/dev/null) $("$GM_PIDOF" zygote 2>/dev/null)"
    fi
    for gm_z in $gm_zpids; do
      gm_zns=$(readlink "/proc/$gm_z/ns/mnt" 2>/dev/null) || continue
      [ "$gm_zns" = "$gm_tns" ] \
        && gm_die "refusing: pid $GM_NS_PID shares pid $gm_z's namespace (global leak)"
    done
    gm_state_load || { gm_build_plan; gm_mount_list; gm_state_save; }
    gm_relabel_payload
    # rebuild staging only when the plan is new or staging is missing —
    # per-app spawns must not re-copy vendor dirs every time
    if [ -s "$GM_SPLAN" ]; then
      if [ "$GM_SAVED" != "1" ] || [ ! -f "$STAGE/.done" ]; then
        gm_build_staging
      fi
    fi
    GM_NS_PIDS="$GM_NS_PID"
    GM_NS_COUNT=1
    gm_apply || gm_die "ns mount FAILED for pid $GM_NS_PID — see $LOG"
    ;;
  selftest)
    # diagnostic: verify the primitives this engine depends on
    gm_st_fail=0
    echo "nsenter binary: ${GM_NSENTER:-NONE}${GM_BB:+ (busybox: $GM_BB)}"
    if [ -z "$GM_NSENTER" ] && [ -z "$GM_BB" ]; then
      echo "nsenter: MISSING (install busybox to /data/adb/ksu/bin/ or /data/adb/ap/bin/)"
      gm_st_fail=1
    fi
    if gm_ns_run $$ "echo NSENTER_OK" 2>/dev/null | "$GM_GREP" -q NSENTER_OK; then
      echo "nsenter into own namespace: OK"
    else
      echo "nsenter into own namespace: FAILED"
      gm_st_fail=1
    fi
    gm_t1="$MODDIR/.st_test_a"; gm_t2="$MODDIR/.st_test_b"
    echo STTEST_A > "$gm_t1"; echo STTEST_B > "$gm_t2"
    gm_st_out=$(gm_ns_run $$ "$GM_MOUNT -o bind '$gm_t1' '$gm_t2' 2>&1 && [ \"\$(cat '$gm_t2' 2>/dev/null)\" = STTEST_A ] && echo BIND_OK || echo BIND_FAIL" 2>/dev/null)
    if [ "$gm_st_out" = "BIND_OK" ]; then
      echo "bind mount: OK"
    else
      echo "bind mount: FAILED ($gm_st_out) — see doctor (selftest)"
      gm_st_fail=1
    fi
    gm_ns_run $$ "$GM_UMOUNT '$gm_t2' 2>/dev/null" >/dev/null 2>&1
    rm -f "$gm_t1" "$gm_t2"
    if [ "$gm_st_fail" = "0" ]; then
      echo "self-test: PASS"
    else
      echo "self-test: FAIL — fix the above before reporting driver issues"
    fi
    ;;
  plan)
    gm_build_plan
    gm_print_plan
    ;;
esac
exit 0
