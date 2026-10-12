# Input and clipboard repair — 2026-09-27

## Implemented

- Keep pointer mode, keyboard visibility, toolbar visibility and clipboard synchronization independent. Opening/closing IME no longer exits selection mode or resets pointer state. Toolbar auto-hide does not depend on IME visibility.
- Use explicit keyboard avoidance for the bottom controls and floating pointer; preserve the page's previous system avoidance mode on exit. Keep pointer controls reachable above the keyboard and toolbar. Touching session buttons does not request keyboard focus.
- Copy/Paste/Cut/Select All send only remote chords. Removed the read/send/wait/paste and copy/poll/write macros.
- `ClipboardSync` owns text synchronization for an authenticated, interactive session. Subscribe to local updates, reconcile remote seq/text snapshots, compensate with a 750 ms timer, and reconcile after foreground resume.
- Request READ_PASTEBOARD once per bridge instance, report denial/read failure without repeated prompts, and retain remote reception when local reads fail. Session header reports status and toggles synchronization.
- Exact-content ownership suppression uses bounded pending echoes. New local text wins when both sides changed while the app was suspended. Reject stale async continuations and serialize outstanding operations across epochs.
- Honor the peer's Clipboard permission in Rust, NAPI and the bridge. Missing native permission capability fails closed. Preserve existing field 16/28 text transport.
- Stop the bridge on disconnect, reconnect, page exit and background timeout. Track visibility even when the app backgrounds before login completes. Cancelled connection callbacks cannot start a stale native connection.

## Verification

- `node scripts/test-clipboard-sync.cjs`: PASS. Includes both directions, delayed echoes, foreground conflicts, permission denial/recovery, read failure, remote revocation, stop during read, serialized delayed write across restart, observed revoke/restore, empty-snapshot handling and ownership bounds.
- `node scripts/test-session-lifecycle.cjs`: PASS. Executes actual SessionKeepAlive class with deterministic OS/timer mocks; covers late registration while hidden, foreground cancellation, timeout/resume and explicit stop.
- Rust `clipboard_tests`: 15/15 PASS (worker-run, reviewed). Permission test exercised actual field 16/28 handling and denied outbound.
- `scripts/build-native.ps1`: OHOS arm64 release success; `hd_clipboard_allowed` export verified.
- `scripts/build-hap.bat`: assembleHap success (existing deprecation/dead-code warnings remain).
- Final signed HAP installed successfully with HDC replacement install; no uninstall/data reset.
- `git -c core.whitespace=cr-at-eol diff --check`: PASS. Existing unrelated dirty files preserved; no commit/push.

## Device evidence and limits

On the first repair build, the real remote session displayed the keyboard and floating mouse together. A pointer swipe changed `floatingMouseMove` bounds from [180,1052][313,1185] to [324,1063][457,1196]. While IME remained attached, device logs recorded paired button=0 down=true/false and button=2 down=true/false. This establishes movement and left/right event delivery with keyboard open; drag selection and both clipboard directions across external apps still need end-to-end acceptance.

The final build adds focus/lifecycle and clipboard concurrency/permission safeguards; it was compiled and installed, but the device was locked again at final verification. Do not represent the first-build device evidence as a complete final-build UAT. A cross-app clipboard test was requested from the user; no result was received before this report.

Scope is non-empty plain text. Images/files and clipboard clearing are not synchronized. Empty native text is ambiguous in the existing retrieval API; the bridge observes the generation without erasing local data or sending old local text back. Background OS clipboard access is not assumed: synchronization reconciles on returning to the foreground, and the existing bounded background hold still applies. An OS write already submitted cannot be revoked; epochs prevent subsequent obsolete actions and operation serialization prevents later writes from overtaking it. Content-based echo suppression cannot perfectly distinguish a genuine same-content copy from a delayed echo without a protocol ownership token.

Final artifacts:
- `ohos/entry/libs/arm64-v8a/libhdcore.so` SHA256: `622F1CF6882DA57CAE881B774C6DD5B7A6BEDC978C0C8F2B2F4CA4EEDE7CEBE2`
- `ohos/entry/build/default/outputs/default/entry-default-signed.hap` SHA256: `9F37704486B47DE2E6B84EB686C1CF65E85B77A9E899B5125B06615DE21B10C2`
