# First model trained for Velyn

2026-10-01. **SignedGainNet v0 is trained and convertible, but is not ready to
replace the app's GMNet model.** It improves the synthetic test score and regresses
on the existing camera audit. No app behavior or bundled weight changed.

## Experiment

The network is original Velyn code, initialized without external weights:
595,201 parameters, three local encoder scales, a global thumbnail branch and a
skip-connected decoder. Output is one signed scalar EV map, bounded to −2…log2(5).
It uses ordinary convolution, pooling, resizing and pointwise operations.

Public data came directly from Poly Haven to the authorized training server.
**Powered by [Poly Haven](https://polyhaven.com)**; the HDR assets are
[CC0](https://polyhaven.com/license). Of 997 catalog HDRIs, metadata grouping gave
431 location/name groups. One original per group and three projected views gave
1,032 training, 129 validation and 132 test views. The respective group counts
are 344, 43 and 44. All 431 sources succeeded. The grouping heuristic can miss
duplicates with incomplete metadata. Views from one source never cross splits.

Sources, split, hashes and generated-view provenance are in the
[frozen manifest](hdr-own-model-pilot/manifest.json). EXRs, tensors and weights are
kept in ignored local storage and the server workspace, outside the repository.
No personal photos or derived camera pixels were sent to the server.

Training used an RTX PRO 6000 Blackwell Workstation Edition, Torch 2.7.0+cu128,
batch 24 and 6,000 steps. The measured training loop took **46.82 seconds**,
including periodic validation and checkpoints, excluding download, initial data
loading and initial validation. Peak allocated CUDA memory at the last progress
sample was about 1,927 MiB. This small experiment does not estimate the duration
of a full-resolution production training job or any iPhone workload.

Validation selected step 5,000 (MAE 0.253206 EV). Test data was not loaded during
training or checkpoint selection. The test was evaluated once after selection.
The weights have SHA-256
`982c19314a4c93096c2bf5ca1734013ee5964a69de917be4ea0e3464e0abcc4f`.

## Synthetic test

44 held-out source groups, 132 views; equal weight per group. Lower mean absolute
log-luminance error is better. Targets are bounded synthetic gains, not native
camera HDR. GMNet uses its published real-world weights at 512px, without app
tone protection; SignedGainNet uses 256px as trained.

| Predictor | Mean error EV |
| --- | ---: |
| Identity / leave SDR unchanged | 0.369007 |
| Published GMNet | 0.335880 |
| SignedGainNet v0 | **0.260362** |

The reduction against GMNet is **22.5%**. A paired bootstrap over the 44 groups
gives a 95% interval of −0.1093…−0.0446 EV for the error difference. This measures
variation within this synthetic collection and does not establish camera quality.

The main weakness is attenuation: only **5.9% recall** and **42.0% precision** for
target gain below −0.05 EV, pooled over valid test pixels. Error within negative
regions is 0.7566 EV, worse than identity's 0.6661 EV. Learning positive gains can
improve average error while leaving the intended darkening behavior inadequate.

## Camera audit

All 15 scenes have been used in earlier experiments, including files named
`holdout-*` and `validation-*`; they are development data now. Evaluation was local
PyTorch CPU on an Apple M2 Mac running macOS 27. Current GMNet is the saved actual
1024px Neural Engine app render. The candidate uses 512px edge-padded inference
and scalar float multiplication. Its codec/display path was not exercised.

| Predictor | Mean error EV | Improved scenes / 15 |
| --- | ---: | ---: |
| Unchanged SDR | 0.613440 | 0 |
| Current app GMNet | **0.463032** | — |
| SignedGainNet, direct gain | 0.492036 | 4 |
| SignedGainNet, existing protection and 75% strength | 0.530663 | 0 |

Direct gain regresses by **6.3%**, with a worst per-scene regression of 0.1624 EV.
The protected variant was specified before this audit; neither variant was tuned
to these results. Scalar application preserves input RGB ratios to numerical
precision, but does not reproduce the reference camera's color reconstruction.

An oracle using the reference's bounded scalar gain reaches 0.001564 EV on this
audit. It uses the answer and is not deployable. It shows that the allowed gain
range can represent nearly all reference luminance here; the prediction remains
the bottleneck. It does not prove that original HDR is uniquely recoverable from
SDR, or that a larger model would solve the ambiguity.

## Conversion and checks

- Five research contract tests pass: transfer functions, signed target generation,
  model initialization/range, capture grouping and panorama projection.
- Rebuilding one frozen public source reproduced metadata and all three NPY
  SHA-256 values exactly. Source bytes were checked against recorded hashes.
- The FP16 Core ML package is 1,233,460 bytes (about 1.18 MiB). Six generated inputs
  pass CPU_ONLY and CPU_AND_NE comparisons: worst absolute differences from
  PyTorch are 0.00810 and 0.00601 EV respectively.
- Five warmed calls per input on this Mac give median runtimes of 9.87–10.22 ms
  for CPU_ONLY and 2.24–2.39 ms for CPU_AND_NE. These are brief synthetic checks,
  not thermal measurements, full editing latency, iPhone timings or confirmed
  placement of every operation on the Neural Engine.
- No Swift engine code changed. Engine tests were not rerun for this Python-only
  experiment; the previous 82-test result is separate evidence. No device install,
  HDR display acceptance, release or public checkpoint publication occurred.

The initial sandboxed Core ML compile could not create its system temporary
directory. The authorized local rerun compiled and completed all comparisons.

## Next data requirement

The compute budget is ample for this model. The next constraint is **matched
camera-native SDR/HDR data**, especially scenes with real local attenuation.
Poly Haven offers useful HDR structure, but our synthetic tone curves and relative
exposure normalization do not teach an iPhone's intended HDR rendering. Gathering
more synthetic crops alone would not resolve that mismatch.

A practical next collection is 500–2,000 independently captured, correctly aligned
SDR/native-HDR pairs for adaptation, with negatives deliberately represented and
camera/scene grouping. Keep another 300–500 scenes untouched for final evaluation.
These are planning ranges, not experimentally established sample requirements.
First test a learning curve on smaller subsets and review target alignment,
transfer functions and SDR white calibration. Private pairs must remain local;
server work may use licensed public pairs only.

Adoption needs improvement on new camera scenes, fewer false darkening regions,
and actual iPhone display/thermal evidence. The previously found ImageIO omission
of gain maps in low-headroom/dimming-dominant exports also remains unresolved.
No C01–C10 or launch gate has been marked passed.

[Reproduction guide](../../Scripts/HDR/Training/README.md) ·
[Training configuration](hdr-own-model-pilot/run.json) ·
[Validation history](hdr-own-model-pilot/validation.json) ·
[Synthetic test details](hdr-own-model-pilot/test.json) ·
[Camera audit](hdr-own-model-pilot/camera-audit.json) ·
[Core ML comparisons](hdr-own-model-pilot/conversion.json)
