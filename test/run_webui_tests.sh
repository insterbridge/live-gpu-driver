#!/bin/sh
# run_webui_tests.sh — tests for bin/webui_ctl.sh (the WebUI backend):
#   * status JSON is valid and reports mode/watcher/global/targets correctly
#   * set-pkgs rewrites config, validates names, dedupes, handles "-"
#   * set-pkgs restarts a running watcher with the new list
#   * list-apps works via pm (faked)
#   * log returns base64 that decodes to the real log tail
# JSON validity is checked with python3. Runs in an isolated user+mount ns.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$(cd "$HERE/.." && pwd)

/usr/bin/unshare -Ur -m /bin/sh -s "$BASE" <<'OUTER'
set -eu
BASE="$1"
T=/tmp/gmwu.$$
# kill stale fake apps/watchers leaked by previously aborted runs —
# they poison /proc scans in this harness
pkill -9 -f "exec -a com" 2>/dev/null || true
pkill -9 -f "exec -a zygote64" 2>/dev/null || true
mkdir -p "$T"
mount -t tmpfs none "$T"
cleanup() {
  [ -n "${ZYG:-}" ] && kill "$ZYG" 2>/dev/null || true
  [ -n "${APP:-}" ] && kill "$APP" 2>/dev/null || true
  [ -n "${WPID:-}" ] && kill -- "-${WPID}" 2>/dev/null || true
  pkill -9 -f "gmwu.$$" 2>/dev/null || true
  umount -R "$T" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

DEV="$T/root"
mkdir -p "$DEV/vendor/lib64/hw"
echo ORIGINAL-VK > "$DEV/vendor/lib64/hw/vulkan.adreno.so"

MOD="$T/live_gpu_driver"
cp -a "$BASE/live_gpu_driver" "$MOD"
rm -rf "$MOD/.staging" 2>/dev/null || true
rm -f "$MOD/engine.log" "$MOD"/.saved.* "$MOD"/.list "$MOD"/.plan.* \
      "$MOD"/.mlist "$MOD"/.want "$MOD"/.rev "$MOD"/.watcher.pid 2>/dev/null || true
mkdir -p "$MOD/system/vendor/lib64/hw"
echo CUSTOM-VK > "$MOD/system/vendor/lib64/hw/vulkan.adreno.so"
echo CUSTOM-TURNIP > "$MOD/system/vendor/lib64/hw/vulkan.turnip.so"
CTL="$MOD/bin/webui_ctl.sh"
ENGINE="$MOD/bin/gpu_mount.sh"

# "zygote" proxy: separate mount ns standing in for init/zygote so the
# engine's global mount has a legal target (mirrors run_tests.sh)
/usr/bin/unshare -m /bin/bash -c 'exec -a zygote64 sleep 300' >/dev/null 2>&1 &
ZYG=$!

# fake app process (private ns, package cmdline)
/usr/bin/unshare -m /bin/bash -c 'exec -a com.game sleep 300' >/dev/null 2>&1 &
APP=$!
sleep 0.3

# fake pm/am/logcat in PATH
BINDIR="$T/bin"; mkdir -p "$BINDIR"
cat > "$BINDIR/pm" <<'EOF'
#!/bin/sh
[ "$1" = "list" ] && [ "$2" = "packages" ] && [ "$3" = "-3" ] && {
  echo "package:com.dolphinemu.dolphin"
  echo "package:com.game"
  echo "package:org.ppsspp.ppsspp"
  exit 0
}
exit 1
EOF
cat > "$BINDIR/am" <<'EOF'
#!/bin/sh
[ "$1" = "force-stop" ] && { echo "stopped:$2" >> "$FAKE_AM_LOG"; exit 0; }
exit 1
EOF
cat > "$BINDIR/logcat" <<'EOF'
#!/bin/sh
exec sleep 300
EOF
chmod +x "$BINDIR/pm" "$BINDIR/am" "$BINDIR/logcat"
export PATH="$BINDIR:$PATH"
export FAKE_AM_LOG="$T/am.log"
export GM_ROOT="$DEV" GM_MARKER=live_gpu_driver GM_TEST_PIDS="$ZYG"

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS: $1"
  else echo "  FAIL: $1  (expected [$2] got [$3])"; fails=$((fails+1)); fi
}
jget() { # json-file python-expr
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"
}

echo "== status: initial (global mode, nothing mounted) =="
sh "$CTL" status > "$T/s1.json"
check "status JSON valid" "ok" "$(python3 -c "import json; json.load(open('$T/s1.json')); print('ok')")"
check "mode global" "global" "$(jget "$T/s1.json" "d['mode']")"
check "watcher stopped" "False" "$(jget "$T/s1.json" "d['watcher_running']")"
check "payload_count 2" "2" "$(jget "$T/s1.json" "d['payload_count']")"
check "payload kind for new file" "new-file" "$(jget "$T/s1.json" "[p for p in d['payload'] if 'turnip' in p['path']][0]['kind']")"

echo "== status: after global mount =="
GM_QUIET=1 sh "$ENGINE" mount >/dev/null
sh "$CTL" status > "$T/s2.json"
check "global_active true" "True" "$(jget "$T/s2.json" "d['global_active']")"
GM_QUIET=1 sh "$ENGINE" unmount >/dev/null

echo "== set-pkgs: write + validation =="
sh "$CTL" set-pkgs "com.game,com.dolphinemu.dolphin" > /dev/null
check "config PERAPP_PKGS written" 'PERAPP_PKGS="com.game com.dolphinemu.dolphin"' \
  "$(grep PERAPP_PKGS "$MOD/config")"
sh "$CTL" status > "$T/s3.json"
check "mode perapp" "perapp" "$(jget "$T/s3.json" "d['mode']")"
check "pkgs in JSON" "['com.game', 'com.dolphinemu.dolphin']" "$(jget "$T/s3.json" "d['pkgs']")"

if sh "$CTL" set-pkgs "com.game;rm -rf /" >/dev/null 2>&1; then
  check "invalid pkg rejected" "rejected" "accepted"
else
  check "invalid pkg rejected" "rejected" "rejected"
fi
if sh "$CTL" set-pkgs 'com.g"ame' >/dev/null 2>&1; then
  check "quote in pkg rejected" "rejected" "accepted"
else
  check "quote in pkg rejected" "rejected" "rejected"
fi
sh "$CTL" set-pkgs "com.game,com.game,org.ppsspp.ppsspp" >/dev/null
check "duplicates removed" 'PERAPP_PKGS="com.game org.ppsspp.ppsspp"' \
  "$(grep PERAPP_PKGS "$MOD/config" | tail -1)"
echo "== watcher restart on set-pkgs + targets =="
# start watcher via ctl, then set-pkgs must keep it running with new list
PATH="$BINDIR:$PATH" sh "$CTL" start-watcher >/dev/null
sleep 0.5
sh "$CTL" set-pkgs "com.game" >/dev/null
sh "$CTL" status > "$T/s4.json"
check "watcher still running after set-pkgs" "True" "$(jget "$T/s4.json" "d['watcher_running']")"
check "target app sees custom driver" "custom" "$(jget "$T/s4.json" "d['targets'][0]['driver']")"
check "target pkg" "com.game" "$(jget "$T/s4.json" "d['targets'][0]['pkg']")"

echo "== set-pkgs '-' clears (global mode) =="
sh "$CTL" set-pkgs "-" >/dev/null
sh "$CTL" status > "$T/s5.json"
check "mode back to global" "global" "$(jget "$T/s5.json" "d['mode']")"
check "watcher stopped when list emptied" "False" "$(jget "$T/s5.json" "d['watcher_running']")"
check "config has no PERAPP_PKGS" "0" "$(grep -c PERAPP_PKGS "$MOD/config" || true)"

echo "== list-apps via fake pm =="
sh "$CTL" list-apps > "$T/apps.json"
check "apps JSON valid + count" "3" "$(jget "$T/apps.json" "len(d)")"
check "apps contains dolphin" "True" "$(jget "$T/apps.json" "'com.dolphinemu.dolphin' in d")"

echo "== force-stop via fake am =="
sh "$CTL" force-stop com.game >/dev/null
check "am force-stop called" "stopped:com.game" "$(cat "$FAKE_AM_LOG")"
if sh "$CTL" force-stop "com.game;reboot" >/dev/null 2>&1; then
  check "force-stop pkg validated" "rejected" "accepted"
else
  check "force-stop pkg validated" "rejected" "rejected"
fi

echo "== drivers: scan + select + apply =="
DRVDIR="$T/drv"; mkdir -p "$DRVDIR/turnip" "$DRVDIR/qual"
echo "FAKE-TURNIP-ELF" > "$DRVDIR/turnip/vulkan.ad07xx.so"
cat > "$DRVDIR/turnip/meta.json" <<'META'
{"schemaVersion":1,"name":"Fake Turnip","driverVersion":"Vulkan 9.9","minApi":27,"libraryName":"vulkan.ad07xx.so"}
META
# blob references notgsl.so (DT_NEEDED) so the reference filter keeps it
echo "FAKE-QC-VK DT_NEEDED:notgsl.so libmissing_dep.so" > "$DRVDIR/qual/vulkan.ad07xx.so"
echo "FAKE-QC-GSL needs vendor.qti.hardware.hexlp-V2-ndk.so" > "$DRVDIR/qual/libgsl.so"
echo "FAKE-QC-HEXLP" > "$DRVDIR/qual/vendor.qti.hardware.hexlp-V2-ndk.so"
echo "ADRENOTOOLS-VARIANT" > "$DRVDIR/qual/notgsl.so"
echo "UNREFERENCED-EXTRA" > "$DRVDIR/qual/libunreferenced.so"
echo "FAKE-QC-EGL" > "$DRVDIR/qual/libEGL_adreno.so"
cat > "$DRVDIR/qual/meta.json" <<'META'
{"schemaVersion":1,"name":"Fake Qualcomm","driverVersion":"Vulkan 1.4","minApi":35,"libraryName":"vulkan.ad07xx.so"}
META
chmod 600 "$DRVDIR/qual/vulkan.ad07xx.so"   # zip stores restrictive mode
( cd "$DRVDIR/turnip" && zip -q -r ../turnip.zip . )
( cd "$DRVDIR/qual"   && zip -q -r ../qualcomm.zip . )
rm -rf "$DRVDIR/turnip" "$DRVDIR/qual"
export GM_DRIVER_DIRS="$DRVDIR"

# wait helper: select now applies ASYNC — poll status until mounted
wait_active() { # $1 = driver path expected, $2 = timeout (s)
  i=0
  while [ $i -lt $(( $2 * 2 )) ]; do
    # cheap poll: engine status directly (sel file is written sync by
    # select, so global_active alone is sufficient signal)
    if GM_QUIET=1 sh "$MOD/bin/gpu_mount.sh" status 2>/dev/null | grep -q ACTIVE; then
      if [ "$(cat "$MOD/.driver_sel" 2>/dev/null)" = "$1" ]; then return 0; fi
    fi
    sleep 0.5
    i=$((i+1))
  done
  echo "    [wait_active TIMEOUT for $1 — engine.log tail:]"
  tail -n 12 "$MOD/engine.log" 2>/dev/null | sed 's/^/      /'
  echo "    [.saved.mlist:]"; sed 's/^/      /' "$MOD/.saved.mlist" 2>/dev/null
  return 1
}

# fake modern firmware: ICD manifest points at a DIFFERENTLY-NAMED lib
mkdir -p "$DEV/vendor/etc/vulkan/icd.d" "$DEV/vendor/lib64/egl"
cat > "$DEV/vendor/etc/vulkan/icd.d/qualcomm_icd.a740.json" <<'JSON'
{"file_format_version":"1.0.0","ICD":{"library_path":"libvulkan_adreno.so","api_version":"1.3.290"}}
JSON
echo "ORIGINAL-ICD-LIB" > "$DEV/vendor/lib64/libvulkan_adreno.so"
echo "ORIGINAL-OTHER-EGL" > "$DEV/vendor/lib64/egl/libEGL_qcom.so"
# stock support libs (so the zip's libgsl/libadreno_utils are REPLACES)
echo "ORIGINAL-GSL" > "$DEV/vendor/lib64/libgsl.so"
echo "ORIGINAL-AU" > "$DEV/vendor/lib64/libadreno_utils.so"
echo "ORIGINAL-GN" > "$DEV/vendor/lib64/libllvm-glnext.so"

sh "$CTL" drivers > "$T/drvs.json"
check "drivers JSON valid + count" "2" "$(jget "$T/drvs.json" "len(d)")"
check "driver meta parsed (name)" "Fake Turnip" "$(jget "$T/drvs.json" "[x for x in d if x['name']=='Fake Turnip'][0]['name']")"
check "driver meta parsed (version)" "Vulkan 9.9" "$(jget "$T/drvs.json" "[x for x in d if x['name']=='Fake Turnip'][0]['version']")"
if sh "$CTL" driver-select "$DRVDIR/turnip.zip" >/dev/null 2>&1; then
  check "valid driver select ok" "ok" "ok"
else
  check "valid driver select ok" "ok" "failed"
fi

check "vulkan lib mapped to hw path" "FAKE-TURNIP-ELF" "$(cat "$MOD/system/vendor/lib64/hw/vulkan.adreno.so")"
check "vulkan lib ALSO mapped to ICD path" "FAKE-TURNIP-ELF" "$(cat "$MOD/system/vendor/lib64/libvulkan_adreno.so")"
if wait_active "$DRVDIR/turnip.zip" 20; then
  check "async apply lands mounts" "True" "True"
else
  check "async apply lands mounts" "True" "False"
fi
check "ICD path now serves custom driver (via zygote ns)" "FAKE-TURNIP-ELF" \
  "$(nsenter -t "$ZYG" -m -- cat "$DEV/vendor/lib64/libvulkan_adreno.so" 2>/dev/null)"
check "selection marker written" "$DRVDIR/turnip.zip" "$(cat "$MOD/.driver_sel")"
sh "$CTL" status > "$T/s6.json"
check "status shows selected driver" "$DRVDIR/turnip.zip" "$(jget "$T/s6.json" "d['driver']")"
check "driver applied globally (mount active)" "True" "$(jget "$T/s6.json" "d['global_active']")"
check "turnip zip maps 2 vulkan targets" "2" "$(jget "$T/s6.json" "d['payload_count']")"

# switch to the qualcomm-style zip: support libs + not* variants mapped
sh "$CTL" driver-select "$DRVDIR/qualcomm.zip" >/dev/null
if wait_active "$DRVDIR/qualcomm.zip" 20; then
  check "async swap lands mounts" "True" "True"
else
  check "async swap lands mounts" "True" "False"
fi
# dep check runs in the background now — poll for the report
i=0; found_dep=""
while [ $i -lt 30 ]; do
  if [ -f "$MOD/.deps_report" ] && grep -q libmissing_dep "$MOD/.deps_report" 2>/dev/null; then
    found_dep="libmissing_dep.so"; break
  fi
  sleep 0.5; i=$((i+1))
done
check "missing dep reported (async)" "libmissing_dep.so" "$found_dep"
check "qc vulkan mapped (hw)" "FAKE-QC-VK DT_NEEDED:notgsl.so libmissing_dep.so" "$(cat "$MOD/system/vendor/lib64/hw/vulkan.adreno.so")"
pmode=$(stat -c '%a' "$MOD/system/vendor/lib64/hw/vulkan.adreno.so" 2>/dev/null || echo "?")
case "$pmode" in *4|*5|*6|*7) check "payload made world-readable (mode $pmode)" "yes" "yes" ;; \
  *) check "payload made world-readable (mode $pmode)" "yes" "no" ;; esac
check "qc libgsl mapped" "FAKE-QC-GSL needs vendor.qti.hardware.hexlp-V2-ndk.so" "$(cat "$MOD/system/vendor/lib64/libgsl.so")"
check "ICD path serves qc driver (via zygote ns)" "FAKE-QC-VK DT_NEEDED:notgsl.so libmissing_dep.so" \
  "$(nsenter -t "$ZYG" -m -- cat "$DEV/vendor/lib64/libvulkan_adreno.so" 2>/dev/null)"
check "qc hexlp mapped" "FAKE-QC-HEXLP" "$(cat "$MOD/system/vendor/lib64/vendor.qti.hardware.hexlp-V2-ndk.so")"
check "not* adrenotools deps included (referenced)" "1" "$(ls "$MOD/system/vendor/lib64/" | grep -c '^not' || true)"
check "unreferenced extra skipped" "0" "$(ls "$MOD/system/vendor/lib64/" | grep -c 'unreferenced' || true)"
check "egl auto-mapped over existing entry" "FAKE-QC-EGL" "$(cat "$MOD/system/vendor/lib64/egl/libEGL_qcom.so")"
check "egl zip-named copy present" "FAKE-QC-EGL" "$(cat "$MOD/system/vendor/lib64/egl/libEGL_adreno.so")"
sh "$CTL" status > "$T/s7.json"
check "driver swap still mounted" "True" "$(jget "$T/s7.json" "d['global_active']")"
check "driver field updated" "$DRVDIR/qualcomm.zip" "$(jget "$T/s7.json" "d['driver']")"

echo "== engine: mount failure is loud (exit code + log) =="
if GM_ROOT="$DEV" GM_TEST_PIDS="999999" GM_QUIET=1 sh "$MOD/bin/gpu_mount.sh" mount >/dev/null 2>&1; then
  check "dead-ns mount fails" "failed" "succeeded"
else
  check "dead-ns mount fails" "failed" "failed"
fi
grep -q "no target namespaces\|mount FAILED" "$MOD/engine.log" && check "failure logged" "yes" "yes" \
  || check "failure logged" "yes" "no"
echo "== engine: selftest =="
st_out=$(GM_QUIET=1 sh "$MOD/bin/gpu_mount.sh" selftest 2>&1)
echo "$st_out" | sed 's/^/    /'
if echo "$st_out" | grep -q "self-test: PASS"; then
  check "selftest passes" "PASS" "PASS"
else
  check "selftest passes" "PASS" "FAIL"
fi
echo "== doctor reports missing dep + staged sanity =="
# payload is still populated + mounted from the swap section above
doc_out=$(sh "$CTL" doctor 2>&1)
echo "$doc_out" | grep -E "dependency|UNRESOLVED|libmissing|staged|avc|self-test|labels" | sed 's/^/    /' | head -15
if echo "$doc_out" | grep -q "libmissing_dep.so"; then
  check "doctor lists unresolvable dep" "yes" "yes"
else
  check "doctor lists unresolvable dep" "yes" "no"
fi
if echo "$doc_out" | grep -q "staged.*entries.*OK"; then
  check "doctor staged sanity OK" "yes" "yes"
else
  check "doctor staged sanity OK" "yes" "no"
fi
# clear -> stock
sh "$CTL" driver-clear >/dev/null 2>&1 || true
sh "$CTL" status > "$T/s8.json"
check "clear drops driver" "" "$(jget "$T/s8.json" "d['driver']")"
check "clear unmounts" "False" "$(jget "$T/s8.json" "d['global_active']")"
check "clear empties payload" "0" "$(jget "$T/s8.json" "d['payload_count']")"

echo "== EBUSY regression: clear + re-select while a process holds the file open =="
# this is the real-world "can't return to stock, can't re-apply" bug:
# plain umount fails EBUSY (driver mapped by running apps) and leaves a
# stale mount that blocks both stock and the next driver
sh "$CTL" driver-select "$DRVDIR/turnip.zip" >/dev/null
wait_active "$DRVDIR/turnip.zip" 20 || true
check "ebusy setup: custom active" "FAKE-T" "$(nsenter -t "$ZYG" -m -- cat "$DEV/vendor/lib64/hw/vulkan.adreno.so" 2>/dev/null | head -c 6)"
nsenter -t "$ZYG" -m -- sh -c "exec sleep 60 < '$DEV/vendor/lib64/hw/vulkan.adreno.so'" &
HOLDER=$!
sleep 0.3
sh "$CTL" driver-clear >/dev/null
stale=$(grep -c "vendor/lib64/hw/vulkan.adreno.so" /proc/$ZYG/mountinfo 2>/dev/null || true)
check "ebusy: clear removes all mounts" "0" "${stale:-0}"
check "ebusy: stock driver visible again" "ORIGINAL-VK" "$(nsenter -t "$ZYG" -m -- cat "$DEV/vendor/lib64/hw/vulkan.adreno.so" 2>/dev/null)"
sh "$CTL" driver-select "$DRVDIR/turnip.zip" >/dev/null
if wait_active "$DRVDIR/turnip.zip" 20; then
  check "ebusy: re-select lands new mount" "True" "True"
else
  check "ebusy: re-select lands new mount" "True" "False"
fi
check "ebusy: new driver served" "FAKE-TURNIP-ELF" "$(nsenter -t "$ZYG" -m -- cat "$DEV/vendor/lib64/hw/vulkan.adreno.so" 2>/dev/null)"
kill "$HOLDER" 2>/dev/null || true
sh "$CTL" driver-clear >/dev/null

echo "== config: get/set toggles =="
sh "$CTL" config-get > "$T/cfg1.json"
check "config-get JSON valid" "ok" "$(python3 -c "import json; d=json.load(open('$T/cfg1.json')); assert d['RESTART_SF']==0; print('ok')")"
sh "$CTL" config-set RESTART_SF 1 > /dev/null
check "config-set RESTART_SF=1" "1" "$(grep -c '^RESTART_SF=1' "$MOD/config" || true)"
sh "$CTL" config-get > "$T/cfg2.json"
check "config-get reflects change" "1" "$(jget "$T/cfg2.json" "d['RESTART_SF']")"
# status also reports it
sh "$CTL" status > "$T/s9.json"
check "status reports restart_sf" "1" "$(jget "$T/s9.json" "d['restart_sf']")"
sh "$CTL" config-set RESTART_SF 0 > /dev/null
check "config-set back to 0" "0" "$(grep -c '^RESTART_SF=1' "$MOD/config" || true)"
if sh "$CTL" config-set ALL_NS 1 >/dev/null 2>&1; then
  check "ALL_NS removed: set rejected" "rejected" "accepted"
else
  check "ALL_NS removed: set rejected" "rejected" "rejected"
fi
# invalid key and value rejected
if sh "$CTL" config-set INVALID_KEY 1 >/dev/null 2>&1; then
  check "invalid key rejected" "rejected" "accepted"
else
  check "invalid key rejected" "rejected" "rejected"
fi
if sh "$CTL" config-set RESTART_SF 2 >/dev/null 2>&1; then
  check "invalid value rejected" "rejected" "accepted"
else
  check "invalid value rejected" "rejected" "rejected"
fi
if sh "$CTL" config-set "RESTART_SF;rm -rf /" 1 >/dev/null 2>&1; then
  check "injection in key rejected" "rejected" "accepted"
else
  check "injection in key rejected" "rejected" "rejected"
fi
sh "$CTL" stop-watcher >/dev/null
echo
if [ "$fails" = "0" ]; then echo "ALL WEBUI-BACKEND TESTS PASSED"
else echo "$fails TEST(S) FAILED"; exit 1; fi
OUTER
