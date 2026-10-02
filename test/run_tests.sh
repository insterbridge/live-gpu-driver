#!/bin/sh
# run_tests.sh — behavioural test of the gpu_mount.sh engine.
#
# Everything runs inside an isolated user+mount namespace
# (unshare -Ur -m, util-linux marks the copies private, so nothing
# propagates to the host) with a private tmpfs:
#   * no host root is needed,
#   * the REAL pid-1 namespace is never touched (GM_TEST_PIDS replaces
#     the init/zygote/surfaceflinger target set with a throwaway process),
#   * GM_ROOT points "the device" at a fake /vendor tree on the tmpfs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$(cd "$HERE/.." && pwd)

/usr/bin/unshare -Ur -m /bin/sh -s "$BASE" <<'OUTER'
set -eu
BASE="$1"
T=/tmp/gmtest.$$
mkdir -p "$T"
mount -t tmpfs none "$T"

# ---- fake device filesystem (the "vendor" partition) --------------------
DEV="$T/root"                       # GM_ROOT target
mkdir -p "$DEV/vendor/lib64/egl" "$DEV/vendor/lib64/hw"
echo ORIGINAL-EGL   > "$DEV/vendor/lib64/egl/libEGL_adreno.so"
echo ORIGINAL-GLES2 > "$DEV/vendor/lib64/egl/libGLESv2_adreno.so"
echo ORIGINAL-VK    > "$DEV/vendor/lib64/hw/vulkan.adreno.so"
echo ORIGINAL-CB    > "$DEV/vendor/lib64/libCB.so"
echo ORIGINAL-AUDIO > "$DEV/vendor/lib64/hw/audio.primary.fake.so"

# ---- module under test (copy so tests don't pollute the source) ---------
MOD="$T/live_gpu_driver"
cp -a "$BASE/live_gpu_driver" "$MOD"
rm -f "$MOD/engine.log" "$MOD"/.list "$MOD"/.plan.* "$MOD"/.mlist "$MOD"/.want "$MOD"/.rev 2>/dev/null || true
rm -rf "$MOD/.staging" "$MOD"/.staging_* 2>/dev/null || true

# ---- payload: 2 replacements + 1 brand-new filename ---------------------
mkdir -p "$MOD/system/vendor/lib64/hw" "$MOD/system/vendor/lib64/egl"
echo CUSTOM-VK     > "$MOD/system/vendor/lib64/hw/vulkan.adreno.so"   # replace
echo CUSTOM-TURNIP > "$MOD/system/vendor/lib64/hw/vulkan.turnip.so"   # NEW name
echo CUSTOM-EGL    > "$MOD/system/vendor/lib64/egl/libEGL_adreno.so"  # replace

ENGINE="$MOD/bin/gpu_mount.sh"

# "zygote": shares this namespace, engine mounts go HERE
sleep 300 & ZYG=$!
# "pristine observer": snapshot namespace taken BEFORE any mounts
/usr/bin/unshare -m -- sleep 300 & PRISTINE=$!
sleep 0.3

export GM_ROOT="$DEV" GM_TEST_PIDS="$ZYG" GM_MARKER=live_gpu_driver

fails=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then
    echo "  PASS: $1"
  else
    echo "  FAIL: $1  (expected [$2] got [$3])"
    fails=$((fails+1))
  fi
}
view() { nsenter -t "$ZYG" -m -- cat "$1" 2>/dev/null || echo "(missing)"; }
mntcount() {
  c=$(nsenter -t "$ZYG" -m -- grep -cF " $1 " /proc/self/mountinfo 2>/dev/null || true)
  echo "${c:-0}"
}

echo "== engine: plan =="
sh "$ENGINE" plan
echo

echo "== engine: mount =="
sh "$ENGINE" mount
echo

echo "== assertions: replacement correctness =="
check "replaced vulkan.adreno.so content"        "CUSTOM-VK"      "$(view "$DEV/vendor/lib64/hw/vulkan.adreno.so")"
check "new vulkan.turnip.so visible"             "CUSTOM-TURNIP"  "$(view "$DEV/vendor/lib64/hw/vulkan.turnip.so")"
check "replaced libEGL_adreno.so content"        "CUSTOM-EGL"     "$(view "$DEV/vendor/lib64/egl/libEGL_adreno.so")"
check "unrelated egl lib untouched (staged hw)"  "ORIGINAL-GLES2" "$(view "$DEV/vendor/lib64/egl/libGLESv2_adreno.so")"
check "unrelated hw lib survives staged dir"     "ORIGINAL-AUDIO" "$(view "$DEV/vendor/lib64/hw/audio.primary.fake.so")"
check "libCB untouched"                          "ORIGINAL-CB"    "$(view "$DEV/vendor/lib64/libCB.so")"

echo "== assertions: staging lives INSIDE .staging (no /data leak) =="
# regression: <= v1.2.0 staged dirs as $STAGE-prefixed SIBLINGS
# (.staging_vendor_lib64_hw) which the cleanup paths never removed —
# every staged vendor dir (up to ~1 GB) leaked into /data forever
check "staged dir inside .staging/" "1" \
  "$(ls -d "$MOD/.staging/dir_vendor_lib64_hw" 2>/dev/null | wc -l)"
check "no legacy sibling staging dirs" "0" \
  "$(ls -d "$MOD"/.staging_vendor* 2>/dev/null | wc -l)"
sh "$ENGINE" unmount >/dev/null
check "unmount removes staging tree" "0" \
  "$(ls -d "$MOD"/.staging "$MOD"/.staging_* 2>/dev/null | wc -l)"
sh "$ENGINE" mount >/dev/null

echo "== assertions: vendor partition never written =="
check "on-disk vendor file unmodified (pristine ns)" "ORIGINAL-VK" \
  "$(nsenter -t "$PRISTINE" -m -- cat "$DEV/vendor/lib64/hw/vulkan.adreno.so" 2>/dev/null || echo NOPE)"

echo "== assertions: exactly one mount per path =="
check "one mount: hw staged dir" "1" "$(mntcount "$DEV/vendor/lib64/hw")"
check "one mount: egl file"      "1" "$(mntcount "$DEV/vendor/lib64/egl/libEGL_adreno.so")"

echo "== engine: idempotency (second mount must not stack) =="
sh "$ENGINE" mount >/dev/null
check "still one mount: hw staged dir" "1" "$(mntcount "$DEV/vendor/lib64/hw")"
check "still one mount: egl file"      "1" "$(mntcount "$DEV/vendor/lib64/egl/libEGL_adreno.so")"
check "content still CUSTOM-VK"        "CUSTOM-VK" "$(view "$DEV/vendor/lib64/hw/vulkan.adreno.so")"

echo "== engine: status =="
sh "$ENGINE" status
st=$(sh "$ENGINE" status | grep -c "ACTIVE" || true)
check "status reports 3 ACTIVE payloads" "3" "$st"

echo "== engine: unmount =="
sh "$ENGINE" unmount
check "restored vulkan.adreno.so"  "ORIGINAL-VK"  "$(view "$DEV/vendor/lib64/hw/vulkan.adreno.so")"
check "new file gone again"        "(missing)"    "$(view "$DEV/vendor/lib64/hw/vulkan.turnip.so")"
check "restored libEGL_adreno.so"  "ORIGINAL-EGL" "$(view "$DEV/vendor/lib64/egl/libEGL_adreno.so")"
left=$(nsenter -t "$ZYG" -m -- grep -cF "$MOD" /proc/self/mountinfo 2>/dev/null || true)
check "no leftover mounts" "0" "${left:-0}"

echo "== engine: payload changed (replan must unmount + remount cleanly) =="
echo CUSTOM-GLES2 > "$MOD/system/vendor/lib64/egl/libGLESv2_adreno.so"
sh "$ENGINE" mount >/dev/null
check "replanned: vulkan.adreno.so still CUSTOM" "CUSTOM-VK" "$(view "$DEV/vendor/lib64/hw/vulkan.adreno.so")"
check "replanned: new turnip file still visible"  "CUSTOM-TURNIP" "$(view "$DEV/vendor/lib64/hw/vulkan.turnip.so")"
check "replanned: newly added file replaced"      "CUSTOM-GLES2" "$(view "$DEV/vendor/lib64/egl/libGLESv2_adreno.so")"
check "replanned: one mount: hw dir"  "1" "$(mntcount "$DEV/vendor/lib64/hw")"
check "replanned: one mount: egl libEGL" "1" "$(mntcount "$DEV/vendor/lib64/egl/libEGL_adreno.so")"
check "replanned: one mount: egl GLES2"  "1" "$(mntcount "$DEV/vendor/lib64/egl/libGLESv2_adreno.so")"
check "replanned: pristine vendor still intact" "ORIGINAL-VK" \
  "$(nsenter -t "$PRISTINE" -m -- cat "$DEV/vendor/lib64/hw/vulkan.adreno.so" 2>/dev/null || echo NOPE)"
st2=$(sh "$ENGINE" status | grep -c "ACTIVE" || true)
check "replanned: status reports 4 ACTIVE" "4" "$st2"

echo "== engine: v1.2.0 legacy staging plan is rejected (upgrade path) =="
# an upgraded install carries a saved plan whose staged dirs point at the
# leaked legacy SIBLING form. Reusing it would rebind the leaked dir and
# never rebuild under .staging/ — the plan must be rejected + rebuilt.
mkdir -p "$MOD/.staging_vendor_lib64_hw"
echo LEGACY > "$MOD/.staging_vendor_lib64_hw/legacy_marker.so"
cp -f "$MOD/.list" "$MOD/.saved.list"
printf '%s|%s|dir\n' "$MOD/.staging_vendor_lib64_hw" "/vendor/lib64/hw" > "$MOD/.saved.mlist"
sh "$ENGINE" mount >/dev/null
check "legacy sibling dir not used as mount source" "0" \
  "$(nsenter -t "$ZYG" -m -- grep -cF "$MOD/.staging_vendor_lib64_hw" /proc/self/mountinfo 2>/dev/null || true)"
check "plan rebuilt under .staging/" "1" \
  "$(awk -F'|' -v s="$MOD/.staging/dir_vendor_lib64_hw" '$1==s && $3=="dir"' "$MOD/.saved.mlist" | wc -l)"
check "driver served after rebuild"    "CUSTOM-VK"     "$(view "$DEV/vendor/lib64/hw/vulkan.adreno.so")"
check "new file served after rebuild"  "CUSTOM-TURNIP" "$(view "$DEV/vendor/lib64/hw/vulkan.turnip.so")"
check "leaked legacy dir deleted (frees /data)" "0" \
  "$(ls -d "$MOD/.staging_vendor_lib64_hw" 2>/dev/null | wc -l)"

echo "== engine: stage-clean REFUSES while staging is a live mount source =="
# field regression: deleting staging while /vendor/lib64 is bind-mounted
# from it empties the mounted dir; vendor HALs SIGSEGV on dlopen ->
# system_server dies -> soft reboot. The guard must refuse, not delete.
mkdir -p "$MOD/.staging/dir_vendor_lib64_hw"
echo GUARDED > "$MOD/.staging/dir_vendor_lib64_hw/x.so"
sh "$ENGINE" mount >/dev/null
if GM_TEST_PIDS="$ZYG" sh "$ENGINE" stage-clean >/dev/null 2>&1; then
  check "stage-clean refuses while mounted" "refused" "deleted anyway"
else
  check "stage-clean refuses while mounted" "refused" "refused"
fi
check "staging preserved while mounted" "1" \
  "$(ls -d "$MOD/.staging/dir_vendor_lib64_hw" 2>/dev/null | wc -l)"
sh "$ENGINE" unmount >/dev/null
GM_TEST_PIDS="$ZYG" sh "$ENGINE" stage-clean >/dev/null 2>&1
check "stage-clean deletes once unmounted" "0" \
  "$(ls -d "$MOD/.staging" 2>/dev/null | wc -l)"
sh "$ENGINE" mount >/dev/null

echo "== engine: final unmount =="
sh "$ENGINE" unmount >/dev/null
check "final: restored vulkan.adreno.so" "ORIGINAL-VK" "$(view "$DEV/vendor/lib64/hw/vulkan.adreno.so")"
check "final: new file gone" "(missing)" "$(view "$DEV/vendor/lib64/hw/vulkan.turnip.so")"
check "final: restored GLES2" "ORIGINAL-GLES2" "$(view "$DEV/vendor/lib64/egl/libGLESv2_adreno.so")"
left2=$(nsenter -t "$ZYG" -m -- grep -cF "$MOD" /proc/self/mountinfo 2>/dev/null || true)
check "final: no leftover mounts" "0" "${left2:-0}"

kill "$ZYG" "$PRISTINE" 2>/dev/null || true
umount -R "$T" 2>/dev/null || true
rm -rf "$T"
echo
if [ "$fails" = "0" ]; then
  echo "ALL TESTS PASSED"
else
  echo "$fails TEST(S) FAILED"
  exit 1
fi
OUTER
