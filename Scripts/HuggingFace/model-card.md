---
license: mit
library_name: pytorch
pipeline_tag: image-to-image
tags:
  - hdr
  - gain-map
  - inverse-tone-mapping
  - coreml
  - image-to-image
  - fine-tuned
---

# Velyn GMNet Camera v1

A camera-adapted version of [GMNet](https://github.com/qtlark/GMNet), trained to
predict a scalar gain map for expanding an SDR photo into HDR. This is the model
bundled in [Velyn v1.2](https://github.com/H4RUming/Velyn/releases/tag/v1.2.0).

Velyn fine-tuned the published GMNet real-world weights. The architecture and
1,921,827 parameters are unchanged. Output is positive scalar log2 gain in
**0…log2(5) EV**, equivalent to **1…5×** linear brightness. This model does not
predict dimming, recover clipped detail, or reconstruct known scene luminance.

## Files

- `model.safetensors`: FP32 learned tensors only; no optimizer state or training records.
- `GMNet.py`, `arch_util.py`: original MIT architecture with Velyn's local import cleanup.
- `inference.py`: local PyTorch reference inference for an sRGB image.
- `coreml/VelynGainMap.mlpackage`: 512px local input, 256px thumbnail.
- `coreml/VelynGainMap1024.mlpackage`: 1024px local input, 256px thumbnail.
- `config.json`, `SHA256SUMS.txt`, `LICENSE`, `NOTICE`: interface, integrity and attribution.

The Core ML packages are identical to those in Velyn v1.2. Their global branch
uses FP32 and local operators use FP16. Equivalent fixed pooling and static kernel
operators improve accelerator compatibility. Deployment target is iOS 18 or later
for these model packages; Velyn itself requires iOS 27 because of other app APIs.

## Use locally

Download this repository, then run:

```sh
python -m pip install torch safetensors numpy Pillow
python inference.py input.jpg gain.npy --size 1024
```

`gain.npy` is a float32 `[height, width]` array in **EV**, not a finished HDR photo.
The example reads an SDR raster, applies EXIF orientation, and converts an embedded
ICC profile to sRGB. Untagged input is assumed to be sRGB. It does not decode RAW,
extract the SDR base from native HDR files, or preserve alpha in this example.
Only use an SDR base as model input.

The predictor expects encoded sRGB RGB floats in `[0,1]`. It preserves aspect ratio,
centers the local image with edge padding, and resizes the complete image to a
256×256 global thumbnail. The returned map is cropped and bilinearly enlarged to
the original dimensions. The Python example uses PyTorch resampling and does not
claim bit-identical Core Image preprocessing or app output.

Apply gain to **linear-light RGB**, equally in all three channels:

```python
# rgb_srgb: float RGB in [0,1]; log_gain: scalar EV map at the same resolution
linear = np.where(rgb_srgb <= 0.04045,
                  rgb_srgb / 12.92,
                  ((rgb_srgb + 0.055) / 1.055) ** 2.4)
hdr_linear = linear * np.exp2(log_gain)[..., None]
```

Do not clip `hdr_linear` to 1 or save it as an ordinary 8-bit image and expect HDR.
A suitable HDR encoder and display path are needed. For Core ML, use the named
`image` and `thumbnail` inputs and `log_gain` output documented in `config.json`.
The output is already EV; do not multiply it by log2(5) again. Single-channel
Core Image Rf maps must be broadcast to RGB before multiplication.

Velyn requests CPU + Neural Engine where available, checks two synthetic outputs
against pinned FP32 references, and falls back if calibration fails. The model
package alone does not guarantee correct or complete Neural Engine placement.
The app's calibration and renderer are available in the linked source repository.

## Training and provenance

- Base: `qtlark/GMNet`, revision `59db6aac16f8fa7071a9447e357d9e7316ce0f8c`,
  `checkpoints/G_realworld.pth`.
- Original checkpoint SHA-256:
  `83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f`.
- Private, user-authorized camera collection: 882 readable native HDR/SDR pairs;
  618 training, 132 validation and 132 comparison photos.
- Capture-day and perceptual-hash grouping produced 50/29/30 groups respectively.
- AdamW, batch 24, 6,000 steps, cosine learning rate 1e-5 to 5e-7.
- Validation selected step 4,500. The global branch stayed FP32 during training;
  local operations used FP16 autocast. Loss combines masked Smooth L1 in EV and
  a spatial-gradient term. Negative target gain was clamped to zero for training.
- Source training checkpoint SHA-256:
  `cc92ee36615c30e4b076215e6bffaba551e3b6351f86174aed8da1e5ed3bcf41`.
  This differs from the exported safetensors hash because the serialization differs.

**Training photographs are private and are not uploaded to this repository,
including as a private dataset.** No thumbnails, EXIF, capture dates, original
filenames, private paths, per-photo metrics, or full training checkpoint are
included. Only learned tensors and explicitly listed public inference assets are
released. Private photos are not required to use the model. Exact retraining is
not reproducible without the private dataset. No formal privacy or memorization
guarantee has been established for the released weights.

[Training code and methodology](https://github.com/H4RUming/Velyn/tree/v1.2.0/Scripts/HDR/Training)

## Evaluation

Photo-weighted mean absolute log-luminance error on the same 132 comparison
photos, using direct scalar predictions (lower is better):

| Model | Mean error, EV |
| --- | ---: |
| Published GMNet, 1024px | 0.487931 |
| Separate Velyn CNN, camera-adapted, 512px | 0.349993 |
| **This fine-tuned GMNet, 1024px PyTorch** | **0.327842** |
| This fine-tuned GMNet, 1024px Core ML | 0.327723 |

Comparison images were excluded from training and checkpoint selection, but their
results had been examined in earlier experiments. **This is a repeated comparison,
not independent final validation.** The model improves 95/132 photos over the
published weights and regresses on 37; the largest error increase is 0.5015 EV.

The actual app engine was also checked on eight photos from that set. New model
and defaults reduced mean error from 0.469327 to 0.285350 EV, but two photos
regressed, with a worst increase of 0.624240 EV. The average per-photo brightness
ratio was 1.1694, so over-bright results remain possible. The two protocols differ;
their numbers must not be combined.

Applying the older 75%-strength/midtone-protection defaults suppresses gains the
model learned to predict. For new maps, Velyn uses 100% strength, a 5× ceiling,
no midtone protection, and bilinear enlargement. Protection remains a user option.
A 5× ceiling does not mean that every pixel receives 5× gain.

Measurements were made on an Apple M2 Mac. Core ML prediction-only median latency
was 0.1045 seconds at 1024px on the repeated comparison set, with CPU + Neural
Engine requested. This is not iPhone end-to-end latency or proof of all-NE execution.

[Full experiment and limitations](https://github.com/H4RUming/Velyn/blob/v1.2.0/Docs/Evidence/hdr-gmnet-finetune-verification.md)
· [App integration checks](https://github.com/H4RUming/Velyn/blob/v1.2.0/Docs/Evidence/hdr-camera-integration.md)

## Intended use and limits

Local photo-editing experiments and user-controlled SDR-to-HDR expansion.
Results are predictions and may be too bright or differ from native HDR.
The private camera collection does not establish generalization across cameras,
subjects or lighting. Physical HDR display fidelity and sustained device thermal
behavior are not validated. Do not interpret output as measured scene radiance.
The Hub download is for local inference; publishing the model does not add a
server dependency or photo uploads to the Velyn app.

## License and credit

MIT, retaining **Copyright (c) 2025 Yinuo Liao**. Velyn's fine-tuning, conversion
and inference additions are also MIT. See `LICENSE` and `NOTICE`. This license
covers the released artifacts; private training photos are not licensed or
redistributed through this repository.

```bibtex
@inproceedings{Liao_2025_ICLR,
  title = {Learning Gain Map for Inverse Tone Mapping},
  author = {Yinuo Liao and Yuanshen Guan and Ruikang Xu and Jiacheng Li and Shida Sun and Zhiwei Xiong},
  booktitle = {The Thirteenth International Conference on Learning Representations},
  year = {2025}
}
```
