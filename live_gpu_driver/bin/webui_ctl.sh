#!/system/bin/sh
#
# webui_ctl.sh — JSON backend for the module WebUI (webroot/index.html).
#
# One entry point the WebView calls via the manager's ksu.exec bridge:
#
#   webui_ctl.sh status            -> JSON: mode, watcher, payload, targets
#   webui_ctl.sh set-pkgs "a,b,-"  -> rewrite PERAPP_PKGS in config (also
#                                     restarts the watcher if it runs);
#                                     use "-" for none (global mode)
#   webui_ctl.sh list-apps         -> JSON array of user package names
#   webui_ctl.sh start-watcher     -> perapp.sh start (human text out)
#   webui_ctl.sh stop-watcher      -> perapp.sh stop
#   webui_ctl.sh apply             -> autostart logic: watcher if pkgs set,
#                                     else global mount
#   webui_ctl.sh unmount           -> stop watcher + unmount everything
#   webui_ctl.sh force-stop <pkg>  -> am force-stop (restart an app)
#   webui_ctl.sh log               -> base64 of the last 80 log lines
#                                     (base64 avoids all JSON escaping)
#
# Package names are validated against ^[A-Za-z][A-Za-z0-9._]*$ before
# they ever reach a shell string. All env (GM_ROOT, GM_TEST_PIDS...) is
# inherited so the test harness can drive this script too.
MODDIR=$(cd "$(dirname "$0")/.." && pwd)
CFG="$MODDIR/config"
LIST="$MODDIR/.list"
MLIST="$MODDIR/.saved.mlist"
PIDFILE="$MODDIR/.watcher.pid"
STAGE="$MODDIR/.staging"
GM_ROOT=${GM_ROOT:-}

pa_die() { echo "{\"error\":\"$1\"}"; exit 1; }

# ---------------------------------------------------------------- helpers --
ctl_pkgs() { # echo PERAPP_PKGS value from config
  [ -f "$CFG" ] || return 0
  awk -F= '/^[[:space:]]*PERAPP_PKGS=/{print $2; exit}' "$CFG" | tr -d '"' | tr -d "'"
}

ctl_pkg_ok() { # strict package-name check
  case "$1" in
    ""|*[!A-Za-z0-9._]*) return 1 ;;
  esac
  case "$1" in
    [A-Za-z]*) return 0 ;;
    *) return 1 ;;
  esac
}

ctl_alive() {
  [ -n "$1" ] && [ -d "/proc/$1" ] && ! grep -q '^State:.*Z' "/proc/$1/status" 2>/dev/null
}

ctl_driver_src() { # -> source file the engine serves for payload entry $1
  # $1 = "src|dst" from .list; if a staged dir covers dst, use staged copy
  gm_src=${1%%|*}; gm_dst=${1#*|}
  [ -f "$MLIST" ] || { echo "$gm_src"; return; }
  while IFS='|' read -r s d k; do
    [ "$k" = "dir" ] || continue
    case "$gm_dst" in "$d"/*)
      echo "$STAGE$(echo "$d" | sed 's|/|_|g')/${gm_dst#"$d"/}"
      return ;;
    esac
  done < "$MLIST"
  echo "$gm_src"
}

ctl_has_driver() { # pid -> 0 if the process sees the custom driver
  first=$(sed -n '1p' "$LIST" 2>/dev/null)
  [ -n "$first" ] || return 1
  src=$(ctl_driver_src "$first")
  dst=${first#*|}
  [ -n "$src" ] || return 1
  cmp -s "$src" "/proc/$1/root${GM_ROOT}${dst}" 2>/dev/null
}

ctl_payload_json() { # JSON array of payload entries
  out=""
  if [ -f "$LIST" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      src=${l%%|*}; dst=${l#*|}
      if [ -e "${GM_ROOT}${dst}" ] || [ -L "${GM_ROOT}${dst}" ]; then k="replace"; else k="new-file"; fi
      [ -n "$out" ] && out="$out,"
      out="$out{\"path\":\"$dst\",\"kind\":\"$k\"}"
    done < "$LIST"
  fi
  echo "[$out]"
}

ctl_targets_json() { # JSON array of running target processes
  pkgs=$(ctl_pkgs)
  out=""
  [ -n "$pkgs" ] || { echo "[]"; return; }
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    cmd=$({ tr '\0' ' ' < "$d/cmdline"; } 2>/dev/null) || continue
    first=${cmd%% *}
    for pkg in $pkgs; do
      case "$first" in "$pkg"|"$pkg":*)
        if ctl_has_driver "$p"; then dr="custom"; else dr="stock"; fi
        [ -n "$out" ] && out="$out,"
        out="$out{\"pid\":$p,\"pkg\":\"$pkg\",\"driver\":\"$dr\"}"
        ;;
      esac
    done
  done
  echo "[$out]"
}

ctl_global_active() { # 1 if global mounts are ACTIVE somewhere
  n=$(GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" status 2>/dev/null | grep -c ACTIVE)
  [ "${n:-0}" -ge 1 ]
}

# ---------------------------------------------------------------- status ----
ctl_status() {
  pkgs=$(ctl_pkgs)
  [ -n "$pkgs" ] && mode="perapp" || mode="global"
  if [ -f "$PIDFILE" ] && ctl_alive "$(cat "$PIDFILE")"; then
    wr="true"; wpid=$(cat "$PIDFILE")
  else
    wr="false"; wpid=0
  fi
  if ctl_global_active; then ga="true"; else ga="false"; fi
  late=${KSU_LATE_LOAD:-0}
  ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
  drv=""
  [ -f "$MODDIR/.driver_sel" ] && drv=$(cat "$MODDIR/.driver_sel")
  deps=""
  [ -f "$MODDIR/.deps_report" ] && deps=$(cat "$MODDIR/.deps_report" | tr '\n' ',' | sed 's/,$//')
  n=0
  [ -f "$LIST" ] && n=$(grep -c . "$LIST" 2>/dev/null)
  echo "{\"mode\":\"$mode\",\"version\":\"$ver\",\"driver\":\"$drv\",\"missing_deps\":\"$deps\",\"watcher_running\":$wr,\"watcher_pid\":$wpid,\"global_active\":$ga,\"late_load\":\"$late\",\"payload_count\":$n,\"payload\":$(ctl_payload_json),\"pkgs\":[$(for p in $pkgs; do printf '"%s",' "$p"; done | sed 's/,$//')],\"targets\":$(ctl_targets_json)}"
}

# --------------------------------------------------------------- set-pkgs ---
ctl_set_pkgs() {
  raw=$1
  [ -n "$raw" ] || pa_die "missing package list"
  if [ "$raw" = "-" ]; then
    new=""
  else
    # normalize separators (comma/space) and validate every entry
    norm=$(echo "$raw" | tr ',' ' ' | tr -s ' ')
    new=""
    for p in $norm; do
      ctl_pkg_ok "$p" || pa_die "invalid package name: $p"
      case " $new " in *" $p "*) ;; *) new="$new $p" ;; esac
    done
    new=${new# }
  fi
  # rewrite config: drop ALL old PERAPP_PKGS lines (including the
  # commented example), append the new one
  tmp="$MODDIR/.config.tmp.$$"
  {
    [ -f "$CFG" ] && grep -v 'PERAPP_PKGS=' "$CFG" || true
    [ -n "$new" ] && echo "PERAPP_PKGS=\"$new\"" || true
  } > "$tmp" || pa_die "cannot write config"
  mv "$tmp" "$CFG"
  # restart the watcher so a new list takes effect immediately
  if [ -f "$PIDFILE" ] && ctl_alive "$(cat "$PIDFILE")"; then
    sh "$MODDIR/bin/perapp.sh" stop >/dev/null 2>&1
    [ -n "$new" ] && sh "$MODDIR/bin/perapp.sh" start >/dev/null 2>&1
  fi
  if [ -n "$new" ]; then echo "{\"ok\":true,\"pkgs\":\"$new\"}"
  else echo '{"ok":true,"pkgs":""}'; fi
}

# --------------------------------------------------------------- drivers ---
# Zip-based driver management (AdrenoToolsDrivers package format:
# root-level .so files + meta.json). Drivers are NOT embedded in the
# module: drop a zip into one of GM_DRIVER_DIRS and select it from the
# WebUI. Selecting extracts, maps the libs onto vendor paths (payload
# mirror) and re-applies the active mode.
GM_DRIVER_DIRS=${GM_DRIVER_DIRS:-/sdcard/Download /sdcard/GPUDrivers /data/adb/gpu_drivers}
SELFILE="$MODDIR/.driver_sel"

ctl_uzp() { # unzip -p: print one member of a zip
  if command -v unzip >/dev/null 2>&1; then unzip -p "$@"
  elif [ -x /data/adb/ksu/bin/busybox ]; then /data/adb/ksu/bin/busybox unzip -p "$@"
  elif [ -x /data/adb/ap/bin/busybox ]; then /data/adb/ap/bin/busybox unzip -p "$@"
  else return 1; fi
}
ctl_uzx() { # unzip -o -q <zip> -d <dir>
  if command -v unzip >/dev/null 2>&1; then unzip -o -q "$1" -d "$2"
  elif [ -x /data/adb/ksu/bin/busybox ]; then /data/adb/ksu/bin/busybox unzip -o -q "$1" -d "$2"
  elif [ -x /data/adb/ap/bin/busybox ]; then /data/adb/ap/bin/busybox unzip -o -q "$1" -d "$2"
  else return 1; fi
}

ctl_meta_get() { # <zip> <key> -> value from the zip's meta.json
  # handles both "key":"value" and "key":123
  ctl_uzp "$1" meta.json 2>/dev/null \
    | sed -n -e "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
             -e "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1
}

ctl_drivers_list() { # JSON array of driver zips found in the scan dirs
  out=""
  for d in $GM_DRIVER_DIRS; do
    [ -d "$d" ] || continue
    for z in "$d"/*.zip; do
      [ -f "$z" ] || continue
      name=$(ctl_meta_get "$z" name)
      ver=$(ctl_meta_get "$z" driverVersion)
      api=$(ctl_meta_get "$z" minApi)
      [ -n "$name" ] || name=$(basename "$z" .zip)
      sel="false"
      [ -f "$SELFILE" ] && [ "$(cat "$SELFILE")" = "$z" ] && sel="true"
      [ -n "$out" ] && out="$out,"
      out="$out{\"path\":\"$z\",\"name\":\"$name\",\"version\":\"${ver:-?}\",\"minApi\":\"${api:-?}\",\"selected\":$sel}"
    done
  done
  echo "[$out]"
}

ctl_getprop() { # safe getprop (absent in test harness)
  command -v getprop >/dev/null 2>&1 && getprop "$1" 2>/dev/null
}

# Every existing vendor path the system's Vulkan loader may open:
#  * libraries named by ICD manifests in /vendor/etc/vulkan/icd.d/*.json
#    (MODERN firmware prefers these; the referenced lib can have ANY name)
#  * the legacy hw module /vendor/lib64/hw/vulkan.$(ro.hardware.vulkan).so
#  * every vulkan.*.so found in the sphal search dirs
# Mounting our driver over ALL of them guarantees whichever file the
# loader opens, it gets ours.
ctl_vulkan_targets() {
  out=""
  rd="${GM_ROOT}"
  # 1) ICD manifest libraries
  if [ -d "$rd/vendor/etc/vulkan/icd.d" ]; then
    for j in "$rd"/vendor/etc/vulkan/icd.d/*.json; do
      [ -f "$j" ] || continue
      lp=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$j" | head -n 1)
      [ -n "$lp" ] || continue
      case "$lp" in
        /*) [ -f "$rd$lp" ] && out="$out $rd$lp" ;;
        *)
          for d in /vendor/lib64 /vendor/lib64/hw /vendor/lib64/egl \
                   /odm/lib64 /odm/lib64/hw /odm/lib64/egl; do
            [ -f "$rd$d/$lp" ] && out="$out $rd$d/$lp"
          done
          ;;
      esac
    done
  fi
  # 2) legacy hw module path
  hw=$(ctl_getprop ro.hardware.vulkan)
  [ -n "$hw" ] && [ -f "$rd/vendor/lib64/hw/vulkan.$hw.so" ] \
    && out="$out $rd/vendor/lib64/hw/vulkan.$hw.so"
  # 3) every existing vulkan.*.so in the sphal search dirs
  for d in /vendor/lib64 /vendor/lib64/hw /vendor/lib64/egl \
           /odm/lib64 /odm/lib64/hw /odm/lib64/egl; do
    for f in "$rd"$d/vulkan.*.so; do
      [ -f "$f" ] && out="$out $f"
    done
  done
  echo "$out" | tr ' ' '\n' | awk 'NF' | sort -u
}

ctl_driver_select() { # $1 = zip path (must live inside a scan dir)
  z=$1
  ok=0
  for d in $GM_DRIVER_DIRS; do
    case "$z" in "$d"/*.zip) [ -f "$z" ] && ok=1 ;; esac
  done
  [ "$ok" = "1" ] || pa_die "path not allowed (must be a .zip inside: $(echo $GM_DRIVER_DIRS))"
  cache="$MODDIR/.drivercache"
  rm -rf "$cache" "$MODDIR/.staging"
  mkdir -p "$cache" || pa_die "cannot create cache"
  ctl_uzx "$z" "$cache" || pa_die "cannot extract zip"
  # locate the vulkan driver library: meta.json's libraryName, else the
  # first vulkan.*.so at the zip root
  lib=$(ctl_meta_get "$z" libraryName)
  if [ -z "$lib" ] || [ ! -f "$cache/$lib" ]; then
    lib=""
    for f in "$cache"/vulkan.*.so; do
      [ -f "$f" ] && { lib=$(basename "$f"); break; }
    done
  fi
  [ -n "$lib" ] && [ -f "$cache/$lib" ] || pa_die "no vulkan driver library found in zip"
  # drop the previous driver's plan state (mounts are removed in the
  # background job — see below — so this call returns fast)
  rm -f "$MODDIR/.saved.list" "$MODDIR/.saved.mlist"
  sys="$MODDIR/system"
  rm -rf "$sys"
  mkdir -p "$sys"
  # --- vulkan driver: mount over EVERY path the loader might use -------
  targets=$(ctl_vulkan_targets)
  [ -n "$targets" ] || targets="${GM_ROOT}/vendor/lib64/hw/vulkan.adreno.so"
  ntargets=0
  for t in $targets; do
    # logical path (engine mounts system/<logical> over GM_ROOT+<logical>)
    lt=${t#"$GM_ROOT"}
    mkdir -p "$sys$(dirname "$lt")"
    cp -f "$cache/$lib" "$sys$lt" || pa_die "cannot install vulkan library"
    ntargets=$((ntargets+1))
  done
  # --- remaining zip libs (fast: only payload-replace + string grep) ---
  # Reference check uses `grep -qsF` directly on the binary — fast enough
  # for the sync path. The FULL dependency analysis (strings + resolution)
  # runs in the background job and its result lands in .deps_report,
  # which `status` picks up.
  for f in "$cache"/*.so; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = "$lib" ] && continue
    case "$b" in
      libEGL_*|libGLESv2_*|libGLESv1_CM_*)
        role=$(printf '%s' "$b" | cut -d_ -f1)
        for e in "${GM_ROOT}"/vendor/lib64/egl/"$role"_*.so; do
          [ -f "$e" ] || continue
          mkdir -p "$sys/vendor/lib64/egl"
          cp -f "$f" "$sys/vendor/lib64/egl/$(basename "$e")"
        done
        mkdir -p "$sys/vendor/lib64/egl"
        cp -f "$f" "$sys/vendor/lib64/egl/$b"
        ;;
      *)
        # include if it replaces an existing vendor file OR is referenced
        # by another lib in the package (quick binary grep)
        keep=0
        [ -f "${GM_ROOT}/vendor/lib64/$b" ] && keep=1
        if [ "$keep" = "0" ]; then
          for g in "$cache"/*.so; do
            [ -f "$g" ] || continue
            [ "$(basename "$g")" = "$b" ] && continue
            if grep -qsF "$b" "$g"; then keep=1; break; fi
          done
        fi
        if [ "$keep" = "1" ]; then
          mkdir -p "$sys/vendor/lib64"
          cp -f "$f" "$sys/vendor/lib64/$b"
        fi
        ;;
    esac
  done
  echo "$z" > "$SELFILE.tmp.$$" && mv -f "$SELFILE.tmp.$$" "$SELFILE"
  # EVERYTHING heavy runs in the background: unmount the old driver,
  # full dependency analysis, then apply. This call returns immediately.
  setsid nohup sh -c '
    MODDIR="'"$MODDIR"'"
    echo "" > "$MODDIR/.deps_report"
    GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" unmount >> "$MODDIR/engine.log" 2>&1
    miss=$(sh "$MODDIR/bin/webui_ctl.sh" deps-report 2>/dev/null)
    [ -n "$miss" ] && printf "%s" "$miss" > "$MODDIR/.deps_report"
    sh "$MODDIR/bin/autostart.sh" >> "$MODDIR/engine.log" 2>&1
  ' >/dev/null 2>&1 &
  echo "{\"ok\":true,\"vulkan_targets\":$ntargets,\"applying\":true}"
}

# ---------------------------------------------------------------- deps ------
# Shell DT_NEEDED approximation: extract every *.so name referenced by
# the payload libraries and report those resolvable NOWHERE (not in the
# payload mirror, not on vendor/odm, not in /system). Common bionic
# system libs are skipped — they live in the default linker namespace.
GM_SYS_LIBS=" libc.so libm.so libdl.so libc++.so libcutils.so liblog.so
 libbase.so libutils.so libz.so libsync.so libhardware.so libhidlbase.so
 libnativewindow.so libvndksupport.so libbinder_ndk.so libdexfile.so
 libutils_proto.so libprocessgroup.so libc_malloc_debug.so
 libandroid_runtime_lazy.so libbinder_wrapper.so "

ctl_dep_resolvable() { # $1 = lib name -> 0 when found somewhere
  case "$GM_SYS_LIBS" in *" $1 "*) return 0 ;; esac
  for d in /vendor/lib64 /vendor/lib64/hw /vendor/lib64/egl \
           /odm/lib64 /odm/lib64/hw /odm/lib64/egl /system/lib64; do
    [ -f "${GM_ROOT}$d/$1" ] && return 0
  done
  for d in "$MODDIR/system"/vendor/lib64 "$MODDIR/system"/vendor/lib64/hw \
           "$MODDIR/system"/vendor/lib64/egl; do
    [ -f "$d/$1" ] && return 0
  done
  return 1
}

ctl_deps_report() { # -> lines of "missinglib <- referencinglib"
  [ -d "$MODDIR/system" ] || return 0
  for f in "$MODDIR/system"/vendor/lib64/*.so \
           "$MODDIR/system"/vendor/lib64/hw/*.so \
           "$MODDIR/system"/vendor/lib64/egl/*.so; do
    [ -f "$f" ] || continue
    if command -v strings >/dev/null 2>&1; then
      names=$(strings "$f" 2>/dev/null | grep -oE '[A-Za-z0-9_.@+-]+\.so' | sort -u)
    else
      names=$(grep -aoE '[A-Za-z0-9_.@+-]+\.so' "$f" 2>/dev/null | sort -u)
    fi
    for n in $names; do
      [ -n "$n" ] || continue
      ctl_dep_resolvable "$n" || echo "$n <- $(basename "$f")"
    done
  done | sort -u
}

ctl_doctor() { # print a diagnostic report of the whole chain; $2 = app pid to inspect
  echo "==================== live_gpu_driver doctor ===================="
  ver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
  echo "module:        $ver"
  drv=""
  [ -f "$SELFILE" ] && drv=$(cat "$SELFILE")
  echo "driver zip:    ${drv:-none}"
  n=0
  [ -f "$LIST" ] && n=$(grep -c . "$LIST" 2>/dev/null)
  echo "payload files: $n"
  if [ "$n" != "0" ]; then
    sed -n 's/.*|/  /p' "$LIST" 2>/dev/null | head -n 12
  fi
  # pid set: the engine's targets, or the test override
  if [ -n "$GM_TEST_PIDS" ]; then
    dpids="$GM_TEST_PIDS"
  else
    dpids="1 $(pidof zygote64 2>/dev/null) $(pidof zygote 2>/dev/null) $(pidof surfaceflinger 2>/dev/null)"
  fi
  echo "---------------- device vulkan discovery -----------------------"
  echo "ro.hardware.vulkan: $(ctl_getprop ro.hardware.vulkan || echo '(unavailable)')"
  echo "ro.hardware.egl:    $(ctl_getprop ro.hardware.egl || echo '(unavailable)')"
  if [ -d "${GM_ROOT}/vendor/etc/vulkan/icd.d" ]; then
    echo "ICD manifests:"
    for j in "${GM_ROOT}"/vendor/etc/vulkan/icd.d/*.json; do
      [ -f "$j" ] || continue
      lp=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$j" | head -n 1)
      echo "  $j -> ${lp:-?}"
    done
  else
    echo "ICD manifests: none (loader uses the legacy hw module path)"
  fi
  echo "vulkan libs on vendor (mount targets):"
  for t in $(ctl_vulkan_targets); do
    echo "  $t"
  done
  echo "---------------- mounts by namespace ---------------------------"
  for p in $dpids ${2:-}; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ -d "/proc/$p" ] || continue
    m=$(grep -c "live_gpu_driver\|\.staging" "/proc/$p/mountinfo" 2>/dev/null || true)
    echo "  pid $p ($(cat "/proc/$p/cmdline" 2>/dev/null | tr '\0' ' ')): ${m:-0} module mounts"
  done
  echo "---------------- does the payload reach processes? --------------"
  if [ "$n" != "0" ]; then
    first=$(sed -n '1p' "$LIST" 2>/dev/null)
    # cut-based parsing: parameter-expansion stripping misbehaves in
    # some on-device shells (mksh/busybox ash pattern quirks with '|')
    src=$(printf '%s' "$first" | cut -d'|' -f1)
    dst=$(printf '%s' "$first" | cut -d'|' -f2)
    src=$(ctl_driver_src "$first")
    for p in $dpids ${2:-}; do
      [ -d "/proc/$p" ] || continue
      if ctl_has_driver "$p"; then r="SEES custom driver"; else r="sees STOCK (or mount missing)"; fi
      echo "  pid $p: $r  [$dst]"
    done
    # what is the app actually mapping?
    for p in ${2:-}; do
      case "$p" in ''|*[!0-9]*) continue ;; esac
      [ -d "/proc/$p" ] || continue
      echo "  vulkan libs mapped in pid $p:"
      awk '{print $6}' "/proc/$p/maps" 2>/dev/null | grep -i "vulkan" | sort -u | sed 's/^/    /'
    done
  fi
  echo "---------------- labels + modes ---------------------------------"
  if [ "$n" != "0" ]; then
    first=$(sed -n '1p' "$LIST" 2>/dev/null)
    dst=$(printf '%s' "$first" | cut -d'|' -f2)
    src=$(ctl_driver_src "$first")
    echo "  payload ($src):"
    ls -lZ "$src" 2>&1 | sed 's/^/    /'
    echo "  vendor (${GM_ROOT}${dst}):"
    ls -lZ "${GM_ROOT}${dst}" 2>&1 | sed 's/^/    /'
    echo "  (payload must be world-readable AND carry the vendor label;"
    echo "   an empty/mismatched label here = chcon is failing in your"
    echo "   su context -> apps get 'no vulkan device'. The module's"
    echo "   sepolicy.rule fallback covers this once loaded: reboot once"
    echo "   after installing the module, then re-apply.)"
  fi
  echo "---------------- stale staged mounts ----------------------------"
  zpid=$(pidof zygote64 2>/dev/null | awk '{print $1}')
  if [ -n "$zpid" ] && [ -d "/proc/$zpid" ]; then
    mounted=$(grep -o " /[^ ]*\.staging[^ ]*" "/proc/$zpid/mountinfo" 2>/dev/null | sort -u)
    found_stale=0
    for m in $mounted; do
      keep=0
      if [ -f "$MODDIR/.saved.mlist" ]; then
        while IFS='|' read -r s d k; do
          [ "$k" = "dir" ] || continue
          case "$m" in *"$(echo "$d" | sed 's|/|_|g')"*) keep=1 ;; esac
        done < "$MODDIR/.saved.mlist"
      fi
      if [ "$keep" = "0" ]; then
        found_stale=1
        echo "  WARNING: stale staged mount in zygote64 ns: $m"
        echo "  (left over from a previous driver selection)"
        echo "  fix: WebUI -> Use stock, then re-select the driver"
      fi
    done
    [ -z "$mounted" ] && echo "  none"
    [ -n "$mounted" ] && [ "$found_stale" = "0" ] && echo "  all staged mounts match the current plan"
  else
    echo "  zygote64 not found"
  fi
  echo "---------------- dependency check -------------------------------"
  miss=$(ctl_deps_report)
  if [ -n "$miss" ]; then
    echo "  referenced but UNRESOLVED libraries (dlopen will fail ->"
    echo "  'no vulkan device'). Fix: use a driver zip that ships them,"
    echo "  or pick the v849 Qualcomm package / Turnip instead:"
    printf '%s\n' "$miss" | sed 's/^/    /'
  else
    echo "  all referenced libraries resolve (payload or vendor)"
  fi
  echo "---------------- staged dir sanity ------------------------------"
  if [ -f "$MODDIR/.saved.mlist" ]; then
    while IFS='|' read -r s d k; do
      [ "$k" = "dir" ] || continue
      stage="$MODDIR/.staging$(echo "$d" | sed 's|/|_|g')"
      orig=$(ls "${GM_ROOT}$d" 2>/dev/null | wc -l)
      stag=$(ls "$stage" 2>/dev/null | wc -l)
      if [ "$stag" -lt "$orig" ]; then
        echo "  WARNING: staged $d has $stag entries, vendor has $orig —"
        echo "  staging copy is INCOMPLETE; re-select the driver"
      else
        echo "  $d: staged $stag entries (vendor $orig) OK"
      fi
    done < "$MODDIR/.saved.mlist"
  else
    echo "  no staged dirs in the current plan"
  fi
  echo "---------------- recent SELinux denials (avc) -------------------"
  avc=$(timeout 5 logcat -d -t 500 2>/dev/null \
         | grep "avc.*denied" | grep -iE "gpu|vulkan|egl|vendor|live_gpu|adreno" | tail -n 5)
  if [ -n "$avc" ]; then
    printf '%s\n' "$avc" | sed 's/^/  /'
    echo "  (if these name the module payload: the bundled sepolicy.rule"
    echo "   should cover it after one reboot; if not, report this output)"
  else
    echo "  none in the recent log"
  fi
  echo "---------------- self-test -------------------------------------"
  GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" selftest 2>&1 | sed 's/^/  /'
  echo "---------------- engine.log (last 25 lines) --------------------"
  tail -n 25 "$MODDIR/engine.log" 2>/dev/null | sed 's/^/  /'
  echo "================================================================"
}

ctl_driver_clear() { # back to stock: empty payload, drop mounts
  GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" unmount >/dev/null 2>&1
  rm -rf "$MODDIR/system" "$MODDIR/.drivercache" "$MODDIR/.staging"
  mkdir -p "$MODDIR/system"
  rm -f "$SELFILE" "$MODDIR/.saved.list" "$MODDIR/.saved.mlist"
  echo '{"ok":true}'
}

case "${1:-}" in
  status)       ctl_status ;;
  drivers)      ctl_drivers_list ;;
  doctor)       ctl_doctor "${2:-}" ;;
  deps-report)  ctl_deps_report ;;
  driver-select) [ -n "${2:-}" ] || pa_die "usage: driver-select <zip>"; ctl_driver_select "$2" ;;
  driver-clear) ctl_driver_clear ;;
  set-pkgs)     [ -n "${2:-}" ] || pa_die "usage: set-pkgs <list|->"; ctl_set_pkgs "$2" ;;
  list-apps)
    out=""
    for p in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
      ctl_pkg_ok "$p" || continue
      [ -n "$out" ] && out="$out,"
      out="$out\"$p\""
    done
    echo "[$out]"
    ;;
  start-watcher) sh "$MODDIR/bin/perapp.sh" start 2>&1 ;;
  stop-watcher)  sh "$MODDIR/bin/perapp.sh" stop 2>&1 ;;
  apply)         sh "$MODDIR/bin/autostart.sh" 2>&1; echo "applied" ;;
  unmount)
    sh "$MODDIR/bin/perapp.sh" stop >/dev/null 2>&1
    GM_QUIET=1 sh "$MODDIR/bin/gpu_mount.sh" unmount 2>&1
    echo "unmounted"
    ;;
  force-stop)
    pkg=${2:-}
    ctl_pkg_ok "$pkg" || pa_die "invalid package name"
    am force-stop "$pkg" 2>&1 && echo '{"ok":true}' || echo '{"ok":false}'
    ;;
  log)
    tail -n 80 "$MODDIR/engine.log" 2>/dev/null | base64 | tr -d '\n'
    echo
    ;;
  *) pa_die "unknown command: ${1:-}" ;;
esac
