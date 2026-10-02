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

## Explicitly authorized private camera adaptation

Private camera data requires the owner's explicit authorization for the chosen
server. This developer workflow does not add uploads or a backend to the app.
Keep all pixel data, manifests, source hashes, dates, per-image scores and trained
private checkpoints in ignored directories. Do not publish the checkpoints as
part of a code change.

On a Mac, preserve the source archive and create anonymous byte-verified copies:

```sh
python Scripts/HDR/Training/stage_camera_archive.py /private/path/photos.zip \
  .work/private-camera/originals
swiftc -module-cache-path .work/clang-cache -parse-as-library \
  Scripts/HDR/Training/decode_camera.swift -o .work/private-camera/decode-camera
.work/private-camera/decode-camera .work/private-camera/originals/inputs.json \
  .work/private-camera/decoded
python Scripts/HDR/Training/prepare_camera_pairs.py \
  .work/private-camera/decoded .work/private-camera/pairs
```

The decoder needs access to macOS ImageIO's system decoders. A restricted execution
environment may return missing metadata/auxiliary images even when the container
contains a gain map; investigate all-missing results before rejecting the data.
It reads the embedded default SDR and HDR representations, applies orientation,
and draws both into explicit linear-sRGB float bitmaps at a 512px long edge.
Neither representation is independently exposure-normalized. Photos without
readable gain maps, corrupt pairs and numerically identical representations are
excluded. Video is skipped. This measures the camera/system's HDR rendition,
not the original scene's absolute luminance.

Pair preparation groups the same capture day and perceptual hashes within six
bits before assigning approximately 70/15/15 percent to train/validation/test.
This prevents known same-day and visual duplicates crossing splits; it cannot
guarantee every recurring subject is detected. EXIF and original names are omitted
from transferable pairs. Each NPZ contains only encoded RGB, a thumbnail, luminance,
the signed target, a validity mask and dimensions. The manifest carries anonymous
IDs, group/split and integrity hashes. These pixels are still private photos.

For an authorized server, create a **new mode-0700** directory whose name begins
`velyn-private-camera-`, and place a `.private-camera-job` marker inside. Transfer
only a flat `pairs.tar` containing the prepared NPZ files and JSON manifests.
Check its SHA-256 after transfer. The bounded job accepts:

```sh
python Scripts/HDR/Training/run_private_camera_job.py /private/job/workspace \
  --initial /private/path/public-pilot-best.pt --gmnet-source Scripts/Models/gmnet
```

The workspace argument must name that newly created private directory. The
GMNet folder must contain its pinned public `G_realworld.pth` checkpoint.
`train_camera.py` fine-tunes the existing public-data pilot with aligned 256px
crops from 512px pairs, full-image thumbnails, horizontal flips, AdamW and a
fixed 6,000-step schedule. It does not invent HDR labels from the model's own
predictions. Validation selects a checkpoint every 500 steps. The final test is
loaded only after that selection; the selected checkpoint is then frozen.

`run_private_camera_job.py` limits training to 20 minutes and removes the uploaded
archive and unpacked tensors in `finally`, including failure/termination paths.
An uncatchable process/host failure still requires caller cleanup. Download
`results` and `cleanup.json`, then remove the **entire private job directory** and
verify its absence. Do not treat the first cleanup record as proof that weights,
logs and per-image scores were also removed. Training code and pre-existing
public-data experiments may remain on the server.

Run `test_camera_privacy.py` to check archive traversal/link rejection, byte
preservation, anonymous staging and deletion after a failed job, using generated
sentinel bytes only. Report aggregate metrics without photo names, dates, image
hashes or per-image results. A successful fine-tune is still subject to app codec,
color and physical-device acceptance before release.

### Compare fine-tuning the published GMNet

`train_gmnet_camera.py` starts from the pinned published real-world checkpoint
instead of the Velyn synthetic-data pilot. It keeps GMNet's 1,921,827-parameter
architecture and positive 0…log2(5) EV convention. The fixed schedule is 6,000
steps, batch 24, AdamW and a cosine learning rate from 0.00001 to 0.0000005.
The global branch remains FP32 during training; the local branch uses FP16
autocast. Validation and comparison run in FP32.

The local training input is a 128px aligned crop from the 512px proxy, resized to
256px to match the 1024px inference scale. Full-image thumbnails are 256px. This
preserves the published model's expected thumbnail input. The architecture,
capacity, input scale and learning rate differ from the own-model experiment, so
the comparison does not isolate the effect of pretraining alone.

With the same explicitly authorized private workspace and deletion procedure:

```sh
python Scripts/HDR/Training/run_private_camera_job.py /private/job/workspace \
  --trainer gmnet --initial /private/path/G_realworld.pth \
  --gmnet-source Scripts/Models/gmnet
```

The existing 618/132/132 split stays fixed. Checkpoint selection uses only the
132-image validation set. The other 132-image comparison set has already been
examined in earlier work and must not be advertised as fresh final validation.
The initial checkpoint remains eligible if training fails to improve validation.

After recovering results and verifying full server cleanup, use
`convert_tuned_gmnet.py CHECKPOINT OUTPUT` on the Mac for a 1024px Core ML package.
It validates checkpoint provenance, checks the static-kernel conversion against
the original model, retains global FP32/local FP16, and compares CPU_ONLY and
CPU_AND_NE policies on generated inputs. No app model is replaced.

`summarize_gmnet_camera.py GMNET_PRIVATE_ROOT OWN_MODEL_PRIVATE_ROOT OUTPUT_JSON`
checks identical manifests and photo ordering, verifies reproduction of the
untuned GMNet baseline, and exports aggregate paired comparisons and group-level
bootstrap intervals. It excludes private photo IDs and per-image scores.
`test_gmnet_training.py` checks full-precision forward equivalence and gradients
through both branches using synthetic tensors only.

`evaluate_coreml_gmnet.py PACKAGE PAIRS PRIVATE_SCORES OUTPUT_JSON` runs the same
comparison locally on a Mac to check whether Core ML conversion preserves model
quality. It reports aggregate errors and per-image-MAE drift without exporting
photo identities. This is a repeated quality check, not new final validation or
physical iPhone evidence. [Recorded GMNet results](../../../Docs/Evidence/hdr-gmnet-finetune-verification.md).
