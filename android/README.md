# RemoteDesk for Android

RemoteDesk is the Android control client sharing the existing RustDesk-compatible `hdcore` with HarmonyOS. The tested development version is 0.1.3. The user confirmed working pointer control, normal speed, brief app-switch connection continuity and bidirectional text clipboard synchronization. Remaining device coverage and route limitations are recorded in [the current validation report](ROUTING-CLIPBOARD-VALIDATION.md).

## Scope

- Existing ID server / relay server / key / remote password, plus direct addresses.
- H.264/H.265 MediaCodec decoding to a TextureView, with FIT/FILL/original geometry.
- Direct touch, floating pointer panel, physical mouse buttons/wheel, hardware keys and Android IME.
- Resizable activity for fold/unfold, rotation and multi-window changes; transport stays independent of surface replacement. Process death still ends the session.
- Opt-in foreground plain-text clipboard synchronization; no files/images/audio transfer.
- An ongoing connected-device service keeps the user-started session active while switching apps. Returning to the focused client reconciles clipboard changes. Explicit disconnect or removing the task stops the service; process death ends the session.
- Android Keystore encrypted local connection settings. Password persistence is opt-in. No server credentials bundled in source or APK.

## Build

Prerequisites: JDK 17+, Gradle 8.13, Android SDK platform 36, Build Tools 35.0.0, NDK 27.2.12479018 and CMake 3.22.1. Accept the SDK license in SDK Manager. Set `ANDROID_HOME`; no machine paths belong in tracked files. Install Rust target `aarch64-linux-android` in your selected Rust toolchain.

On Windows, run `./android/build-native.ps1`, then from `android/` run `./gradlew.bat assembleDebug`. Rust and JNI use 16 KiB ELF page alignment. The initial package is ARM64 only. The debug signing key is local and is not a distribution/release key.

Install the generated debug APK with `adb install -r app/build/outputs/apk/debug/app-debug.apk`. Enter your existing server configuration on the phone. Do not put passwords, server keys, device identifiers or raw device logs into Git.

## Device acceptance

Samsung foldable acceptance must cover outer screen, unfolded inner screen, rotation, multi-window, connection continuity during resize, English/Chinese composition, Ctrl/Shift chords, pointer buttons/wheel, direct touch with panel visible, background focus release and clipboard in both directions. Compilation and simulated geometry tests do not prove those outcomes. Android background clipboard limits are respected by suspending synchronization outside the focused session.

Native protocol limitations are inherited from `hdcore`: server key handling is not proof of end-to-end encryption; this port does not add a new transport-security implementation. Use the same trusted tunnel deployment as the existing client.

Current build/device evidence and pending acceptance: [ROUTING-CLIPBOARD-VALIDATION.md](ROUTING-CLIPBOARD-VALIDATION.md). The [first-device report](VALIDATION.md) preserves the historical 0.1.0 checks.

Launcher artwork: [ICON.md](ICON.md). The Android package ID remains unchanged so updates retain encrypted settings.

Performance/branding update: [PERFORMANCE.md](PERFORMANCE.md).
