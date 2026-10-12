# Hardware input and touch coexistence — 2026-10-04

## Result and scope

Implemented physical keyboard, mouse buttons/movement and vertical wheel forwarding. Direct touch remains enabled when the optional floating mouse panel is visible. The panel toggle now shows/hides the helper rather than switching the whole remote canvas to a trackpad. Existing unrelated workspace changes were preserved. No device installation, commit, push, or signing configuration change was performed.

Changed production files:

- `ohos/entry/src/main/ets/pages/Session.ets`: focused remote input surface, mouse/axis events, synthetic mouse-touch filtering, shared cursor, direct-touch cancellation, focus/window/background/disconnect release; hidden IME attachment independent of the soft keyboard panel.
- `ohos/entry/src/main/ets/services/HardwareKeyboard.ets`: OHOS-to-RustDesk key mapping, Unicode/layout fallback, navigation/function/keypad keys, modifier snapshots, repeat and key-up ownership, release of modifiers observed before focus.
- `ohos/entry/src/main/ets/services/HardwarePointer.ets`: balanced mouse buttons and fractional vertical wheel accumulation.
- `ohos/entry/src/main/ets/native/HarmonyDeskNative.ets`, `ohos/entry/src/main/ets/types/libharmonydesk.so.d.ts`, `ohos/entry/src/main/cpp/harmonydesk_napi.cpp`: physical-key NAPI bridge.
- `ohos/entry/ohos/hdcore/src/lib.rs`: physical key packets with modifier metadata; mouse packets include held Ctrl/Shift/Alt/Meta; text/chord helpers suspend and restore physical modifiers, IME navigation preserves them, session resets clear modifier state.

Keyboard routing: ordinary text and composition pass to the attached system IME without requiring the soft keyboard to be visible. Shortcuts are handled before IME; events not consumed by IME have a post-IME fallback. Shift is mirrored to the remote peer while remaining available to local IME. Input is gated by interactive session/focus state, and late IME callbacks are ignored after the component deactivates.

The floating panel reserves its rectangular control area for local controls; the remote canvas outside it remains directly touchable. Physical wheel events over the panel scroll at the current remote cursor as well. Wheel sensitivity currently uses one integral remote step per 15 vp, retaining fractional motion; tuning requires device feedback. Horizontal scrolling and mouse back/forward buttons are outside this change.

## Verification

All targeted checks below passed; no full regression was run.

- `node scripts/test-hardware-keyboard.cjs`: actual service code with SDK key enums; letters/layout text, punctuation, Caps/NumLock, keypad, navigation/F-keys, shortcuts/modifiers, repeats, release, and focus gained with a modifier already held.
- `node scripts/test-session-input.cjs`: actual Session handlers and geometry; mouse movement/clicks, wheel and panel wheel, FIT black bars, touch/panel coexistence, duplicate mouse-touch filtering, cancel with empty contacts, two-finger cancellation, source handoff, read-only/focus gates, IME routing and matching key-up.
- `node scripts/test-ime-input.cjs`: actual TypeBar lifecycle with an IME mock; hidden attachment, committed Chinese/text and control callbacks, panel show/hide without detaching, stale callbacks, serialized detach/reattach.
- `node scripts/test-session-lifecycle.cjs`: existing affected background/resume checks passed and evidence reused after unchanged lifecycle service.
- `node scripts/test-clipboard-sync.cjs`: existing adjacent clipboard checks passed; clipboard service was not changed.
- In `ohos/entry/ohos/hdcore`: `cargo test physical_modifiers_are_carried_by_keys_and_mouse_and_restored_after_macros`: 1 passed, 15 filtered out. Inspects encoded key/mouse packets, Shift+IME navigation, and modifier suspension/restoration around text/chord helpers.
- `scripts/build-native.ps1`: final AArch64 release build succeeded.
- `scripts/build-hap.bat`: final C++/ArkTS compilation, `PackageHap`, and `PackingCheck` succeeded. **The command as a whole failed at `SignHap`**, because the existing signing certificate expired on 2026-09-30 at 20:01:02 China time. No credentials/certificates were renewed or changed.
- `git -c core.whitespace=cr-at-eol diff --check` on affected tracked source files passed. Compiler warnings remain.
- Inspected the unsigned HAP archive: includes AArch64 native libraries and the `hd_send_hardware_key` export plus `sendHardwareKey` NAPI binding.

## Artifact

- `ohos/entry/build/default/outputs/default/entry-default-unsigned.hap`
- Size: 3,888,159 bytes.
- SHA256: `96834d605464b2be19c2b59f0bde8e1c08530c8ffd79a98d2029db48b76c82f0`.
- Packaged `libhdcore.so` SHA256: `4b3badbcf0185800add27ad4e054ea0d2ecf318b977a4a17a817dc14fb1f74e3`.
- This is an **unsigned** build artifact, not an install-ready signed release.

## Runtime acceptance not performed

The MatePad is unavailable. Local DevEco has an emulator executable and a MatePad Pro 13 x86_64 profile, but the referenced `<SDK>/system-image/HarmonyOS-6.1.1/tablet_x86/` image is missing. HDC reported no targets. The current HAP contains ARM64 libraries only; an x86_64 emulator also needs a compatible native build. No emulator image download, agreement acceptance, or configuration change was performed.

The tests simulate OS/native boundaries; they do not establish real ArkUI hit testing, Bluetooth event delivery, IME candidate behavior, wheel feel, remote OS shortcut behavior, or seamless window/mode switching. Once a valid signing certificate and device are available, verify physical typing (Chinese/English), Ctrl/Shift combinations and system-reserved shortcuts, left/right/middle clicks and drag selection, wheel direction/speed, panel-visible direct touch, and release/recovery after focus/background/disconnect changes. These runtime outcomes remain unverified.

## Follow-up: real-device keyboard acceptance — 2026-10-12

The user reported that physical mouse input worked, but physical keyboard typing produced no remote text. During reproduction, the application was running and IME attachment succeeded, while the device layout reported `remoteInputSurface` (a Stack) as unfocused. The code unconditionally marked it focused after requesting focus, so that state was not evidence of actual OS focus.

Replaced the container key target with an explicit focusable Text leaf that does not intercept pointer hit testing. Moved key/focus callbacks to that leaf and removed the optimistic focused-state assignment. Focus state now follows actual onFocus/onBlur callbacks; focus diagnostics contain no typed text or device identifiers.

Validation: hardware-keyboard, session-input and IME-input targeted tests passed; signed HAP build and replacement installation succeeded. The user subsequently reported that this test had no remaining problem and authorized a commit. This records user-confirmed keyboard recovery alongside the earlier mouse confirmation; it does not establish exhaustive shortcut, composition, clipboard or desktop-mode coverage.

Device identifiers, remote host details, local signing credentials, raw layout captures and local SDK paths are intentionally omitted. The earlier unsigned-build section is historical evidence, not the final installation status.

### Commit preparation

Targeted JavaScript tests resolve the SDK from `OHOS_BASE_SDK_HOME`, `DEVECO_SDK_HOME`, or `DEVECO_DIR`, with the standard Windows installation as a fallback. `HARMONY_TYPESCRIPT` and `HARMONY_KEYCODE_DTS` remain supported overrides. All five input/IME/clipboard/lifecycle scripts passed after removing machine-specific paths. No application behavior changed during commit preparation.

The commit includes the existing clipboard, lifecycle and session UI work with the user's explicit approval. Local signing/build configuration and machine-specific build script changes remain outside the commit. Build and device acceptance above were performed using those local environment settings.
