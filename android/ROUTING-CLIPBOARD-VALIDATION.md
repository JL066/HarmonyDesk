# RemoteDesk 0.1.2–0.1.3 routing and clipboard validation

Date: 2026-10-13. Debug ARM64 APK SHA-256: `3590FA7D0D3AD71501E3CB2F446BAFB5158F30FC20F591304F7AC0F18028F9A5`.

## Behavior

- Default automatic routing uses the rendezvous server's `is_local` signal plus a private unicast IPv4 candidate. Eligible LAN connections get a 1.5-second TCP attempt and a 4-second handshake deadline, then fall back to relay on transport/incomplete-handshake failure. Authentication errors remain terminal. External candidates go through relay.
- This is a LAN routing signal, not proof of matching Wi-Fi SSIDs. IPv6 candidates currently fall back to relay in automatic mode. Manually entered IP addresses remain explicit direct connections because they have no peer ID for relay lookup.
- Users can also select always-relay or legacy direct-first routing. The connected screen displays the actual successful route. HarmonyOS retains the legacy policy unless the new API is explicitly called.
- Session generations guard connection state and outgoing queues, preventing a previous connection's worker from consuming a replacement session's input or overwriting its state.
- Clipboard pause/resume preserves synchronization checkpoints. Returning from another application detects a changed local text clipboard; an unchanged local clipboard allows a pending remote update to apply. Simultaneous changes prefer the local copy. Initial activation snapshots the local baseline without transmitting pre-existing text. Failed remote writes remain retryable.
- Clipboard enablement is persisted in encrypted settings. Earlier versions did not persist it, so users upgrading from 0.1.1 must enable it once. Synchronization runs only with an active, focused, interactive session and supports plain text up to 256 KiB; clearing the clipboard is not synchronized.
- Added diagnostics contain route codes, event counts, sizes, state and timing, never clipboard text, remote input, addresses or credentials.

## Verification

- Native `cargo check` passed. Four targeted route/parser/queue/deadline tests passed, including a local socket test enforcing the absolute handshake read deadline. Affected clipboard-permission/outbound, physical-modifier and packet-copy tests also passed. No full regression was run.
- Clipboard Java compilation against Android API 36 and four executable resume-policy assertions passed. These policy assertions do not simulate Android clipboard services or establish end-to-end synchronization.
- Android ARM64 native release build passed; `assembleDebug lintDebug` passed with 0 errors and 11 warnings. APK 16 KiB alignment check passed.
- AAPT and installed-package inspection confirmed RemoteDesk 0.1.2, version code 3. Upgrade installation succeeded, and the application process was alive after cold launch. Existing application identity and stored settings were preserved.
- `git diff --check` passed. Local toolchains, build outputs, captures, native binaries and signing material remain excluded from source delivery.

## Device acceptance pending

The user tested automatic mode on the same Wi-Fi: the actual route was relay, and pointer control did not work. Performance and clipboard acceptance could not be completed. Numeric telemetry for that session showed `route=2 input_allowed=0 mouse_sent=0` throughout, while video continued decoding. Clipboard enablement logged `running=0`.

Live Android window inspection found RemoteDesk's activity in the foreground but `com.android.systemui`'s transparent `NS:DragTargetView` window holding focus. The input gate requires window focus, so this was a concrete blocker before network input transmission. Returning, reopening the app, and the user's lock/unlock test did not remove that window.

After restarting the phone, the user confirmed pointer control works. Window inspection confirmed RemoteDesk holds focus and the drag overlay no longer does. Telemetry changed to `input_allowed=1` and recorded 235 mouse events in one five-second reporting interval. Clipboard polling started with `running=1 allowed=1`. This confirms recovery from the observed focus blocker; it does not prove two-way clipboard delivery or explain why automatic routing still selects relay.

The user subsequently confirmed normal speed and successful computer-to-phone clipboard synchronization. Phone-to-computer synchronization failed: the user reported the app disconnects when switching to another app to copy. Telemetry confirms a pause followed by session reset within about six seconds, and the copied text then becomes the baseline after reconnecting. No local clipboard send was recorded. The six-second disconnect is not explained by the separate 60-second background timer in the old client.

Version 0.1.3 adds a user-started `connectedDevice` foreground service to keep the remote network session active during app switching, and removes the 60-second background disconnect timer. Its ongoing notification offers return/disconnect actions. Explicit disconnect and removing the app task stop the service; it is non-sticky and does not reconnect after process death. Clipboard access and remote input remain suspended in the background. Service setup follows Android's [connected-device service requirements](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device); the declared network permission is a prerequisite, with no network settings changed by the app.

The build also shows a visible reason when input is paused (background, missing window focus, or view-only) and numeric diagnostics for those gates and service/session lifecycle. It does not bypass focus restrictions. `assembleDebug lintDebug` passed (0 errors, 11 warnings), APK alignment and `git diff --check` passed. APK SHA-256: `FBE7DB2F0EC5B87BDA2662EBBCE8CDD74985DEBAD077162F1650A259E19E4568`. Upgrade installation and launch succeeded.

## 0.1.3 device acceptance

- Android service inspection confirmed `SessionService` running as a connected-device foreground service.
- During the user's app-switch test, telemetry recorded pause with an active session, continuing video reception, and resume with the same session still active; no reconnect or session reset occurred. The observed Activity pause-to-resume interval was approximately 11 seconds.
- On return, clipboard reconciliation logged a changed local text snapshot and a successful native enqueue (`result=0`). The user confirmed the computer actually pasted the phone's copied text, establishing end-to-end phone-to-computer delivery.
- Computer-to-phone receipt was also observed in this build, with an applied remote clipboard update; the user previously confirmed that direction's pasted result on 0.1.2. The user confirmed normal pointer control and speed after the earlier system-focus recovery.
- Brief app-switch continuity and both clipboard directions are accepted across these observations. Multi-minute background use, process death, and fresh device-wide regression were not tested. Process death intentionally ends the session.

External-network relay selection and successful LAN direct selection remain unverified on the phone. No server or system network configuration was changed. This report records validation before source commit; no remote push was performed.
