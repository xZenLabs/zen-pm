# ZenPM Android companion

This APK hosts the ZenPM Go backend as `libzenpm.so`, so Android executes code
installed with the APK rather than a binary copied to noexec shared storage.
It includes both 32-bit ARM (`armeabi-v7a`) and 64-bit ARM (`arm64-v8a`) native
libraries.

On macOS, install JDK 17, Gradle 8.6, and the Android command-line tools (or
install them with Android Studio). Then install the SDK components and build:

```sh
brew install openjdk@17
brew install --cask android-commandlinetools
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
sdkmanager --licenses
sdkmanager "platforms;android-34" "build-tools;34.0.0" "ndk;25.2.9519653"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/25.2.9519653"
./android/build.sh
```

The build script requires Gradle 8.6 because the project uses Android Gradle
Plugin 8.4.2. Set `GRADLE_BIN` to a Gradle 8.6 executable when it is not on
your `PATH`.

NDK 25 supplies a macOS compiler compatible with Apple Silicon.

Install `android/app/build/outputs/apk/release/app-release.apk`. On Android 11
and newer, launching ZenPM or starting it from KOReader opens Android settings
for **All files access** until it is granted; grant it for KOReader package
management. Android 4.4 uses the normal storage permission declared by the APK.
The KOReader plugin starts the companion automatically. The companion stops
when KOReader closes ZenPM or after five minutes without requests, so it does
not keep a foreground service running while idle.

On BOOX devices, the companion appears in Apps as **ZenPM Backend**. Ensure
**App Freeze** is turned off for it under **Apps > App Management**, because a
frozen companion cannot receive KOReader's start request.

Published APKs are signed in CI with the persistent release keystore held in
GitHub Actions secrets. The companion’s **Update** action checks the matching
GitHub release, verifies the APK SHA-256 digest, and opens Android’s package
installer. Android always requires the user to approve that install. Android
8+ may first require allowing installs from ZenPM Companion; Android 4.4 uses
the global **Unknown sources** setting.

An APK installed from an earlier debug-signed build cannot be upgraded to the
first release-signed build. Uninstall that old companion once, then install the
release-signed APK; later releases update normally.
