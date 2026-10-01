# SignedGainNet training pilot

An original 595,201-parameter CNN trained from scratch to predict a scalar log2
gain between −2 and log2(5) EV. It can brighten and darken different regions.
The checkpoint is a research candidate; the app still uses GMNet.

**Powered by [Poly Haven](https://polyhaven.com).** Source HDR panoramas are
[CC0](https://polyhaven.com/license). The explicit preparation command follows
the [API terms](https://github.com/Poly-Haven/Public-API/blob/master/ToS.md), uses
a distinct User-Agent, checks asset hashes, and records source URLs. No download
code is included in the app. Do not copy private photo libraries to the server.

## Data and limits

The first collection has 431 source panoramas in 431 location/name groups.
Grouping joins captures within 2 km or the same normalized name family before
splitting. This is a metadata heuristic, not a guarantee against every duplicate.
One panorama per group yields three 256px perspective views. The split is:

| Split | Groups | Views |
| --- | ---: | ---: |
| Train | 344 | 1,032 |
| Validation | 43 | 129 |
| Test | 44 | 132 |

These are 431 source groups, **not 1,293 independent scenes**. The recorded
[manifest](../../../Docs/Evidence/hdr-own-model-pilot/manifest.json) freezes
the selection, source MD5/SHA-256, projection angles, normalization and split.
Source EXRs total 1.48 GB. Images and checkpoints stay outside Git.

We treat EXR RGB as linear Rec.709/sRGB primaries for this pilot. Per-view
95th-percentile luminance is normalized to 0.8 before exposure augmentation.
Neither this normalization nor the source metadata establishes absolute nits.
`pairs.py` generates exposure/WB variations, highlight compression, shadow lift,
local tone changes, 8-bit quantization and small noise. Targets are the bounded
log2 luminance ratio after degrading the actual input. Pixels below 0.003 linear
luminance in either image are excluded from the point loss.

This is synthetic pretraining. It does not reproduce an iPhone ISP, recover
clipped chroma/detail, or provide camera-native HDR labels. The model predicts
one shared RGB multiplier, so it preserves the input color ratios. A single SDR
image can correspond to different original HDR exposures and tone curves;
random tone recipes cannot remove that ambiguity.

## Reproduce on a CUDA server

Tested with Python 3.12.3, Torch 2.7.0+cu128, NumPy 1.26.4, SciPy 1.17.1,
OpenEXR 3.3.3 and Pillow 12.3.0. The existing GMNet audit additionally needs the
MIT code in `Scripts/Models/gmnet` and its pinned public `G_realworld.pth` weights.

From the repository root, use an isolated virtual environment and ignored output:

```sh
python3 -m venv .work/hdr-training-venv
.work/hdr-training-venv/bin/pip install torch==2.7.0 --index-url https://download.pytorch.org/whl/cu128
.work/hdr-training-venv/bin/pip install numpy==1.26.4 scipy==1.17.1 OpenEXR==3.3.3 Pillow==12.3.0

.work/hdr-training-venv/bin/python Scripts/HDR/Training/test_training.py
.work/hdr-training-venv/bin/python Scripts/HDR/Training/prepare_data.py \
  .work/hdr-data --frozen-manifest Docs/Evidence/hdr-own-model-pilot/manifest.json
.work/hdr-training-venv/bin/python Scripts/HDR/Training/train.py \
  .work/hdr-data .work/hdr-run --steps 6000 --batch 24
.work/hdr-training-venv/bin/python Scripts/HDR/Training/evaluate.py \
  .work/hdr-data .work/hdr-run/best.pt .work/hdr-run/test.json \
  --gmnet-source Scripts/Models/gmnet --gmnet-weights .work/gmnet/G_realworld.pth
```

Omitting `--frozen-manifest` explicitly queries the live catalog and may produce
a different collection. Keep a separate output directory for each collection.
Training refuses an incomplete manifest. `--resume` restores optimizer, scaler,
scheduler and step after checking configuration and manifest identity. Initial
weights and per-step augmentation use recorded seeds; CUDA convolution selection
is not forced deterministic, so bit-identical weights are not promised.

The loss combines Smooth L1 in EV with a small spatial-gradient term. AdamW,
cosine learning rate 0.0002→0.00001, batch 24, FP16 autocast and gradient clipping
are fixed for the pilot. Validation runs every 1,000 steps. The lowest validation
MAE selects `best.pt`; test views are loaded only by `evaluate.py`. Test recipes
use per-view seeds and remain fixed. Do not tune on this test report; after
examining it, reserve new groups for the next final evaluation.

## Local camera audit and Core ML

Bring only the trained weights to the Mac. Existing private fixtures remain on
the Mac. `audit_camera.py` consumes outputs from the preparation scripts in the
[parent guide](../README.md):

```sh
python Scripts/HDR/Training/audit_camera.py \
  .work/hdr-run/best.pt /private/tmp/velyn-hdr-experiments \
  /private/tmp/velyn-hdr-ne1024 .work/hdr-run/camera-audit.json
python Scripts/HDR/Training/convert.py .work/hdr-run/best.pt .work/hdr-run/coreml
```

The audit also needs scikit-image 0.25.2. Conversion uses macOS, Torch 2.7.0,
NumPy 1.26.4 and coremltools 9.0. It traces 512px local input plus a 128px global
thumbnail into an FP16 ML Program, with iOS 18 as the model format minimum.
This does not change the app's deployment target. CPU and CPU_AND_NE policies are
compared with PyTorch on six generated inputs. A requested compute policy is not
proof of all operations running on the Neural Engine.

No script copies the candidate into `Velyn/Models`, changes the app model choice,
or packages it into a release. [Results and adoption gates](../../../Docs/Evidence/hdr-own-model-verification.md).
