# Installing ZenPM

Download the required files from the [ZenPM releases page](https://github.com/xZenLabs/zen-pm/releases). Use the files from the same release; beta releases are prereleases and require the **Beta updates** setting in ZenPM for in-app updates.

## Kindle standalone

> **Warning:** Install the standalone package only on older Kindle jailbreaks
> that provide root access, such as WinterBreak and AdBreak. Do not install it
> on newer jailbreaks, KPM-managed devices where `/mnt/us/kmc/kpm` exists, or
> any setup without root access.

This install also requires the latest hotfix and a script launcher such as
KUAL.

### Hotfix update/reinstall
Reinstallation steps:

1. Turn on airplane mode
2. Restore OTAs
3. Download latest hotfix from [wiki](https://kindlemodding.org/jailbreaking/post-jailbreak/setting-up-a-hotfix/), copy to kindle root
4. Update your kindle
5. Run the hotfix
6. Rename OTAs
7. You can use WiFi once more

### Install ZenPM
> Make sure you have the latest hotfix installed (see above)

1. Download `ZenPM-kindle-standalone-<version>.zip`.
2. Extract the ZIP to the Kindle USB-storage root. It creates `documents/ZenPM.sh` and `ZenPM/`.
3. Safely eject the Kindle, then run `ZenPM.sh` from the script launcher.
4. Open ZenPM from the Kindle launcher.

## KOReader on Kindle or 32-bit Kobo

1. Download `ZenPM-koreader-ereader-<version>.zip`.
2. Extract it and copy `zenpm.koplugin/` to KOReader's `plugins/` directory.
3. Restart KOReader and open **ZenPM** from its menu.

The plugin detects the compatible ARM hard-float or soft-float backend. On ARM64 devices, use the Linux package below when `uname -m` reports `aarch64` or `arm64`.

Standalone Kobo packages are not currently published.

## KOReader on Android

Android requires both the ZenPM companion APK and the KOReader plugin.

1. Download `ZenPM-android-<version>.apk` and `ZenPM-koreader-android-<version>.zip`.
2. Sideload and install the APK with Android's package installer. If prompted, allow installs from the app you used to open the APK.
3. Extract the plugin ZIP and copy `zenpm.koplugin/` to KOReader's `plugins/` directory.
4. Restart KOReader, open **ZenPM** from its menu, and grant the requested storage access.

The KOReader plugin starts the installed ZenPM companion automatically. The APK is required because Android cannot run the backend bundled with the plugin directly.

## KOReader on macOS

1. Download `ZenPM-koreader-macos-<version>.zip`.
2. Extract it and copy `zenpm.koplugin/` to KOReader's `plugins/` directory.
3. Restart KOReader and open **ZenPM** from its menu.

## KOReader on Linux

1. Download `ZenPM-koreader-linux-<version>.zip`.
2. Extract it and copy `zenpm.koplugin/` to KOReader's `plugins/` directory.
3. Restart KOReader and open **ZenPM** from its menu.
