# Camera-adapted GMNet in the app

2026-10-02. The user requested replacing the app model and adjusting its
postprocessing after the fine-tuning comparison. Both bundled input sizes now
use **gmnet-camera-v1**, selected training step 4500. This is an app integration;
a release, phone installation and physical HDR display acceptance were not
performed in this change.

## Behavior

- New predictions use strength **100%**, maximum gain **5×**, and midtone
  protection **off**. The maximum is a ceiling, not a uniform brightness boost.
- Bilinear enlargement matches the direct prediction path used in the 132-photo
  comparison. The older edge-aware path remains available to stored recipes.
- Midtone protection and strength remain adjustable. **Model prediction** restores
  full strength and the model's cap; **Preserve tones** provides the previous
  protective treatment.
- Existing maps and their tone/upsampling settings are unchanged. No inference
  runs on launch or import. An older map gets a localized prompt to predict again.
  Explicit regeneration preserves the user's strength, cap and protection values;
  tap **Model prediction** afterward to use the new defaults on that photo.
- Optional `predictionModel` records provenance without making old projects depend
  on model availability. The default initializer and missing-key decoding are
  unchanged. RAW and native HDR still use their existing paths.
- Runtime calibration selects pinned FP32 reference samples by model provenance.
  Thresholds remain 0.02 EV for constant gray and 0.04 EV for the asymmetric ramp.
  CPU + Neural Engine is requested first. The calibrated 512 fallback remains;
  this does not establish every operator's placement on an iPhone.

The model retains scalar positive gain, 0…log2(5) EV. It does not predict dimming.
Rf tensors are still broadcast equally to RGB before storage and multiplication.
The separately implemented signed-map path remains compatible.

## Actual engine comparison

Eight existing comparison photos were chosen before this integration comparison:
sort anonymous IDs, choose the first photo in each distinct capture group, stop
at eight. These are from the previously examined 132-photo set, not a fresh test
set. No tuning followed these eight results.

Both models processed the same embedded SDR images through the current Swift
engine on an **Apple M2 Mac, macOS 27**. `prepare.swift` imports a temporary
16-bit P3 SDR representation, performs model inference, saves and reloads the
numeric map, and renders at the source resolution. Metrics then sample aligned
512px outputs against the native HDR representation, using `metrics.py`, linear
sRGB and the stated 203-nit PU21 assumption. The original camera files remained
byte-identical. Repeated source decodes differed by at most 0.000000954 in a
linear float channel; both variants were scored against the same reference.

| Model and treatment | Mean luminance MAE, EV ↓ | PU21 PSNR ↑ | PU21 SSIM ↑ |
| --- | ---: | ---: | ---: |
| Previous model and defaults | 0.469327 | 31.146 | 0.988169 |
| Previous model, direct prediction | 0.369402 | 31.755 | 0.991768 |
| Tuned model, previous protection | 0.426547 | 31.516 | 0.988446 |
| **Tuned model, new defaults** | **0.285350** | **34.716** | **0.993458** |
| Tuned model, full gain with edge-aware enlargement | 0.285094 | 34.747 | 0.993636 |

New defaults reduce mean error **39.2%** against the previous defaults on this
small check. Six of eight photos improve; two regress, with a worst increase of
**0.624240 EV**. The mean per-photo luminance ratio is **1.1694**, so the new result
still tends to be brighter than the native reference on this subset. Mean u′v′
error is 0.000106, compared with 0.000119 previously. This is evidence that the
measured improvement survives app integration, not a claim of native HDR recovery
or uniform improvement. Edge-aware and bilinear results are close here; this
subset was not used to retune the interpolation choice.

The earlier 132-photo Core ML comparison was 0.327723 EV versus PyTorch's 0.327842
EV. Its input preparation and scale differ from this full engine check, so these
numbers must not be directly combined. See the [training comparison and its
limits](hdr-gmnet-finetune-verification.md).

Reproduce the two engine runs using `Scripts/HDR/prepare.swift` with the private
manifest, original model and bundled model, then aggregate without photo IDs:

```sh
python Scripts/HDR/summarize_camera_integration.py PRIVATE_MANIFEST \
  ORIGINAL_ENGINE_OUTPUT CAMERA_ENGINE_OUTPUT \
  Docs/Evidence/hdr-camera-integration-results.json
```

[Aggregate results](hdr-camera-integration-results.json) contain no photos,
filenames, dates, private paths or per-photo scores.

## Verification

- `./Scripts/verify.sh`: **83 tests in 12 suites passed**; iOS Simulator build passed.
- iPhone architecture build from `Docs/api-availability.md`: **BUILD SUCCEEDED**,
  signing disabled. The only device-build warning skips unused App Intents metadata.
- Real bundled 512/1024 inference, Rf map storage, neutral RGB preview, JPEG and
  HEIC HDR auxiliary maps, preserved SDR base, import rejection for existing HDR,
  cancellation, original integrity, recipe persistence and legacy rendering passed.
- Added checks assert actual applied gain equals the stored model EV without the
  former protection gate, and reject the other checkpoint's calibration samples.
- Both model sizes retain the original MIT attribution and mixed precision policy.
  The 512 conversion passed the same six synthetic CPU/NE cases as 1024, with
  maximum PyTorch/Core ML error below 0.06 EV. Hashes are in
  [model-integrity.json](../model-integrity.json).
- Python compilation and `git diff --check` passed.

Private photos and the PyTorch training checkpoint remain outside Git. The user
requested this model change; only converted inference weights are bundled. Exact
retraining cannot be reproduced without the private dataset. This integration
used local inference only; no data was uploaded and prior server cleanup remains
as recorded. App processing stays entirely on-device.

Remaining checks: new camera scenes, physical iPhone HDR appearance, device
latency/heat, and broader codec/display behavior. No C01–C10 or full Lightroom
parity acceptance gate is marked complete by this work.
