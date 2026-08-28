This folder is the driver drop-zone. Put your custom GPU driver files
here, MIRRORING the absolute path they must end up at on the device.

Examples:

  payload/vendor/lib64/hw/vulkan.adreno.so
  payload/vendor/lib64/egl/libEGL_adreno.so
  payload/vendor/lib64/egl/libGLESv2_adreno.so
  payload/vendor/lib64/egl/libGLESv1_CM_adreno.so
  payload/vendor/lib64/libCB.so
  payload/vendor/lib64/libadreno_utils.so
  payload/vendor/lib64/libgsl.so
  payload/vendor/lib64/libllvm-qgl.so
  (32-bit versions go to payload/vendor/lib/... if your device has them)

The installer copies payload/<path> into the module's system/<path>
mirror, and the mount engine bind-mounts it over the real /<path>.

Find the exact names YOUR device expects:

  adb shell su -c 'getprop ro.hardware.egl; getprop ro.hardware.vulkan'
  adb shell su -c 'ls /vendor/lib64/egl /vendor/lib64/hw | grep -iE "egl|vulkan|adreno|mali|pvr"'

Rules of thumb:
* REPLACING an existing file  -> use its exact original name/path.
* ADDING a file that does not exist on the vendor partition yet is
  also supported (the engine stages a merged copy of the parent dir),
  but prefer original names — Android's loaders only look up fixed
  names like vulkan.<ro.hardware.vulkan>.so or
  libEGL_<ro.hardware.egl>.so.
* Qualcomm/Adreno: Mesa Turnip builds ship a single vulkan driver —
  rename it to vulkan.adreno.so (or vulkan.$(getprop ro.hardware.vulkan).so).
* Vendor blobs must match your kernel's kgsl/msm_drm driver version;
  a much newer blob on an old kernel driver will crash apps.

GALAXY S23 (all models, all regions — Snapdragon 8 Gen 2, Adreno 740,
64-bit only):
  Verify:  adb shell su -c 'ls -l /vendor/lib64/hw/ /vendor/lib64/egl/ /odm/lib64/hw/ 2>/dev/null | grep -iE "adreno|vulkan|egl"'
  Typical: /vendor/lib64/hw/vulkan.adreno.so
           /vendor/lib64/egl/libEGL_adreno.so (leave EGL/GLES stock)
  Turnip:  rename the Turnip build to vulkan.adreno.so, drop it at
           payload/vendor/lib64/hw/vulkan.adreno.so
           (Vulkan apps/emulators get the new driver; GLES games keep
           the stock Qualcomm GL stack — that is the safe default.)
