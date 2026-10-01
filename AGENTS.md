# Velyn implementation rules

The original Korean product specification is a local-only PDF excluded from the public repository. Public milestones and acceptance gates are recorded in Docs/acceptance.md and Docs/professional-roadmap.md. Follow them. Implemented foundation: M0-01 SDK investigation and M1-01 original file import. The user subsequently requested a major Lightroom-style UI redesign: a photo library, browsing thumbnails, full-screen viewing, and separate metadata panels are now in scope. A subsequent user request expanded scope to professional editing: global light/color, curves, HSL, detail, geometry, presets, history, full-resolution SDR export are implemented. Respect the remaining device/color acceptance gates in Docs/editor-features.md; do not label the full PoC or Lightroom feature parity complete.

- Never modify, re-encode, or replace an imported original with a thumbnail. Copy bytes, verify SHA-256, then atomically commit the package.
- No app server, photo uploads, login, analytics, or advertising SDKs. File-provider system downloads are distinct from app traffic.
- Domain models use Foundation values and Codable/Sendable only. No SwiftUI, PhotoKit, Vision, Core Image, or Metal objects in persistent DTOs.
- Disk copies, hashing, decoding, rendering, and inference must not run on MainActor. Services own mutable framework objects.
- Propagate cancellation, remove incomplete staging files, preserve committed work, and ignore stale UI results.
- Internal project paths must stay inside their package. Do not accept arbitrary relative paths from manifests.
- Internal originals are excluded from system backup. Retain the user-facing data-loss notice.
- Use installed SDK headers/interfaces and compile probes to verify API spelling and availability. SDK 27 imports kCIContextMemoryLimit as CIContextOption.memoryTarget.
- Do not call model-download APIs automatically on launch or import.
- Run `./Scripts/verify.sh` after engine changes. For device compilation, use the command in Docs/api-availability.md.
- Record evidence, sample type, and actual execution environment. Simulator or Mac timing is never an A17 Pro benchmark. Synthetic DNG is never a ProRAW validation result.
- Do not add real user photos to the repository. Synthetic fixtures must have a generator and provenance.
- Do not declare C01–C10 or a launch milestone passed without the required device evidence.

## Current expanded scope (2026-09-28)

The user requires photo processing to remain entirely on-device and rejects server-dependent features. Local masks, curves, grading, clone/heal, bundled depth/removal/gain-map models, SDR-to-HDR prediction, HDR/TIFF export, library organization, batch processing and camera paths are implemented. See Docs/professional-roadmap.md for exact scope and remaining work. Model preparation must remain explicit; no automatic downloads on launch/import and no photo uploads. Current automated evidence: 71 tests, synthetic simulator workflow, signed device build and update installation (latest installation and launch succeeded). These are not physical-device or Lightroom-parity acceptance.

## Focused editor and export UI (2026-09-29)

User-facing save choices must stay at four or fewer and always include JPEG, PNG, HEIC. Current fourth choice is the unchanged original. TIFF/AVIF codecs remain engine-only. Keep one active adjustment slider with a large photo preview. Preview scheduling uses one latest pending request, at most 30 interactive render starts per second, 768px interactive and 1536px settled proxies; never use proxies for full-resolution export. See Docs/Evidence/focused-editor-verification.md for simulator-only evidence.

P3 gamut expansion uses a shared analytical 33³ cube, not an ML model or recovery of known original colors. Keep P3 preview/detail output, alpha, zero-strength bypass and HDR headroom. Warm-hue protection is a heuristic, not semantic skin detection. See Docs/Evidence/gamut-expansion-verification.md.

Object removal uses a transient paint/erase selection, zoomable canvas, and explicit Run. Keep bundled AOT-GAN inference off MainActor; do not infer while painting. Preserve drafts on error/cancel, clear only on success, and delete only uncommitted patch resources when discarding stale results. Legacy clone/heal recipes remain readable; new UI offers object removal only. See Docs/Evidence/removal-ui-verification.md.

RAW developer controls are sparse per-photo recipe overrides; hide controls unsupported by the file/decoder, preserve absent-key rendering, and include every override in the decoded proxy cache key. Color presets/batch paste preserve target RAW settings. PNG supports 8/16-bit output while the save-format list remains JPEG/PNG/HEIC/original. A real user DNG was checked on macOS, not as a physical-device acceptance result.

Gain-map tensors use Rf, which expands to (R,0,0,1). Always broadcast R to RGB before gain curves/multiplication and normalize new stored maps. Existing R-only PNG maps must remain compatible without regeneration. Regression tests must include actual Rf/model output and neutral RGB through preview and HDR JPEG/HEIC export, not only synthetic RGB gray maps or HDR peak checks. See Docs/Evidence/hdr-red-cast-verification.md.

## Localization (2026-09-29)

App language is System / Korean / English, stored under `appLanguage`. Use `L10n.tr` or `L10n.format` for app text and add matching keys to both `Engine/Resources/{en,ko}.lproj/Localizable.strings`. Keep persisted enum raw values and user-entered names unchanged; localize labels at display time. Native permission and picker language follows iOS settings. See Docs/Evidence/localization-verification.md.

## Library actions and HDR reference audit (2026-10-01)

Library selection must reconcile with visible IDs; deletion captures IDs before confirmation, remains reversible, and offers Undo/Trash restoration. Keep failed-operation selections. Import source changes must not silently discard selected photos.

Gain-map fingerprints track the recipe used for prediction, excluding geometry, vignette, and gain controls. Old maps remain readable; regenerate explicitly and preserve user gain settings. A native HDR/embedded SDR pair showed reconstruction error despite close PyTorch/Core ML output agreement. Do not treat neutral RGB/valid gain-map export as native HDR fidelity. See Docs/Evidence/library-hdr-audit.md (72 engine tests; synthetic simulator workflows; one real photo on macOS; no new physical-device acceptance).
