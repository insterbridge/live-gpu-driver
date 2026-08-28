#!/system/bin/sh
# service.sh — boot hook. Only runs if your root solution executes module
# scripts (modern KernelSU runs it even in late-load mode, at `ksud
# late-load` time). Harmless no-op otherwise.
MODDIR=${MODDIR:-$(cd "$(dirname "$0")" && pwd)}
sh "$MODDIR/bin/autostart.sh" >/dev/null 2>&1
exit 0
