# v1.0.0 release verification

2026-09-29. Version 1.0.0, build 2. Public bundle identifier: `com.h4ruming.velyn`. Requires iOS 27; device family is iPhone; executable architecture is arm64.

## Build and package

- `./Scripts/verify.sh`: 71 tests in 12 suites passed; iOS Simulator build succeeded.
- `./Scripts/package-release.sh 1.0.0`: unsigned Release archive succeeded with Xcode 27 / iPhoneOS 27 SDK. The script overrides private local signing settings and uses the public bundle identifier.
- ZIP integrity check passed. All 47 archive entries are under `Payload/`; no path traversal entries, personal provisioning profiles, app signature directory, or signing key files are included.
- Version, build number, minimum OS, platform, and bundle ID verified from the packaged Info.plist. The executable is a device arm64 Mach-O.
- AOT-GAN, Depth Anything V2 Small, and GMNet compiled models are included, together with the Velyn MIT license, their notices/licenses and English/Korean localizations.
- `Velyn-1.0.0-unsigned.ipa`: 107,910,962 bytes (102.91 MiB).
- SHA-256: `058946ff0e8185548d80eabeb7fdda5b322a3e7c0ed8457712cef9222253dd54`.
- The v1 signed build was installed on an iPhone 15 Pro. Launch returned a device-locked error, so this build has no new physical-device launch result. The preceding development build had launched successfully.
- A separate signed Release build uses the existing local development bundle ID to update the user's installation. The public archive contains neither its provisioning profile nor its private signing configuration.

## Distribution scope

GitHub release assets are the unsigned IPA, checksum file, and installation guide. Users must sign the app for their devices. AltStore Classic and Apple Configurator instructions cite their official documentation; these third-party installation paths have not been tested end to end for Velyn v1. Configurator requires an already signed app.

This version packages the existing implementation. It does not establish C01–C10 acceptance, comprehensive physical-device color/performance validation, or Lightroom parity. No real user photos are included.
