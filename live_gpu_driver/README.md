# Live GPU Driver Mount — module internals

Runtime GPU driver replacement via bind mounts. Works with
late-loaded KernelSU (no OverlayFS/Magic Mount required), APatch,
Magisk, or any root shell.

See the repo's top-level README for usage.

## Architecture

```
webroot/index.html  →  ksu.exec bridge  →  bin/webui_ctl.sh
                                              │
                    ┌─────────────────────────┼──────────────────┐
                    ▼                         ▼                  ▼
            bin/gpu_mount.sh         bin/perapp.sh       bin/autostart.sh
            (mount engine)           (per-app watcher)   (mode selector)
                    │
                    ▼
            mount -o bind  (via nsenter into init/zygote/SF namespaces)
```

## Engine (`bin/gpu_mount.sh`)

Subcommands: `mount | unmount | status | plan | ns <pid> | selftest`

**Mount flow:**
1. Build payload list from `system/` mirror
2. Classify: per-file binds (target exists) vs staged merged dirs
   (new filenames require a dir-level mount)
3. Relabel payload files to the stock vendor label
   (`same_process_hal_file`); verify chcon stuck
4. Stage merged dirs (copy original vendor dir + overlay payload;
   chmod a+rX + chcon on every file)
5. nsenter into init/zygote64/zygote/surfaceflinger namespaces
6. Apply bind mounts — strict verification: every namespace must
   confirm each mount with `MOUNT_OK`
7. Post-mount label fix (chcon through the mounted path, which is
   more reliable than the /data staging path on some filesystems)

**Unmount flow:**
1. Replay the saved plan in reverse across all namespaces
2. Lazy umount (`umount -l`) — plain umount fails EBUSY when
   processes hold the file mapped
3. Self-healing sweep: remove ANY mount carrying the module marker,
   even ones the plan doesn't know about
4. Delete staging

**Concurrency:** all state files written atomically (unique tmp name +
`mv`). Multiple engine invocations can run simultaneously.

**Stale mount handling:** apply verifies each mount serves the correct
inode (via `stat` through the target namespace); stale mounts are
lazy-detached and replaced.

## Driver-zip loader (`bin/webui_ctl.sh driver-select`)

Input: any AdrenoToolsDrivers-format zip (root-level `.so` files +
`meta.json`).

1. Extract to `.drivercache/`
2. Find the Vulkan library (`meta.json`'s `libraryName`, or first
   `vulkan.*.so`)
3. Map it over **every** loader target:
   - ICD manifest `library_path` entries (`/vendor/etc/vulkan/icd.d/*.json`)
   - Legacy hw module (`hw/vulkan.$(ro.hardware.vulkan).so`)
   - Every existing `vulkan.*.so` in vendor/odm lib dirs
4. Map support libs (`libgsl`, `libadreno_utils`, `libllvm-*`, `not*`)
   to `/vendor/lib64/` — new filenames only when referenced (DT_NEEDED
   grep) to avoid unnecessary dir staging
5. Map EGL/GLES set over every existing `egl/libEGL_*` entry
   (vendor-tag agnostic)
6. Launch background job: unmount old → dependency report → apply

Everything heavy is async; the WebUI polls status until active.

## Per-app watcher (`bin/perapp.sh`)

- Watches logcat for system_server's `Start proc <pid>:<pkg>/...` lines
- When a target package starts: waits for its private mount namespace,
  then mounts the driver into that pid only
- **Leak guard**: engine refuses to mount into any pid still sharing
  an init/zygote namespace (a race can't go global)
- Verification by content comparison through `/proc/<pid>/root/<path>`
  (mountinfo sources are fs-relative; grep on paths is unreliable)

## SELinux

Normal operation needs no policy changes: payload files are relabeled
to `same_process_hal_file` — the label app domains already load.

`sepolicy.rule` ships a fallback for devices where `chcon` fails in
the root context: it allows app domains to load driver files that kept
`/data` labels. Scoped to file access on those label classes only.
Loaded at boot / late-load; **reboot once after install** for it to
take effect.

## Doctor (`webui_ctl.sh doctor`)

Sections:
1. Module version, selected driver, payload list
2. Device vulkan discovery (props, ICD manifests, all loader targets)
3. Mounts by namespace (init, zygote, SF)
4. Does the payload reach processes (per-pid content comparison)
5. Labels + modes (payload vs stock; must be world-readable + HAL label)
6. Stale staged mounts (mounted but not in current plan)
7. Dependency check (DT_NEEDED approximation; unresolvable libs)
8. Staged dir sanity (entry count vs original)
9. Recent SELinux denials (avc)
10. Selftest (nsenter + bind mount primitives)
11. engine.log tail

## Boot hooks

`service.sh`, `late-load.sh`, `boot-completed.sh` all call
`bin/autostart.sh`, which applies whatever mode `config` selects.
Everything is idempotent. Modern KernelSU runs these even in
late-load mode; if your root doesn't run scripts, use the WebUI or
Action button.
