# Local HDR experiments

These scripts evaluate alternatives to v1.1 without changing app behavior or bundled weights. All inference and evaluation run locally. Do not commit manifests, input photos, float tensors, trained experimental weights, or photo previews.

## Protocol fixed before the new validation set is evaluated

2026-10-01. The eight images used for v1.1 are now development data. Seven additional numbered fixtures (04–10) from MONOGRID/gainmap-js are reserved for validation. They share a source repository with three development photos; this is not an independent camera benchmark. A policy is selected using development results before opening validation scores. Do not retune it on validation failures.

Compare shipped Core Image outputs separately from approximations made on 512px samples. Test these immediately available families:

- Strength, gain cap, no protection, linear/perceptual/adaptive/shadow protection, and global gain offsets.
- Bilinear versus the shipped edge-aware enlargement.
- Input size, padding, float versus 8-bit input, orientation ensemble, and gamma convention.
- A small learned scene-level calibration and a small residual CNN, trained only on development scenes, with leave-one-scene-out development checks. This is a feasibility experiment, not enough data for a production model.
- JPEG/HEIC round trips for any shortlisted treatment.

Report log-luminance MAE/P95, mean luminance ratio, gain correlation, PU21 PSNR/SSIM, chromaticity error, and dark/mid/bright/edge region errors. Regions are numeric luminance masks, not semantic sky/face labels. PU21 assumes SDR white = 203 cd/m², and also checks 100 cd/m² sensitivity. Candidate and reference use the same absolute scale, without independent exposure normalization. These are simulated reference-viewing conditions, not measured display luminance.

Promotion requires improvement across brightness, structure, and color with no substantial per-scene regression. A better mean alone does not qualify. No physical-device HDR display check is available in this experiment.

## Prepare

A private JSON manifest contains `id`, `group` (`development` or `validation`), and absolute `input` paths. Use unique alphanumeric/hyphen/underscore IDs. All inputs must contain readable native HDR and an SDR base.

```sh
swiftc -O -parse-as-library $(rg --files Velyn/Engine -g '*.swift') \
  Scripts/HDR/prepare.swift -o .work/prepare-hdr
.work/prepare-hdr /private/path/manifest.json /private/tmp/hdr-experiments \
  Velyn/Models/VelynGainMap.mlpackage
```

Preparation preserves original bytes and writes aligned linear-sRGB float pixels, model inputs, stored numeric gain maps, and actual production renders. Existing completed samples are reused; use a fresh output directory after changing the engine or fixture preparation.

## Run and reproduce

Use a dedicated Python environment with `numpy==1.26.4`, `torch==2.7.0`, `scipy==1.17.1`, `scikit-image==0.25.2`, and Pillow. Core ML conversion remains separate. The local macOS 27 loader rejected the SciPy 1.15.3 wheel; 1.17.1 passed the metric checks.

```sh
python Scripts/HDR/metrics.py
python Scripts/HDR/experiment.py /private/tmp/hdr-experiments .work/hdr-results \
  /private/path/G_realworld.pth --phase development
# The previous command writes frozen.json and residual.pt. Do not change them.
python Scripts/HDR/experiment.py /private/tmp/hdr-experiments .work/hdr-results \
  /private/path/G_realworld.pth --phase validation
python Scripts/HDR/export_candidates.py /private/tmp/hdr-experiments \
  .work/hdr-results /private/tmp/hdr-candidates
swiftc -O -parse-as-library Scripts/HDR/roundtrip.swift -o .work/hdr-roundtrip
.work/hdr-roundtrip /private/tmp/hdr-candidates
python Scripts/HDR/diagnose_limits.py /private/tmp/hdr-experiments \
  .work/hdr-results/representation-limits.json /private/tmp/hdr-signed
.work/hdr-roundtrip /private/tmp/hdr-signed
python Scripts/HDR/measure_roundtrip.py /private/tmp/hdr-candidates \
  /private/tmp/hdr-signed .work/hdr-results
python Scripts/HDR/summarize.py .work/hdr-results Docs/Evidence
```

The 68 variants include actual production renders, sampled postprocessing, six PyTorch input variants plus a three-pass ensemble, gamma diagnostics, ridge scene calibration, and a 1,861-parameter residual CNN. Learned development results exclude the evaluated image from training; final weights use only the eight development images. The CNN uses four 64px patches per step, 120 Adam steps at 0.002, and seed 20261001. No pretrained app weight is modified. Timing is Mac CPU/PyTorch with four threads, not iPhone or Core ML latency.

`diagnose_limits.py` is a post-selection diagnostic: its oracle uses reference pixels to measure representation limits and cannot be deployed as a predictor. The generated neutral signed-gain ramp has known 0.5× and 4× gain. Its source is this script, with no external image input.

`export_candidates.py` keeps private visual comparisons on a shared −2 EV SDR scale. They cannot demonstrate physical HDR display luminance. `summarize.py` exports only numeric CSV/JSON evidence, never photo rasters, source paths, or trained weights. [Measured findings](../../Docs/Evidence/hdr-experiments-2026-10-01.md).

## References

- [PU21 reference implementation](https://github.com/gfxdisp/pu21): banding_glare encoding, BSD-3-Clause. Preserve its notice in any port.
- [GMNet](https://github.com/qtlark/GMNet): existing pinned MIT-licensed implementation and checkpoint.
- [Evaluation pitfalls](https://arxiv.org/abs/2108.08713): objective improvement is not proof of perceived HDR quality.

## Signed gain models (DITM and HDRUNet)

This later experiment reuses all 15 scenes above. None is a fresh holdout now.
It evaluates published checkpoints, without training on the reference images.
The candidates are research inputs; neither replaces the bundled GMNet.

```sh
# Explicit developer download. Without --download this only verifies local files.
python Scripts/HDR/prepare_signed_models.py .work/signed-models --download
python Scripts/HDR/compare_signed_models.py .work/signed-models \
  /private/tmp/hdr-experiments /private/tmp/current-ne1024 .work/signed-comparison
swiftc -O -parse-as-library $(rg --files Velyn/Engine -g '*.swift') \
  Scripts/HDR/roundtrip_signed.swift -o .work/signed-roundtrip
.work/signed-roundtrip /private/tmp/hdr-experiments .work/signed-comparison \
  /private/tmp/signed-roundtrip
python Scripts/HDR/measure_signed_roundtrip.py /private/tmp/signed-roundtrip \
  .work/signed-comparison .work/signed-roundtrip-results.json
python Scripts/HDR/summarize_signed.py .work/signed-comparison/comparison.json \
  .work/signed-roundtrip-results.json Docs/Evidence/hdr-signed-model-results.json
```

`current-ne1024` is a fresh `prepare.swift` run using `VelynGainMap1024.mlpackage`.
It must match the fixture IDs and dimensions. The comparison checks pinned source,
weight and license hashes in `signed-model-sources.json` before executing the
external code. Downloads use official GitHub raw URLs at fixed commits. DITM's
checkpoint includes NumPy scalar metadata; loading uses `weights_only=True` with
only its known scalar types allowlisted. Keep both MIT notices with the downloaded
files. Cached predictions are keyed by the exact preprocessed input tensor.

DITM predicts linear HDR normalized to 1,000 nits in its official test code.
The comparison assumes 203-nit SDR white. HDRUNet predicts **nonlinear** HDR:
its paper explicitly describes gamma-corrected targets. The experiment tests
extended sRGB and a 2.24 power curve as transfer assumptions. Raw output treated
as linear is retained only as a diagnostic, not a fair primary comparison.
HDRUNet has no verified absolute nit calibration for these camera photos.

The signed variants bound log2 gain to −2…log2(5). An optional median anchor
uses only SDR midtones; it never looks at reference HDR. Attenuation-only variants
add 25%, 50% or 100% of the negative correction to the current GMNet output.
The scalar gain preserves source RGB ratios. RGB denoising/detail predictions
are not applied by that path.

`roundtrip_signed.swift` uses the app's actual numeric PNG storage, history,
preview and export. It records rejected exports when ImageIO omits a gain map;
it does not count those files as successful HDR. Eager ImageIO decoding followed
by an explicit Core Graphics float bitmap avoids a macOS 27 Core Image direct
readback crash encountered during this experiment. This workaround is confined
to the research reader, not the app. Use a new output directory for each run.

[Signed model findings and limitations](../../Docs/Evidence/hdr-signed-model-verification.md).

## Training a Velyn predictor

[SignedGainNet research](Training/README.md) provides explicit public CC0 data
preparation, a scene-grouped split, training from scratch, a frozen synthetic test,
a local camera audit and Core ML conversion. It does not replace the app model.
The [first results](../../Docs/Evidence/hdr-own-model-verification.md) explain why
better synthetic scores did not yet translate to better camera HDR.
