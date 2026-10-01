# HDR quality changes in v1.1

2026-10-01. This continues the [v1.0.1 investigation](library-hdr-audit.md). The model weights are unchanged; this release changes how the predicted gain is applied.

## Changes

**Scene-dependent tone protection.** The old curve gated gain by linear luminance between 0.18 and 0.8. That preserved dark tones but suppressed much of the useful gain in compressed, low-contrast SDR images. The new policy measures the 10th–90th percentile luminance span at prediction time. Below four stops it uses a protection curve in perceptual sRGB brightness; above six stops it retains the old curve, with a smooth transition between. Flat fields and insufficient samples retain the old policy. Transparent pixels do not establish the scene's black point. The mix is stored with the map, so preview size and export resolution cannot change the tone policy.

This is a bounded heuristic. It does not know the photographed scene's original exposure, reconstruct clipped texture, or infer a camera's artistic HDR intent.

**Edge-aware map enlargement.** New maps use Core Image's `CIEdgePreserveUpsampleFilter`, guided by the edited SDR image, instead of only stretching the small gain map. The installed SDK's `CIEdgePreserveUpsample` protocol and actual filter attributes confirm `inputSmallImage`, `inputSpatialSigma` (3), and `inputLumaSigma` (0.15). The result is clamped, and R is broadcast to RGB before multiplication, keeping neutral colors and alpha.

**Compatibility.** Optional `protectionBlend` and `edgeAwareUpsampling` fields are only set for newly predicted maps. Absent fields keep existing documents' rendering. Regenerate explicitly to apply v1.1; strength, maximum gain, and the protection toggle are retained. The UI explains this for older maps. No model download or inference is added to launch/import.

The histogram, inference, map storage, and rendering remain inside the editing service actor. Tone-state fingerprint hashing also stays off MainActor. Interactive previews retain the 30-starts/second cap and 768/1536px proxies; exports use original resolution.

## Paired image audit

[Full numeric results and source URLs](hdr-v11-paired-results.json). Eight local native-HDR/embedded-SDR pairs were measured on macOS 27 using the production pipeline. No photo was uploaded. Public samples were downloaded only for local evaluation; neither their pixels nor the user's photo were added to this repository.

Five samples informed development. After choosing the tone policy, three files from the gainmap-js test corpus were evaluated separately. These three are not a large independent benchmark. The experiment did not fit per-image constants to the HDR reference.

Luminance is sampled at a 256-pixel long edge in linear sRGB. Error is absolute log2 luminance difference, excluding SDR/reference luminance at or below 0.01. The table is a content measurement, not display nits or a perceptual score.

| Sample | Group | Previous MAE | v1.1 MAE |
| --- | --- | ---: | ---: |
| User's sunset JPEG | Development | 0.140 EV | 0.088 EV |
| libultrahdr Apple sample | Development | 0.049 EV | 0.049 EV |
| DJI 0226 | Development | 0.571 EV | 0.463 EV |
| DJI 0616 | Development | 0.576 EV | 0.481 EV |
| DJI 0927 | Development | 0.655 EV | 0.575 EV |
| gainmap-js 01 | Held out | 0.185 EV | 0.145 EV |
| gainmap-js 02 | Held out | 1.043 EV | 0.919 EV |
| gainmap-js 03 | Held out | 0.307 EV | 0.255 EV |
| **Equal-image mean** | | **0.441 EV** | **0.372 EV** |

The aggregate reduction is **15.6%**. The sunset's average luminance changes from 0.899× native HDR to 1.062×; this improves absolute luminance error but slightly overshoots the reference. Sample 02 still has substantial error. The results do not establish exact native-HDR recovery or universal improvement.

There is a tradeoff: correlation with the native gain pattern falls on six of eight images, is unchanged on one, and improves on one. For example, DJI 0226 changes from 0.860 to 0.628. Broader midtone gain improves absolute luminance error but can match the reference's spatial distribution of gain less closely. The 95th-percentile luminance error improves on seven samples and is unchanged on the Apple sample. These metrics support reduced brightness error, not a claim that every aspect of HDR fidelity improved.

Additional PyTorch experiments doubled local input resolution and removed square padding. They did not materially resolve the reconstruction difference, so the shipped model retains its bounded 512px input. The source is [GMNet](https://github.com/qtlark/GMNet); its dataset and gamma convention differ from a general iPhone camera pipeline. The earlier photo-tensor PyTorch/Core ML comparison measured only 0.000983 EV mean conversion error.

## Automated and simulator evidence

- `./Scripts/verify.sh`: **75 tests / 12 suites**, iOS Simulator build.
- New tests cover scene contrast, flat fields, invalid metadata, persisted options, alpha/color ratios, gain cap, zero strength, and leakage across a sharp boundary using actual Rf raster samples.
- Existing tests retain old R-only PNG compatibility and actual-model preview/HDR JPEG/HEIC neutral RGB checks.
- [Simulator smoke results](hdr-v11-simulator.json): actual bundled-model inference on a 1200×900 synthetic chart, HDR JPEG and HEIC round trips, equal neutral RGB channels, stale-map detection, setting preservation, and undo/redo passed. Peak linear RGB was 2.931×. This is iOS 27 Simulator evidence, not a physical HDR display test.
- Signed iPhone Release compilation and unsigned public IPA packaging succeeded for version 1.1.0, build 4. The physical iPhone was unavailable, so no new installation or display check is claimed.
- The README uses a new, explicitly synthetic source and fresh engine exports. Screenshots are from the actual v1.1 Simulator app, with unmodified UI and generated fixtures in a separate store.
- Reproduce the paired audit with `Scripts/audit-hdr-reference.swift` as documented in the earlier audit. It now reports `legacy`, `app-default`, and `model-full` from the same predicted map.

Physical iPhone display accuracy, sustained heat, and broad camera/scene coverage remain unverified. This does not close acceptance gates C01–C10.
