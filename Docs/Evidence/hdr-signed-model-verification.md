# Signed gain maps and published model evaluation

2026-10-01. Apple M2, macOS 27.0 (26A428), Xcode 27.0 (27A266a).
Inference: PyTorch 2.7 CPU, four threads, 512px long edge. Storage/render/export:
Core Image and ImageIO on this Mac. This is not an iPhone performance, thermal
or HDR display acceptance result.

## Decision

The engine can now preserve negative as well as positive log2 gain. DITM and
HDRUNet were evaluated with their published weights. Neither qualifies to replace
or augment the default predictor on the tested camera photos. The app continues
to generate positive-only GMNet maps; it does **not** automatically darken photos
with an unvalidated model. No experimental weights were added to the app.

This result does not establish that learned attenuation cannot work. These
checkpoints and the tested adaptation rules did not improve our current pipeline.
A useful next model needs training targets that match the camera SDR/native-HDR
pairs, followed by evaluation on new scenes and physical iPhone display checks.

## Implemented engine path

- Optional `signedLog2V1` recipe metadata distinguishes new numeric PNG maps from
  existing positive maps. An absent key keeps the original interpretation.
- The fixed encoded range is −2…log2(5) EV: gains from 0.25× to 5×. Its zero-EV
  sample is approximately 0.462756. Encoding is independent of user-adjustable caps.
- A local actor entry point accepts aligned finite EV tensors, normalizes them,
  broadcasts Rf's red component to RGB and stores a 16-bit numeric PNG. It performs
  no network access or model selection. It rejects RAW/native-HDR inputs.
- Strength and independent brightening/dimming limits apply during rendering.
  Midtone protection blends toward **zero EV**, not numeric black. Zero strength
  bypasses the effect. Existing resources do not need regeneration.
- Signed recipes expose a localized dimming limit in the existing single-slider
  control. This control stays hidden for ordinary GMNet maps. Undo/redo, reopen,
  crop/rotation and prediction fingerprints retain the metadata.
- HDR export validates the presence of an auxiliary gain map before committing
  an active signed edit. If the encoder drops it, export fails and removes the
  staging file; the original and committed recipe remain intact.

## Models and preprocessing

| Model | Official source / pinned revision | Parameters |
| --- | --- | ---: |
| DITM | [ITM25](https://github.com/SayedNadim/ITM25/tree/c34be980c56856f013ccf1e23168c11bd3a42e1a) | 1,973,665 |
| HDRUNet | [HDRUNet](https://github.com/chxy95/HDRUNet/tree/e9bd4b90a27d7531a38b8c97db05feb368b96dc2) | 1,651,494 |

Both repositories carry MIT licenses. Pinned code, checkpoint and license SHA-256
values are in [the source manifest](../../Scripts/HDR/signed-model-sources.json).
The explicit preparation script was tested with a clean download directory.
All photo processing stayed local. No user photos or derived rasters are in this
repository. No Core ML conversion or NPU claim is made for these two candidates.

DITM takes sRGB input and internally linearizes it. Its official test code treats
output as normalized 1,000-nit linear HDR. We assume 203-nit SDR white for the
comparison. We test direct RGB output, scalar gain, and SDR-only median anchoring.
The anchor is the median gain over input luminance 0.03…0.5, subtracted before
applying the signed range. It is an adaptation heuristic, not model training.

[HDRUNet's paper, sections 1 and 4.1](https://arxiv.org/html/2105.13084v2), states
that its HDR targets have already undergone gamma correction. The initial raw
interpretation was therefore corrected: primary comparisons decode extended
sRGB, with power 2.24 as a sensitivity case. Neither is verified as the exact
transfer curve of arbitrary camera inputs. The unconverted version remains in
numeric evidence only as `hdrunet-raw-diagnostic`; it must not be used to rank the
model. There is no verified absolute nit calibration for these inputs. The
[official repository](https://github.com/chxy95/HDRUNet) also cautions that the
model expects its competition data distribution.

## Quality results

All 15 previously used scenes are exploratory data now, including the filenames
`holdout-*` and `validation-*`. This is not fresh validation or a reproduction of
the models' published benchmarks. There was no fine-tuning. Baseline is the current
1024px Neural Engine GMNet render, evaluated at 512px, not the old v1.1 render.

Lower mean absolute log-luminance error (EV) is better. Each scene has equal weight.

| Candidate | Mean error EV | Scenes improved / 15 | Worst regression EV |
| --- | ---: | ---: | ---: |
| Current GMNet | 0.463032 | — | — |
| DITM signed, anchored | 0.690083 | 0 | +0.624501 |
| HDRUNet extended-sRGB signed, anchored | 0.674723 | 0 | +0.379545 |
| HDRUNet power-2.24 signed, anchored | 0.730467 | 0 | +0.437358 |
| Current + 25% DITM attenuation | 0.481010 | 1 | +0.042455 |
| Current + 25% HDRUNet sRGB attenuation | 0.480647 | 1 | +0.055587 |

50% and 100% attenuation were also tested and regressed further. The best of these
simple 25% combinations increases mean error by about 3.8%. Anchored DITM darkens
42.8% of valid pixels on average; anchored HDRUNet sRGB darkens 31.7%, while the
reference darkens 4.0%. These fractions use a −0.02 EV threshold and exclude
near-black input/reference pixels. They are numeric regions, not semantic labels.
On `validation-07`, where actual attenuation covers 27.6%, HDRUNet's negative-region
precision is 37.1% and recall 51.2%; it frequently darkens the wrong locations.

The result is a mismatch in spatial prediction as well as exposure calibration.
Simply allowing negative values or mixing a small amount of attenuation does not
resolve it. Scalar application prevents new hue shifts, but does not transfer the
networks' RGB detail reconstruction or denoising.

## Storage and codec findings

Actual DITM and extended-sRGB HDRUNet outputs were passed through the app's storage,
reopen, preview and export paths: 15 scenes × 2 models × 2 codecs. Numeric results
are recorded separately from the inference comparison.

The signed 16-bit map and render path preserve the requested EV field: worst
scene mean error is 0.000863 EV. Preview readback adds at most 0.001035 EV mean
error. These small numeric errors do not establish perceptual HDR quality.

ImageIO silently omitted the auxiliary gain map in 26 of 60 initial export
attempts, concentrated in dimming-dominant or low-headroom predictions. Resetting
inherited headroom to unknown did not change the outcome, so that proposed change
was discarded. The final exporter rejects those cases rather than publishing
an unchanged SDR base as HDR. General dimming-only HDR export therefore remains
an unresolved codec limitation of the tested system path.

The final run produced 34 valid gain-map exports and rejected the other 26.
Every successful export retained its auxiliary map. Among these successful cases,
worst scene mean reconstruction error was 0.072433 EV for JPEG and 0.059661 EV for
HEIC; 97.4% / 98.5% of intended negative-region pixels remained measurably darker
than the SDR fallback on average. Lossy codecs do not preserve every pixel or
prove perceptual equivalence. All imported originals passed hash verification.

A separate macOS 27 readback issue appeared when converting some decoded CG/CI
images directly to RGBAf: raw 8-bit bytes were copied as floats or the process
crashed. An explicit Core Graphics float bitmap avoids it in the experiment.
No iPhone reproduction has been performed and this is not attributed to model
inference. The app's synthetic signed JPEG/HEIC regressions use its usual CIImage
HDR decoder and pass; real-photo device decoding remains a gate.

## Verification and remaining gates

`./Scripts/verify.sh`: **82 tests in 12 suites passed**, including two signed
JPEG/HEIC cases, two dimming-only codec cases and the existing four actual GMNet
512/1024 JPEG/HEIC cases. iOS Simulator build succeeded. Unsigned generic iPhone
build also succeeded. No physical-device installation or display check was made
for this change.

The synthetic tests exercise actual Rf tensors, neutral/color/alpha preservation,
zero-EV protection, independent caps, signed PNG storage, geometry, history,
JPEG/HEIC reconstruction and embedded SDR fallback. Invalid dimensions, NaN,
infinity, cancellation and codec failure leave originals and committed work intact.

See [reproduction commands](../../Scripts/HDR/README.md#signed-gain-models-ditm-and-hdrunet).
The [numeric evidence](hdr-signed-model-results.json) contains quality comparisons,
negative-region diagnostics and all 60 export outcomes without photo pixels or
local source paths.
The default model and public release are unchanged. Remaining work includes a
candidate that improves on fresh camera pairs, a dependable low-headroom signed
export path, and physical iPhone color, HDR adaptation and thermal measurements.
