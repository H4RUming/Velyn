# Hugging Face model publication

2026-10-02. The user requested publishing the model while keeping photographs
private. The public model repository is
[H4RUming/Velyn-GMNet-Camera-v1](https://huggingface.co/H4RUming/Velyn-GMNet-Camera-v1).
Initial commit: `ae6e989d9e6577b4cf15aa24ce4967c4e6576d3b`.

## Published contents

Exactly 16 uploaded files, plus the Hub's `.gitattributes`:

- FP32 `model.safetensors`, 126 tensors, 1,921,827 parameters, 7,698,196 bytes.
- Two Core ML packages, byte-identical to the 512/1024 packages in Velyn v1.2.
- Original architecture, local inference example, interface configuration,
  requirements, model card, MIT license, attribution and checksums.

Total uploaded file size: 17,710,811 bytes. Safetensors SHA-256:
`8b2d19b71e59ac6c3aa7ad632461e8d7e17d240ced60b29a3577ab98ca186ced`.

Only learned tensors were extracted from the pinned training checkpoint.
No photographs, thumbnails, EXIF, original filenames, capture dates, private
paths, per-photo metrics, optimizer state or full training checkpoint were
uploaded. No private photo dataset was created on Hugging Face. The user's
photos remain in the existing local private storage.

The model card names GMNet as the base, preserves its MIT attribution, describes
the private dataset and repeated comparison protocol, and reports per-photo
regressions and missing physical-device acceptance. It does not imply that
publishing weights provides a formal privacy guarantee or licenses the private
training photographs.

## Verification

- Strict architecture load and exact tensor equality after safetensors round trip.
- Generated 512×512 middle-gray input matches the FP32 reference center value,
  0.9562162757 EV. Rectangular input produces finite, bounded gain at the original
  dimensions. Resampling mixes decoder subpixel phases and is not assumed to be
  identical to the square reference or Core Image preprocessing.
- Generated SDR image loading, invalid-value rejection and the inference CLI pass.
- Hugging Face model-card validation passes with MIT metadata.
- Upload used an explicit file list verified against SHA-256 values. Python cache
  files created while testing were excluded.
- All 16 published files were downloaded without authentication from the pinned
  commit and compared byte-for-byte via SHA-256. Public visibility, MIT metadata
  and absence of unexpected repository files were confirmed.

These checks run on the Mac. No app engine/model change or device benchmark was
introduced by this publication. Existing v1.2 engine and physical installation
results remain as recorded. Preparation sources are in
[Scripts/HuggingFace](../../Scripts/HuggingFace/README.md).
