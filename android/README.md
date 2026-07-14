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

Install `android/app/build/outputs/apk/release/app-release.apk`. The KOReader
plugin starts `org.zenlabs.zenpm/.ZenPMService` automatically. The release APK
is debug-signed for sideloading; configure a dedicated release keystore before
publishing through an app store.
