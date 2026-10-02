# Fine-tuning the published GMNet

2026-10-02. **Fine-tuned GMNet has the lowest mean luminance error in this
comparison.** It improves over both the published weights and the camera-adapted
Velyn CNN. The candidate remains private research output; the app's bundled
model and release are unchanged.

## Fixed comparison

The user authorized another server run on the same camera collection. The
882 prepared pairs and their capture-day/perceptual-hash groups were unchanged:
618 training images, 132 validation images and 132 comparison images. Checkpoint
selection uses only validation. The comparison images were not used for training,
but their results had already been examined in previous experiments. This is a
repeated comparison, **not fresh final validation**.

Starting weights are the published GMNet real-world checkpoint, SHA-256
`83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f`.
The [original MIT architecture](../../Scripts/Models/gmnet/GMNet.py), attribution,
1,921,827 parameters and positive 0…log2(5) EV output are retained. No attenuation
head, negative labels or new architecture was added.

All parameters are fine-tuned with AdamW, batch 24 and a fixed 6,000-step cosine
schedule from 0.00001 to 0.0000005. The global kernel/channel/headroom branch stays
FP32; local operators use FP16 autocast. The loss is masked Smooth L1 in EV plus
a small spatial-gradient term. Negative reference gains are clamped to zero for
this positive-only training objective; evaluation still uses the complete signed
reference, so unsupported negative targets are not hidden from the score.

A 128px crop from the 512px proxy is resized to 256px for training, matching the
effective scale of 1024px inference. The global thumbnail depicts the complete
image at 256px. Horizontal flips preserve pair alignment. The architecture,
capacity, input scale and learning rate differ from the own-model experiment, so
this is a practical model comparison rather than an isolation of pretraining alone.

The run used an RTX PRO 6000 Blackwell Workstation Edition, Torch 2.7.0+cu128.
Training plus periodic validation/checkpoint writes took **297.08 seconds**,
excluding transfer, data loading, initial validation and comparison inference.
Validation selected **step 4,500**, with mean error **0.265823 EV**. The selected
checkpoint was frozen before comparison. No retuning followed comparison results.

## Results on the same 132 photos / 30 capture groups

Lower mean absolute log-luminance error is better. All primary rows apply the
predicted scalar gain directly. Photo means weight every photo equally; group
means give each capture group equal weight.

| Predictor | Mean photo error EV | Mean group error EV |
| --- | ---: | ---: |
| Published GMNet, 1024px | 0.487931 | 0.455463 |
| Camera-adapted Velyn CNN, 512px | 0.349993 | 0.378250 |
| **Fine-tuned GMNet, 1024px** | **0.327842** | **0.346991** |

Fine-tuned GMNet reduces photo-weighted mean error by **32.8%** versus the
published checkpoint and **6.3%** versus the own model. It improves 95/132 photos
over published GMNet and 93/132 over the own model. It still regresses on some
photos: the largest increases are 0.5015 EV and 0.3973 EV respectively.

The paired bootstrap over capture groups gives these 95% error-difference
intervals (fine-tuned minus comparison):

- Published GMNet: −0.2101…−0.0013 EV.
- Own model: −0.0617…−0.0078 EV.

These are within-collection intervals on an already examined comparison set, not
proof of broad camera or user generalization. Reproduction of the untuned
baseline and identical private manifest/photo ordering are checked by the
[aggregate summarizer](../../Scripts/HDR/Training/summarize_gmnet_camera.py).

## Existing postprocessing reduces the benefit

The current-style 75% strength, adaptive midtone protection and 2 EV cap were also
applied in tensor code, with bilinear map enlargement:

| Predictor with approximate protection | Mean photo error EV |
| --- | ---: |
| Published GMNet | 0.635414 |
| Fine-tuned GMNet | 0.586878 |

This is substantially worse than the fine-tuned model's direct 0.327842 EV result.
The learned gain already targets native camera HDR. Applying the existing
protective reduction again suppresses gains needed to match that reference.
That interpretation follows from the paired ablation; it does not establish that
protection should be removed for every photo or user-selected effect strength.

The tensor approximation excludes app edge-aware enlargement, full-resolution
export, codec behavior and actual HDR display. A weight-only replacement while
leaving all existing defaults untouched would not reproduce the direct-model
result. Model choice and default postprocessing need to be validated together.

## Privacy, checks and adoption limits

Only the already authorized, anonymized pixel pairs were uploaded, to a new
mode-0700 private server directory. Transfer SHA-256 matched. The job removed its
uploaded archive and extracted tensors automatically after training/evaluation.
Results were copied to the Mac and every returned file's SHA-256 was compared
with the server copy. The entire private workspace was then deleted, including
private weights, per-photo scores and logs, and absence was verified. Original
photos and trained candidate weights remain local and outside Git.

Two synthetic GMNet tests pass: full-precision training-forward equivalence to
the original model, including two-item batches, and finite nonzero gradients in
both local and global branches. The four archive/privacy tests also pass after
adding an explicit `--trainer gmnet` choice to the bounded cleanup runner.
Python syntax checks pass. No engine code was changed or engine acceptance rerun.

The conversion tool preserves the existing static-kernel implementation and
FP32-global/FP16-local policy, retains the original license, and writes to an
explicit research output directory. The 1024px Core ML package is **4,995,828
bytes** (about 4.76 MiB). Static-kernel forward equivalence on six generated inputs
has a maximum error of 0.00000036 EV. Against original FP32 PyTorch, six generated
inputs pass both CPU_ONLY and CPU_AND_NE policies; worst pixel differences are
0.02804 and 0.05662 EV respectively. The latter occurs on a uniform white input
and approaches the pre-existing 0.06 EV conversion tolerance.

That difference justified checking whether conversion preserves the measured
quality gain on actual photos. All 132 comparison photos were run **locally**
through Core ML with CPU_AND_NE requested. Mean error is **0.327723 EV**, versus
PyTorch's 0.327842 EV. The largest absolute change in any photo's MAE is 0.006685
EV. This checks stability of the quality metric, not pixelwise equivalence on
those photos. The improvement survives conversion on this collection.

Median prediction time is 0.1045 seconds and the 95th percentile is 0.1123 seconds
on the Apple M2 Mac, with first-image warmup excluded. These measure model
prediction only, not image loading or full editing latency. No private images were
reuploaded for this check. A requested CPU_AND_NE policy does not establish the
placement of every operator. None of these results establishes iPhone performance,
thermal behavior, HDR display quality or export acceptance.

The result supports testing this candidate next with calibrated app defaults and
new camera scenes. Remaining reasons to withhold production adoption are per-photo
regressions, repeated use of the comparison set and missing device/display/codec
validation. Absence of negative gain is not by itself an HDR failure.

[Aggregate evidence](hdr-gmnet-finetune-results.json) ·
[Training and reproduction](../../Scripts/HDR/Training/README.md#compare-fine-tuning-the-published-gmnet)
