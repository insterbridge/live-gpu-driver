#!/system/bin/sh
# boot-completed.sh — runs once the system finishes booting (late-load
# mode runs it right after service.sh). Belt-and-braces: autostart is
# idempotent, so this just guarantees the watcher/mounts exist even if
# an earlier stage was skipped.
MODDIR=${MODDIR:-$(cd "$(dirname "$0")" && pwd)}
sh "$MODDIR/bin/autostart.sh" >/dev/null 2>&1
exit 0
