# RemoteDesk icon

Generated with the built-in image_gen tool on 2026-10-13. The original bitmap is stored at `app/src/main/res/drawable-nodpi/remotedesk_icon.png`; adaptive launcher resources reference this workspace asset. No external image URL or machine-specific source path is required to build.

## Adaptive mask correction (0.1.4)

The original fixed 6dp foreground inset allowed the artwork to extend beyond the adaptive icon safe zone at some launcher sizes. The foreground now uses an 18% inset on each side, scaling with its drawable bounds. The original generated bitmap is unchanged. Android reserves a central 66dp safe diameter within the 108dp layer; see the [official adaptive icon guidance](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive).

A pixel-color geometry check estimates the bright artwork's maximum center radius at 27.85dp after scaling, inside the 33dp safe radius. This is a source geometry check, not a screenshot of the Samsung launcher. `assembleDebug lintDebug` passed (0 errors, 11 warnings); the 0.1.4 update was installed. The user then confirmed that the icon displays completely on the phone, accepting the launcher appearance fix.

Prompt:

Use case: logo-brand. Asset type: production Android launcher icon for a remote desktop app named RemoteDesk, used on a Samsung foldable phone. Create one polished square icon asset, no mockup. Subject: an original bold abstract mark combining two overlapping screen planes with a clear pointer-arrow-shaped negative space, communicating fast remote connection. Modern premium technology aesthetic, restrained dimensional highlights, exceptionally clear silhouette readable at tiny app-icon size. Large central symbol within the central 60 percent safe region, balanced generous margins suitable for circle and squircle Android adaptive masks. Fully opaque full-bleed square background, seamless to all four edges; no outer rounded-square border or baked drop shadow. Tasteful cool luminous color accents against a deep dark background. No text, no letters, no Android robot, no existing brand logos, no fine-detail clutter, no watermark. Deliver a single beautiful finished 1024x1024 square app icon.
