# HDR experiments after v1.1

2026-10-01. The user requested all immediately available quality experiments, with NPU optimization deferred. App code, default settings, bundled weights, and the released IPA are unchanged.

## Scope and evidence

- **15 native-HDR/embedded-SDR pairs:** eight previously used development images and seven newly reserved validation images. The new files are [gainmap-js fixtures 04–10](https://github.com/MONOGRID/gainmap-js/tree/main/tests/files). Three development files share this repository; this is a small convenience sample, not independent camera coverage.
- **68 variants per image: 1,020 comparisons**, each evaluated at both 203 and 100 cd/m² reference-white assumptions. The shortlist was frozen before validation scores were opened. No validation-based retuning occurred.
- **Nine tiny CNN training runs:** eight leave-one-image-out development runs and one final run on all eight development images. A separate ridge scene-calibration experiment uses the same split. These are feasibility prototypes, not production-trained models.
- **74 photo codec round trips:** 37 candidates, each exported as HDR JPEG and HEIC. Two additional generated signed-gain exports test attenuation, amplification, and neutral colors.
- All 15 original-file preservation checks pass. No photo was uploaded, and no real photograph, derived raster, or trained experimental weight is included in the repository.

[Numeric summary](hdr-experiment-summary.json) · [All per-image results](hdr-experiment-results.csv) · [Reproduction](../../Scripts/HDR/README.md)

## Method

macOS 27, Xcode 27, production Core Image/Core ML plus PyTorch CPU experiments with four threads. Measurements use a 512px long edge in extended linear sRGB. Actual production renders are labeled `production/`; Python treatments operate on sampled data and are not full-resolution app implementations.

Metrics include log-luminance MAE/P95, gain correlation, mean luminance ratio, PU21 PSNR/SSIM, CIE u′v′ chromaticity distance, and dark/mid/bright/HDR/edge region errors. Region labels are numerical masks, not semantic recognition. PU21 uses the BSD-licensed `banding_glare` equation, an explicit shared white level, and a fixed 0.005–10,000 cd/m² range; neither output is independently exposure-normalized. No reference sample exceeded that range at 203 cd/m². These are assumed viewing conditions, not screen measurements.

Identity, brightness-change, red-cast, and scalar-gain chromaticity invariants pass. A color-managed Pillow comparison confirms that the Core Image model input is not vertically inverted: mean code-value differences were 0.00364 in the same orientation versus 0.23346 after a vertical flip on the sunset sample. Alternative flip inputs remain ensemble experiments, not an orientation bug fix.

The selection gate required lower mean brightness error, non-decreasing PU PSNR, PU SSIM no worse by more than 0.002, chromaticity error no worse by more than 0.0001, and no image with over 0.03 EV MAE regression. It nominated three input variants; the 1024px candidate was strongest on development. This gate establishes a research shortlist, not release acceptance.

## Results

MAE is in EV; lower is better. PU scores below use 203 cd/m². The 512px measurements differ slightly from the previous 256px audit.

| Treatment | Development MAE | Validation MAE | Validation PU PSNR | Validation PU SSIM |
| --- | ---: | ---: | ---: | ---: |
| Shipped v1.1 | 0.3717 | 0.5726 | 27.56 | 0.97178 |
| Legacy protection | 0.4388 | 0.6600 | 26.33 | 0.97298 |
| v1.1 with bilinear enlargement | 0.3715 | 0.5727 | 27.56 | 0.97183 |
| 512px float input, adaptive protection | 0.3712 | 0.5733 | 27.59 | 0.97513 |
| **1024px float input, adaptive protection** | **0.3699** | **0.5704** | **27.68** | **0.97537** |
| Three-orientation 512px ensemble | 0.3712 | 0.5736 | 27.58 | 0.97515 |
| Gamma-2.2 reconstruction | 0.4274 | 0.6355 | 26.72 | 0.95181 |
| No tone protection, 75% gain | 0.3399 | 0.5035 | 28.50 | 0.97545 |
| Learned scene scale | 0.3733 | 0.4484 | 29.63 | 0.97538 |
| Small residual CNN | 0.3831 | 0.4647 | 29.60 | 0.97375 |

### What is worth keeping?

- **1024px input:** small, consistent improvement: validation MAE falls about 0.4%, improving six of seven images, with a worst increase of 0.0015 EV. Mean CPU/PyTorch forward time across all samples is 3.79 seconds versus 0.83 seconds for native 512px float input, about 4.55×. The change also differs from the shipped pipeline in padding/interpolation; its entire advantage cannot be attributed to resolution alone. It is a possible optional quality mode, not a demonstrated fix for the visible HDR mismatch.
- **Float input instead of 8-bit input:** negligible difference on these samples. It does not justify blaming quantization for the current quality gap.
- **Orientation ensemble:** more inference work without a validation brightness improvement. Defer.
- **Bilinear versus edge-aware enlargement:** tiny average differences; the global metrics do not overturn the existing sharp-boundary regression test. No reason to switch globally based on this corpus.
- **Gamma 2.2:** worsens brightness, structure, and color metrics. Reject as a blanket correction.
- **Removing tone protection:** better mean brightness error but up to 0.142 EV regression on a development image. It does not pass the scene-regression gate.
- **Learned scene scale:** validation mean error improves about 21.7%, but leave-one-image-out development has a worst regression of 0.269 EV and worse mean PU PSNR. Keep as a research direction, not a replacement.
- **1,861-parameter CNN:** validation mean error improves about 18.8%, but only three of seven validation images improve; worst regression is 0.230 EV. Development worst regression is 0.430 EV. Shared-scale visual inspection shows excess brightening of a night city scene and shadow errors. Reject for deployment; eight training images are inadequate evidence for a general model.

Changing reference white from 203 to 100 cd/m² preserves the key conclusions. For example, validation v1.1/1024 PU PSNR is 28.384/28.518 dB and PU SSIM is 0.96987/0.97318.

## A newly measured representation limit

The current app bounds predicted log gain to 0…log2(5), so it can only preserve or increase a pixel's brightness. Native HDR is not always brighter at every pixel than its SDR rendition. In validation 07 and 09, **27.6% and 25.7%** of the evaluated pixels have native HDR gain below −0.02 EV.

An oracle that knows the exact reference but is constrained to 1×–5× gain still has MAE floors of **0.1778 EV and 0.0401 EV** on these two images. This oracle was computed after candidate selection to diagnose expressiveness, not to select or fit a deployable method. Most other samples have very small floors, so this restriction does not explain all of the mismatch.

Signed log gain is compatible with the intended gain-map concept: [Ultra HDR's specification](https://developer.android.com/media/platform/hdr-image-format) explicitly allows a minimum content boost below 1. A generated neutral ramp confirms the current ImageIO export path can encode this: requested 0.5×/4× decodes to **0.49993×/3.99820× in JPEG** and **0.49998×/3.99861× in HEIC**, with maximum RGB channel spreads below 0.000003. This tests codecs, not a learned signed-gain predictor or compatibility with every viewer.

The promising next model target is a gain field that can both attenuate and amplify, supervised by real SDR/HDR pairs and tested across diverse scenes. The stored representation, compatibility version, and training target would all need to change together. Simply allowing negative numbers from a model trained on nonnegative targets is not sufficient.

## Export checks

All 74 photo exports contain gain maps. Compared with the corresponding candidate before encoding, JPEG mean HDR luminance MAE is **0.0338 EV** (worst 0.0595), HEIC **0.0210 EV** (worst 0.0462). Mean SDR-base MAE is 0.0320 EV and 0.0194 EV respectively. These are 512px, quality-95 codec checks; they include expected lossy image differences and are not full-resolution acceptance. Export loss is much smaller than the measured prediction mismatch in this corpus.

## Decision

Keep the shipped v1.1 defaults while retaining the 1024px candidate for a future optional quality mode. None of the tested cheap postprocessing or tiny learned corrections provides a large, consistently safe improvement across both groups. Prioritize broader paired training data and a signed-gain target over further fixed brightness curves. NPU optimization remains deferred.

The iPhone was discoverable as paired during this session, but no physical display comparison, thermal test, or device inference timing was performed. Mac and SDR comparison images cannot establish physical HDR appearance. Release acceptance gates remain open.
