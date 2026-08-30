#!/bin/sh
# build.sh — pack the module into a manager-flashable zip
set -e
cd "$(dirname "$0")"
OUT="${OUT:-live_gpu_driver-v1.2.0.zip}"

if command -v zip >/dev/null 2>&1; then
  ( cd live_gpu_driver && zip -r9 -q "../$OUT" . \
      -x "engine.log" -x ".list" -x ".plan.*" -x ".mlist" -x ".want" \
      -x ".rev" -x ".saved.*" -x ".staging/*" -x "*.log" \
      -x ".watcher.pid" -x ".relabeled" -x ".sweep.done" -x ".config.tmp" )
else
  python3 - "$OUT" <<'EOF'
import os, sys, zipfile
out = sys.argv[1]
z = zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9)
for dp, dn, fn in os.walk("live_gpu_driver"):
    dn[:] = [d for d in dn if d != ".staging"]
    for f in fn:
        rel = os.path.relpath(os.path.join(dp, f), "live_gpu_driver")
        if rel in ("engine.log", ".list", ".mlist", ".want", ".rev",
                   ".watcher.pid", ".relabeled", ".sweep.done", ".config.tmp") \
           or rel.startswith(".plan") or rel.startswith(".saved") \
           or rel.endswith(".log"):
            continue
        exe = f.endswith(".sh") or dp.endswith("bin")
        zi = zipfile.ZipInfo(rel)
        zi.external_attr = (0o755 if exe else 0o644) << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(dp, f), "rb") as fh:
            z.writestr(zi, fh.read())
z.close()
EOF
fi
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
