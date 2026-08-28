#!/bin/sh
# run_perapp_tests.sh — behavioural tests for per-app mode:
#   * engine `ns <pid>` mounts into exactly ONE namespace
#   * engine refuses pids sharing an init/zygote namespace (leak guard)
#   * watcher: initial sweep mounts running targets
#   * watcher: logcat "Start proc" line mounts newly started target
#   * non-target processes keep the stock driver throughout
#   * watcher stop; full unmount restores everything
#
# Runs inside an isolated user+mount namespace with a private tmpfs.
# logcat and pidof are faked via PATH injection.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BASE=$(cd "$HERE/.." && pwd)

/usr/bin/unshare -Ur -m /bin/sh -s "$BASE" <<'OUTER'
set -eu
BASE="$1"
T=/tmp/gmpa.$$
mkdir -p "$T"
mount -t tmpfs none "$T"

DEV="$T/root"
mkdir -p "$DEV/vendor/lib64/hw"
echo ORIGINAL-VK > "$DEV/vendor/lib64/hw/vulkan.adreno.so"
echo ORIGINAL-AUDIO > "$DEV/vendor/lib64/hw/audio.primary.fake.so"

MOD="$T/live_gpu_driver"
cp -a "$BASE/live_gpu_driver" "$MOD"
rm -rf "$MOD/.staging" 2>/dev/null || true
rm -f "$MOD/engine.log" "$MOD"/.saved.* "$MOD"/.list "$MOD"/.plan.* \
      "$MOD"/.mlist "$MOD"/.want "$MOD"/.rev "$MOD"/.watcher.pid 2>/dev/null || true
mkdir -p "$MOD/system/vendor/lib64/hw"
echo CUSTOM-VK     > "$MOD/system/vendor/lib64/hw/vulkan.adreno.so"
echo CUSTOM-TURNIP > "$MOD/system/vendor/lib64/hw/vulkan.turnip.so"
echo "PERAPP_PKGS=\"com.game\"" >> "$MOD/config"

ENGINE="$MOD/bin/gpu_mount.sh"
WATCHER="$MOD/bin/perapp.sh"

# fake app processes: private mount ns, cmdline = package name.
# NOTE 1: background INSIDE the function — a backgrounded function call
# would put $! on the caller's subshell (harness ns), not the unshared
# process.
# NOTE 2: the app's stdout MUST be redirected away — when spawned via
# $(...) the background process inherits the substitution pipe and
# keeps it open, blocking the substitution until the app exits (300s).
app() {
  /usr/bin/unshare -m /bin/bash -c "exec -a $1 sleep 300" >/dev/null 2>&1 &
  echo $!
}
APPA=$(app com.game)
APPB=$(app com.other)
sleep 0.3

# sanity: apps must live in namespaces distinct from each other + harness
ns_a=$(readlink "/proc/$APPA/ns/mnt"); ns_b=$(readlink "/proc/$APPB/ns/mnt"); ns_h=$(readlink /proc/self/ns/mnt)
[ "$ns_a" != "$ns_h" ] && [ "$ns_b" != "$ns_h" ] && [ "$ns_a" != "$ns_b" ] \
  || { echo "FATAL: test apps do not have distinct namespaces"; exit 1; }

# fake logcat: streams lines appended to a file
BINDIR="$T/bin"; mkdir -p "$BINDIR"
LOGSRC="$T/logcat.src"; : > "$LOGSRC"
cat > "$BINDIR/logcat" <<EOF
#!/bin/sh
exec tail -n +1 -f "$LOGSRC"
EOF
chmod +x "$BINDIR/logcat"

export GM_ROOT="$DEV" GM_MARKER=live_gpu_driver

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS: $1"
  else echo "  FAIL: $1  (expected [$2] got [$3])"; fails=$((fails+1)); fi
}
view() { nsenter -t "$1" -m -- cat "$DEV/vendor/lib64/hw/vulkan.adreno.so" 2>/dev/null || echo "(missing)"; }
turnip() { nsenter -t "$1" -m -- cat "$DEV/vendor/lib64/hw/vulkan.turnip.so" 2>/dev/null || echo "(missing)"; }
mcount() { c=$(nsenter -t "$1" -m -- grep -cF " $2 " /proc/self/mountinfo 2>/dev/null || true); echo "${c:-0}"; }

echo "== engine: ns <pid> mounts into ONE namespace only =="
GM_QUIET=1 sh "$ENGINE" ns "$APPA"
check "target app gets CUSTOM-VK"        "CUSTOM-VK"     "$(view "$APPA")"
check "target app sees new turnip file"  "CUSTOM-TURNIP" "$(turnip "$APPA")"
check "other app keeps ORIGINAL-VK"      "ORIGINAL-VK"   "$(view "$APPB")"
check "global view keeps ORIGINAL-VK"    "ORIGINAL-VK"   "$(cat "$DEV/vendor/lib64/hw/vulkan.adreno.so")"
check "other app: no turnip file"        "(missing)"     "$(turnip "$APPB")"
check "target app: exactly 1 mount"      "1" "$(mcount "$APPA" "$DEV/vendor/lib64/hw")"
check "other app: 0 mounts"              "0" "$(mcount "$APPB" "$DEV/vendor/lib64/hw")"

echo "== engine: leak guard (pid sharing a zygote-like ns is refused) =="
# GM_ZYGOTE_PIDS claims APPA's own namespace is a zygote namespace;
# mounting into APPA must then be refused.
if GM_QUIET=1 GM_ZYGOTE_PIDS="$APPA" sh "$ENGINE" ns "$APPA" 2>/dev/null; then
  check "guard refuses zygote-ns pid" "refused" "mounted"
else
  check "guard refuses zygote-ns pid" "refused" "refused"
fi

echo "== watcher: start + initial sweep mounts running target =="
PATH="$BINDIR:$PATH" sh "$WATCHER" start
sleep 1
[ -f "$MOD/.watcher.pid" ] && wp=$(cat "$MOD/.watcher.pid") || wp=""
if [ -n "$wp" ] && [ -d "/proc/$wp" ]; then r="alive"; else r="dead"; fi
check "watcher process alive" "alive" "$r"

echo "== watcher: logcat Start-proc line mounts new target process =="
APPC=$(app com.game)
sleep 0.3
echo "Start proc $APPC:com.game/u0a99 for activity com.game/.MainActivity" >> "$LOGSRC"
sleep 1.5
check "newly started app gets CUSTOM-VK"   "CUSTOM-VK" "$(view "$APPC")"
check "newly started app sees turnip file" "CUSTOM-TURNIP" "$(turnip "$APPC")"

echo "== watcher: non-target processes stay stock =="
check "non-target app still ORIGINAL-VK"   "ORIGINAL-VK" "$(view "$APPB")"
check "non-target app still no turnip"     "(missing)"   "$(turnip "$APPB")"

echo "== watcher: status reports =="
sh "$WATCHER" status | sed 's/^/    /'
st_out=$(sh "$WATCHER" status | grep -c "com.game.*custom driver" || true)
check "status shows custom driver on target" "2" "$st_out"

echo "== watcher: stop (mounts stay until apps die — by design) =="
sh "$WATCHER" stop
sleep 0.3
[ -f "$MOD/.watcher.pid" ] && r="still-running" || r="stopped"
check "watcher pidfile removed" "stopped" "$r"
check "target keeps driver after watcher stop" "CUSTOM-VK" "$(view "$APPA")"

echo "== full unmount restores everything =="
GM_QUIET=1 sh "$ENGINE" unmount
check "target app restored"     "ORIGINAL-VK" "$(view "$APPA")"
check "late app restored"       "ORIGINAL-VK" "$(view "$APPC")"
check "non-target still stock"  "ORIGINAL-VK" "$(view "$APPB")"
check "turnip gone everywhere"  "(missing)"   "$(turnip "$APPC")"

kill "$APPA" "$APPB" "$APPC" 2>/dev/null || true
kill "$wp" 2>/dev/null || true
umount -R "$T" 2>/dev/null || true
rm -rf "$T"
echo
if [ "$fails" = "0" ]; then echo "ALL PER-APP TESTS PASSED"
else echo "$fails TEST(S) FAILED"; exit 1; fi
OUTER
