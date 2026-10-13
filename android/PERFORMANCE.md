# RemoteDesk 0.1.1 performance and branding check

Historical 0.1.1 snapshot. Subsequent user feedback and 0.1.3 acceptance are recorded in [ROUTING-CLIPBOARD-VALIDATION.md](ROUTING-CLIPBOARD-VALIDATION.md).

Date: 2026-10-13. Debug ARM64 APK SHA-256: `14CF953FD92C2F21AC40A5569D60A681058FD740C94076E3F91939A04352AD53`.

## Change and verification

- Launcher/connection page renamed RemoteDesk. The generated icon is bundled through Android adaptive-icon resources; original image and generation prompt are documented in ICON.md. Package ID and encrypted-setting identity stay unchanged.
- Decoder prefers a compatible hardware decoder with advertised low-latency support. If low-latency configuration fails, it retries without that option.
- Each pending encoded packet is prepared once. Parameter-set extraction copies only codec configuration NAL units rather than every compressed video slice. Already decoded output backlog is coalesced to its newest frame; encoded reference frames are still submitted in order.
- Numeric-only performance logging measures local settings/configuration time, readiness, first visible image, received frames, decoder queue and output counts. It does not log connection addresses, credentials, input text or screen content.
- `assembleDebug lintDebug` passed (0 errors, 11 warnings); APK 16 KiB alignment check passed. AAPT confirmed version 0.1.1, RemoteDesk label and adaptive-icon reference. Upgrade installation and cold launch succeeded on the attached phone.

## Device evidence

The user confirmed the original Android version connects but both connection and interaction are slow.

Old session used `c2.qti.hevc.decoder`; output delay configuration changed from 4 to 11 and maximum output delay from 8 to 15. These are codec configuration/buffer observations, not measured end-to-end milliseconds.

New session selected `c2.qti.hevc.decoder.low_latency`, and the device confirmed `algo.low-latency.value=1`. It still advertised output delay 11 / maximum 15; do not claim those buffer figures decreased.

One measured new connection, with the existing force-relay preference enabled:

- Encrypted settings save: 39 ms; native configure and connect dispatch each rounded to 0 ms.
- Remote session ready: 3524 ms after dispatch; first visible image: 3999 ms from click.
- Subsequent approximately 5-second windows: 21 received / 21 rendered and 61 received / 60 rendered; sampled encoded queue depth 0 and input stalls 0.

These windows show the decoder keeping up with received frames. They do not establish the upstream bottleneck or a speedup ratio: remote screen activity and network conditions were not controlled, and the old build had no equivalent frame telemetry. No matched MatePad measurement is available. Force-relay preference was not changed.

## Remaining acceptance

User before/after interaction feedback and a comparable same-network/MatePad route test remain pending. Connection setup slowness is not yet established as an Android code defect; source uses the same Rust handshake as HarmonyOS. No server or network configuration was modified. No commit or push was performed.
