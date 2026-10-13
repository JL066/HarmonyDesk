# Android first-device validation — 2026-10-13

Historical 0.1.0 snapshot. Later acceptance and the current version are recorded in [ROUTING-CLIPBOARD-VALIDATION.md](ROUTING-CLIPBOARD-VALIDATION.md).

## Delivered state

Debug ARM64 Android client, package `io.github.jl066.harmonydesk`, version `0.1.0` (1).
APK: `app/build/outputs/apk/debug/app-debug.apk` (ignored build output).
SHA-256: `DFA3BA4FB2DC1397AB7BEF609E351FEE1F7B89F0CAEF2B086E0A987E51E77B2E`.
Built on the existing shared core from fork main, with an additive atomic video packet/metadata ABI. Existing OHOS entry points remain available.

## Verified

- Android ARM64 Rust release build and JNI build succeeded.
- Focused Rust `video_packet_ffi_tests` test passed (1 test, 16 filtered): undersized buffer preserves queued packet and matching metadata.
- `tests/run-tests.ps1`: 111 assertions passed for viewport mapping, mouse masks, control-key mapping and composition state. These are pure Java checks, not physical IME tests.
- Gradle `assembleDebug lintDebug`: success, 0 lint errors and 10 warnings. Warnings include ARM64-only/ChromeOS support, custom-view accessibility/tool constructors, draw allocation and untranslated strings; this is a Chinese test client.
- `zipalign -c -P 16 4`: passed. Native ELF LOAD alignment verified at 16 KiB, bridge dependency uses `libhdcore.so`, not an absolute build path. This does not prove operation on a 16 KiB device.
- Installed over the test package with `adb install -r`: success. Cold launch returned success; UI hierarchy confirmed the app and connection-page title, with no current-process AndroidRuntime/startup error recorded.
- User confirmed the connection page opens before the final update. Final update connection page additionally verified through the device UI hierarchy.
- Static lifecycle review: decoder replacement waits for prior worker teardown; retained Surface/SurfaceTexture are released after completion; input is gated by session readiness and window focus.

## Still requiring device acceptance

No remote connection or authentication success has been established. The user must enter existing server configuration on the phone. Pending: decoded live video, direct and floating mouse coexistence, physical mouse buttons/wheel, hardware keyboard and Chinese/English IME, shortcuts, clipboard in both directions, outer/inner screen transitions, rotation/multi-window, and background/focus release.

This first version does not implement audio/file transfer or automatic restoration after process death. Transport security is inherited from the current core/tunnel; this port does not establish a new end-to-end encryption guarantee.

## Local-data boundary

No device identifier, server credential, signing key or raw device capture is included here. Build products, native output, local configuration, keystores and private device captures are ignored. Android work remains uncommitted; the original HarmonyOS checkout and its local signing configuration were preserved.
