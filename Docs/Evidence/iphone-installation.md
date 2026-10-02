# iPhone installation

2026-09-29, iPhone 15 Pro / iOS 27.0, paired over local network with Developer Mode enabled.

- Signed Release build succeeded, including the GMNet model and new 1024×1024 opaque AppIcon.
- `devicectl device install app` succeeded for `<LOCAL_BUNDLE_IDENTIFIER>`.
- The user confirmed the app works after installation.
- Provisioning expires 2026-10-06 03:01:11 UTC (12:01 JST/KST). Re-sign and reinstall when needed; retain the bundle identifier to preserve app storage.
- The previous placeholder bundle identifier could not be registered, so the project now uses the dedicated identifier above.
- This confirms installation and initial use, not full device performance, photo quality, or C01–C10 acceptance.

Icon source and generation prompt: [app-icon.md](../app-icon.md).

## v1.2 update — 2026-10-02

- Signed Release **1.2.0 (5)** installed over the existing **1.0.0 (2)** using the
  same local bundle ID and signing identity, without uninstalling.
- `devicectl` confirmed successful installation, successful application launch,
  and the new installed version/build.
- No test flags were used. HDR display quality and performance remain unverified
  on the physical phone. See [release verification](v1.2-release-verification.md).
