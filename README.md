# Live GPU Driver — runtime driver swapping for late-loaded root

A KernelSU / APatch module that swaps the Android GPU driver (Vulkan /
EGL) **at runtime** using bind mounts — no OverlayFS, no Magic Mount,
no boot-time root required.

Built for **late-loaded KernelSU** where module system directories are
never magic-mounted, but works with any root solution (GKI, LKM, APatch,
Magisk).

## How it works

```
┌─────────────────────────────────────────────────────────┐
│  Driver .zip files (Adreno-Tools-Drivers format)          │
│  dropped into /sdcard/Download                          │
│                         │                               │
│                         ▼                               │
│  WebUI: pick a driver → engine extracts, maps,          │
│  bind-mounts over /vendor paths                         │
│                         │                               │
│    ┌────────────────────┼────────────────────┐          │
│    ▼                    ▼                    ▼          │
│  init (pid 1)      zygote64 / zygote    surfaceflinger  │
│    └──── mount namespaces ────────────────────┘          │
│                         │                               │
│                         ▼                               │
│  Every app forked from zygote afterwards                │
│  resolves the custom driver files                       │
└─────────────────────────────────────────────────────────┘
```

The vendor partition is **never written** — dm-verity/AVB stay intact,
and a reboot restores everything to stock. Rollback is one tap.

## Features

- **Driver-zip management** — drop any [Adreno-Tools-Drivers](https://github.com/StevenMXZ/Adreno-Tools-Drivers)
  package (Turnip or Qualcomm) into `/sdcard/Download`, pick it from
  the WebUI. Swap drivers without reflashing.
- **Global mode** — every app started after apply gets the custom driver
- **Per-app mode** — only listed packages get it (banking, camera, etc.
  stay stock)
- **Auto-detection** — finds every Vulkan loader path (legacy hw module,
  ICD manifests, any `vulkan.*.so` in sphal search dirs)
- **SELinux-safe** — files are relabeled to the stock vendor label;
  bundled `sepolicy.rule` as fallback; never sets the device permissive
- **Self-diagnosing** — `doctor` command checks the entire chain:
  mounts, labels, permissions, dependencies, mapped libs, avc denials
- **Non-blocking WebUI** — driver selection returns in ~2s; staging and
  mounting run in background with live progress feedback

## Install

```
./build.sh                          # produces live_gpu_driver-<ver>.zip
adb push live_gpu_driver-*.zip /sdcard/
```

Install from KernelSU / APatch manager → Modules → Install from storage.

## Usage

1. **Get a driver** — download from
   [Adreno-Tools-Drivers](https://github.com/StevenMXZ/Adreno-Tools-Drivers/releases)
   (Turnip or Qualcomm) and push to `/sdcard/Download/`
2. **Open the WebUI** — manager → module → WebUI button
3. **Tap "Use"** on the driver you want
4. **Force-stop + relaunch** your apps to pick up the new driver
5. **After every reboot** — WebUI → Apply (or the Action button)

### Finding your device's paths

```
adb shell su -c 'getprop ro.hardware.egl; getprop ro.hardware.vulkan'
adb shell su -c 'ls /vendor/lib64/hw/ /vendor/lib64/egl/ | grep -iE "vulkan|egl|adreno|mali|pvr"'
```

The engine auto-detects all Vulkan loader targets. For EGL/GLES, it
auto-maps over every existing `egl/libEGL_*` entry regardless of vendor
tag.

### Driver compatibility notes

| Driver type | System-wide | Notes |
|---|---|---|
| Mesa Turnip | ✅ works | Best compatibility; targets stock kgsl across generations |
| Qualcomm blob (any generation) | ✅ works | Auto-fixes file permissions and SELinux labels; verified with Quest 3 (Adreno 740) and Ray-Ban Display (v863.1) `not*`-only packages on 8 Gen 2 |
| Qualcomm blob (missing dependencies) | ⚠️ needs matching | Some packages ship without all required libs (e.g. `hexlp`); `doctor` reports unresolvable dependencies automatically |

The engine auto-fixes the two issues that previously broke system-wide
Qualcomm blob loading: restrictive file permissions (zip-stored `0600` →
corrected to `0644`) and wrong SELinux labels (`vendor_file` →
`same_process_hal_file`). Both are verified on-device.

## Per-app mode

In the WebUI, switch to **Per-app** and add packages (typed or picked
from installed apps). A small watcher catches app starts via logcat
and mounts the driver into each app process's own mount namespace only.

## Command reference

```bash
# Full diagnostic (mounts, labels, deps, mapped libs, avc, selftest)
adb shell su -c 'sh /data/adb/modules/live_gpu_driver/bin/webui_ctl.sh doctor'

# Status (JSON)
adb shell su -c 'sh /data/adb/modules/live_gpu_driver/bin/webui_ctl.sh status'

# Manual apply (same as Action button)
adb shell su -c 'sh /data/adb/modules/live_gpu_driver/action.sh'

# Restore stock
adb shell su -c 'sh /data/adb/modules/live_gpu_driver/action.sh unmount'
```

## Testing

The test suites run on Linux in isolated user+mount namespaces (no
device needed, host untouched):

```bash
test/run_tests.sh          # global mode (30 assertions)
test/run_perapp_tests.sh   # per-app watcher (21 assertions)
test/run_webui_tests.sh    # WebUI backend + driver zips (60 assertions)
```

All state files are written atomically; concurrent engine invocations
are safe (regression-tested by polling status at 5 Hz during an async
apply).
## Limitations

- **Kernel-side GPU driver (kgsl/msm_drm) can't be swapped live** — the
  userspace blob must be compatible with your kernel's kgsl.
- **Mounts are in-memory** — that's what makes rollback instant. Re-apply
  after each reboot.
- **Running apps keep the old driver** until restarted (mount namespaces
  are copied at fork time).
- **surfaceflinger** keeps the old driver until restart (`RESTART_SF=1`
  in config for immediate restart with a screen flicker).
- **Some Qualcomm packages ship incomplete dependency sets** (e.g. missing
  `hexlp`). The dependency checker reports unresolvable libraries; use a
  package that ships everything, or Turnip.

## License

MIT — see [LICENSE](LICENSE)
