# Language settings and English README

2026-09-29. Implemented English and Korean with a System default option in the library's Settings screen.

## Implementation

- `appLanguage` stores `system`, `ko`, or `en` in UserDefaults. System mode resolves the first supported preferred language and falls back to English.
- `L10n` selects bundled resources for UI labels, accessibility text, errors, and formatted progress messages. Both languages contain 456 matching keys. Camera and photo permission explanations also have localized InfoPlist resources.
- The picker updates AppStorage. The root view observes it and updates the SwiftUI locale without recreating the library or editor stores.
- Persistent enum values remain unchanged. Generated mask names are translated for display; album, preset, and other user names retain their contents.
- The README and image reproduction notes are now in English. The editor, HDR, export, and settings screenshots show the actual English app in the iOS 27 Simulator, using the existing synthetic landscape.

## Checks completed

- `./Scripts/verify.sh`: 71 tests passed in 12 suites; iOS Simulator build succeeded.
- Added tests cover supported and unsupported language preferences, bundle lookup, error text, numeric formatting, legacy enum decoding, and preservation of mask/user names.
- Resource audit: the English and Korean key sets match; all 422 literal localization call-site keys exist; format placeholders match; English translations contain no Korean text.
- Signed Release build for a generic iOS device succeeded. Updated the existing iPhone 15 Pro installation and confirmed the app launches.
- Simulator screenshots checked for Korean/System default and explicit English. English editor, HDR, and export labels fit the inspected layouts.
- A debug-only simulator hook (`--settings-smoke-test --settings-language-after-open=ko`, then `en`) changes the same AppStorage binding used by the picker after the settings screen opens. Both directions updated the visible screen without restarting. An ordinary relaunch retained English; the app container's preferences stored `appLanguage = en`.
- Both language resource directories and localized permission strings are present in the built app bundle. `git diff --check` passed.

## Limits

The live-switch smoke check exercises the picker binding programmatically; it is not a physical-device tap test. Installation and launch do not establish full device UI acceptance. System permission dialogs and photo/file pickers follow the iOS app language, so they may differ from an explicit language chosen inside Velyn. System-generated errors and third-party license texts retain their own language.

No rendering algorithms, model weights, import originals, or saved edit identifiers changed. No claim is made about C01–C10, display color acceptance, or Lightroom parity.
