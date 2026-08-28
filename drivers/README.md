# Driver packages

Download these separately and push to your device:

| Package | Source | Notes |
|---------|--------|-------|
| Turnip (Mesa) | [Adreno-Tools-Drivers](https://github.com/StevenMXZ/Adreno-Tools-Drivers/releases) | Best compatibility, works on all Adreno 6xx/7xx |
| Qualcomm blobs | [Adreno-Tools-Drivers](https://github.com/StevenMXZ/Adreno-Tools-Drivers/releases) | Generation-matched blobs work best (e.g. Quest 3 = Adreno 740 = S23) |

Driver zips use the Adreno-Tools-Drivers package format (root-level `.so` files + `meta.json`).
Drop them into `/sdcard/Download` on your device and they appear in the module's WebUI.
