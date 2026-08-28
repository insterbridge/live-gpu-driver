# Driver packages

Download these separately and push to your device:

| Package | Source | Notes |
|---------|--------|-------|
| Turnip (Mesa) | [K11MCH1/AdrenoToolsDrivers](https://github.com/K11MCH1/AdrenoToolsDrivers/releases) | Best compatibility, works on all Adreno 6xx/7xx |
| Qualcomm blobs | [K11MCH1/AdrenoToolsDrivers](https://github.com/K11MCH1/AdrenoToolsDrivers/releases) or [StevenMXZ/Adreno-Tools-Drivers](https://github.com/StevenMXZ/Adreno-Tools-Drivers/releases) | Generation-matched blobs work best (e.g. Quest 3 = Adreno 740 = S23) |

Driver zips use the AdrenoToolsDrivers package format (root-level `.so` files + `meta.json`).
Drop them into `/sdcard/Download` on your device and they appear in the module's WebUI.
