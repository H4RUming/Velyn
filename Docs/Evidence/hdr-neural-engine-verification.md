# HDR inference on Neural Engine

2026-10-01. The shipped weights are still GMNet's pinned MIT real-world checkpoint.
This change alters conversion precision, equivalent operators, inference routing,
and input resolution. It does not claim recovery of the original scene radiance.

## What changed

- The small global thumbnail branch stays FP32; the local branch stays FP16.
- Dynamic depthwise convolution is replaced by nine static slices and channel
  multiplications. PyTorch equivalence is required within 0.0001 EV. No retraining.
- New predictions prefer CPU + Neural Engine. Two generated calibration inputs
  must match pinned FP32 samples before a backend is cached. Invalid results
  retry GPU, then CPU on the 512 model. Cancellation is propagated.
- A bundled 1024 variant is selected for originals with a long edge of at least
  1024 pixels when a Neural Engine is reported and its calibration passes.
  A failed 1024 calibration falls back to 512 rather than retrying 1024 on GPU/CPU.
- Saved gain-map resources and existing recipes retain their rendering. The
  larger model is used only when a new prediction is requested. No model download.

`cpuAndNeuralEngine` permits CPU work too. Compute-plan placement is recorded;
it is not an Instruments trace or a claim that every operation executes on ANE.
Apple describes this partitioning in [Tune your Core ML models](https://developer.apple.com/videos/play/wwdc2021/10038/).

## Numerical issue found during acceleration

On **Apple M2 / macOS 27.0 (26A428)**, enabling ANE on the original fully FP16
conversion changed a constant-0.5 reference from about 0.356 EV to 0.253 EV.
The old 0.24–0.45 calibration interval would have accepted that result.
The asymmetric color ramp had up to 0.209 EV error versus Core ML CPU at 512.

Intermediate-output probes located large divergence in the global downsampling
branch, then amplification through its residual blocks. Keeping that branch in
FP32 reduced maximum ramp error to **0.0313 EV at 512** and **0.0362 EV at 1024**;
mean errors were about 0.0073 EV. Static-kernel conversion alone did not fix it.
These observations support a precision-sensitive global branch; the precise
hardware arithmetic cause has not been proven.

The new calibration uses constant and asymmetric inputs, with per-sample
tolerances of 0.02 and 0.04 EV. It rejects the observed drift and all-zero output.
Full-image backend comparison on a generated ramp has separate maximum/mean
gates of 0.06/0.015 EV. Real model/Rf/neutral RGB export tests remain in place.

## Timing and placement

These are **Mac M2 measurements**, not A17 Pro or iPhone measurements.
Each number is a median of six warm predictions (two generated inputs, three
runs each). Model load, warmup, image decoding, map storage and rendering are
excluded. This is a short benchmark, not a sustained-load or energy test.

| Conversion / input | CPU | GPU | CPU + Neural Engine |
| --- | ---: | ---: | ---: |
| Original, 512 | 238 ms | 65 ms | 24 ms — fails accuracy |
| Corrected, 512 | 126 ms | 62 ms | 30 ms |
| Corrected, 1024 | 529 ms | 244 ms | 105 ms |

For corrected 1024, the compute plan prefers Neural Engine for 124 operations
and CPU for 53, with approximately 95.6% of estimated operation cost assigned
to ANE. Cost weights are Core ML estimates, not measured execution-time fractions.
The prior 4.55× figure compared 512/1024 PyTorch CPU inputs and is a different
measurement from this Core ML backend comparison.

## Actual app output quality

Repeated the full app input padding, prediction, PNG map storage, edge-aware
enlargement, tone protection and rendering on the same 15 local HDR pairs.
These scenes are already used development data; they are not a fresh holdout.
Metrics use the previous common 512-pixel evaluation size and PU21 SDR white
of 203 cd/m². Original hashes were preserved. Photos and arrays remain private.

| Path | Mean log-luminance MAE | PU21 PSNR | PU21 SSIM | Worst per-scene MAE regression |
| --- | ---: | ---: | ---: | ---: |
| v1.1 | 0.465438 EV | 30.487 dB | 0.978948 | — |
| Corrected 512 / ANE | 0.466069 EV | 30.485 dB | 0.978943 | +0.003045 EV |
| Corrected 1024 / ANE | 0.463032 EV | 30.586 dB | 0.979537 | +0.001361 EV |

1024 improves MAE on 11/15 scenes, reducing mean MAE by **0.52%**. Chroma error
changes by about 0.0000014 in u′v′. This is a small numerical improvement, not a
claim that SDR now matches native HDR or that the difference is perceptually visible.
The 512 fallback stays close to prior output but does not improve mean quality.

Repeated Core Image decoding differed by up to 0.0000062 in reference linear RGB;
the comparison records these differences and uses the same archived reference
for all scores. They are below the 0.00001 repeatability gate.

## Signed-gain experiment

Ran 15-fold leave-one-scene-out experiments with the same 1,861-parameter
residual architecture and training budget, comparing positive-only targets
with targets allowing down to −2 EV. Mean MAE was 0.392781 versus 0.393210 EV.
Both had a worst regression of about **+0.433 EV** against v1.1. The signed
model predicted almost no negative regions. Merely changing the output range
and loss target was insufficient with this small dataset and architecture.

Neither prototype is bundled. A representation that supports attenuation is
still useful research, but there is no validated model to drive it yet.

## Verification and limits

- `./Scripts/verify.sh`: **77 tests passed**, including 512/1024 × JPEG/HEIC
  real-model round trips, neutral preview/export, unchanged SDR fallback,
  map orientation, alpha/chroma, invalid calibration, and cancellation.
- iOS simulator build and signed iPhone Release build succeeded.
- An iPhone installation attempt failed because the phone was locked and its
  developer disk image could not mount. Device timing, memory, power, thermal
  behavior and HDR display judgment remain unverified. No C01–C10 gate is closed.

Numeric evidence: [hdr-neural-engine-results.json](hdr-neural-engine-results.json).
Conversion recipes and hashes: [model instructions](../../Scripts/Models/README.md),
[integrity record](../model-integrity.json).

## Reproduce

```sh
# Use the pinned local checkpoint; there are no automatic downloads.
python Scripts/Models/convert_gain_map.py /private/path/G_realworld.pth \
  --precise-global --static-kernel
python Scripts/Models/convert_gain_map.py /private/path/G_realworld.pth \
  --precise-global --static-kernel --size 1024 \
  --output Velyn/Models/VelynGainMap1024.mlpackage
python Scripts/Models/calibrate_gain.py /private/path/G_realworld.pth
swiftc -parse-as-library -D GAIN_BENCHMARK_CLI \
  Velyn/Platform/GainMapBenchmark.swift -o .work/gain-benchmark
.work/gain-benchmark /private/path/results.json /private/path/model.mlmodelc
```

For iPhone developer runs, a Debug build launched explicitly with
`--gain-benchmark` writes `Documents/gain-benchmark.json` from synthetic inputs.
It never opens the photo library or runs during a normal app launch.
Use `Scripts/HDR/prepare.swift` into fresh private directories for each model,
then `compare_accelerated.py` against the archived v1.1 directory.
`signed_experiment.py` records the exploratory leave-one-scene-out experiment.
