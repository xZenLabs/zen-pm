# ZenPM Android companion

This APK hosts the ZenPM Go backend as `libzenpm.so`, so Android executes code
installed with the APK rather than a binary copied to noexec shared storage.

On macOS, install JDK 17, Gradle, and the Android command-line tools (or install
them with Android Studio). Then install the SDK components and build:

```sh
brew install gradle openjdk@17
brew install --cask android-commandlinetools
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export ANDROID_HOME="$(brew --prefix)/share/android-commandlinetools"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
sdkmanager --licenses
sdkmanager "platforms;android-34" "build-tools;34.0.0" "ndk;23.2.8568313"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/23.2.8568313"
gradle -p android assembleRelease
```

NDK 23 supplies an Intel macOS compiler on some Apple Silicon installations;
install Rosetta if macOS cannot run it: `softwareupdate --install-rosetta --agree-to-license`.

Install `android/app/build/outputs/apk/release/app-release.apk`. On Android 11
and newer, the first ZenPM launch opens Android settings for **All files
access**; grant it, then open ZenPM again. Android 4.4 uses the normal storage
permission declared by the APK. The KOReader plugin starts the companion
automatically.

Published APKs are signed in CI with the persistent release keystore held in
GitHub Actions secrets. The companion’s **Update** action checks the matching
GitHub release, verifies the APK SHA-256 digest, and opens Android’s package
installer. Android always requires the user to approve that install. Android
8+ may first require allowing installs from ZenPM Companion; Android 4.4 uses
the global **Unknown sources** setting.

An APK installed from an earlier debug-signed build cannot be upgraded to the
first release-signed build. Uninstall that old companion once, then install the
release-signed APK; later releases update normally.
