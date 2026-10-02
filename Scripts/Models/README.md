# GMNet Core ML conversion

## Current bundled model

The app bundles `gmnet-camera-v1`: the published GMNet architecture fine-tuned on
user-authorized camera HDR/SDR pairs. The selected step-4500 checkpoint has SHA-256
`cc92ee36615c30e4b076215e6bffaba551e3b6351f86174aed8da1e5ed3bcf41`.
Only the converted 512/1024 packages are distributed. Private photos, manifests,
and the PyTorch training checkpoint stay outside the repository. Exact retraining
is therefore not possible from the public repository alone.

Use `Scripts/HDR/Training/convert_tuned_gmnet.py CHECKPOINT OUTPUT --size 512`
(and `--size 1024`) with that checkpoint to reproduce the conversion. Copy each
`GMNetCamera.mlpackage` to the corresponding bundled `VelynGainMap` package.
`calibrate_gain.py CHECKPOINT` reproduces the pinned FP32 calibration samples.
The runtime selects references by checkpoint provenance and rejects unknown
models; the original published model remains supported for explicit comparisons.
See [integration evidence](../../Docs/Evidence/hdr-camera-integration.md).

## Original published baseline

The following instructions reproduce the earlier, untuned baseline. Running them
with their default output replaces the current bundle with that baseline.

The app includes the converted model; Python and a server are not needed at runtime.

- Source: https://github.com/qtlark/GMNet/tree/59db6aac16f8fa7071a9447e357d9e7316ce0f8c
- Checkpoint: `checkpoints/G_realworld.pth` from that revision.
- Checkpoint SHA-256: `83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f`.
- MIT license is preserved in `gmnet/LICENSE` and the app notices.
- Tested conversion environment: macOS, Python 3.12, torch 2.7.0, coremltools 9.0, numpy 1.26.4.

After downloading the pinned checkpoint explicitly, run from the repository root:

```sh
python3 -m venv .work/gmnet-venv
.work/gmnet-venv/bin/pip install torch==2.7.0 coremltools==9.0 numpy==1.26.4
.work/gmnet-venv/bin/python Scripts/Models/convert_gain_map.py /path/to/G_realworld.pth \
  --precise-global --static-kernel
```

The script checks the checkpoint hash and uses `torch.load(weights_only=True)`.
It keeps the global thumbnail branch in FP32 and the local branch in FP16.
The parameter count remains 1,921,827. A fully FP16 conversion produced a large
Neural Engine error in the global branch on the tested M2. The dynamic depthwise
convolution is expressed as nine static slices, channel multiplications and a sum.
The 64×64 to 3×3 adaptive pool becomes an equivalent fixed 22×22 / stride 21 pool.
Both rewrites are compared against PyTorch; no learned weight is retrained.
Inputs are sRGB RGB code values in 0…1: local 512×512 or 1024×1024 and global 256×256.
The local image preserves aspect ratio with edge padding; the global thumbnail
is resized to a square, matching the original model's conditioning input.
The returned normalized log gain is multiplied by log2(5), as required by the
real-world dataset normalization, then bounded to 0…log2(5). Negative gain is
intentionally excluded for an expansion control. Core ML can round slightly
above the bound; the app clamps again before saving the map.

The conversion compares PyTorch and Core ML on a seeded random input and
constant black, middle gray and white. These are numerical conversion checks,
not photographic quality evaluation. The application uses the sRGB transfer
function through Core Image; the research rendering example uses gamma 2.2.
This difference and the bounded gain require real-photo/display evaluation.

At runtime the app tries CPU + Neural Engine, then GPU, then CPU. Two generated
inputs must match pinned PyTorch reference samples before a backend is cached.
This requests eligible Neural Engine execution; it does not force all operations
onto that device. `MLComputePlan` diagnostics record the actual planned split.
Use `calibrate_gain.py CHECKPOINT` to regenerate the reference numbers.

The bundled 1024 variant uses the same conversion with `--size 1024` and
`--output Velyn/Models/VelynGainMap1024.mlpackage`. It is selected for originals
at least 1024 pixels on the long edge when a Neural Engine is present and its
calibration passes. Failure falls back to the 512 model; 1024 is not retried
on GPU or CPU. Smaller originals and CPU-only devices use 512.

Model hashes are recorded in `Docs/model-integrity.json`. Current verification
and remaining device checks are described in `Docs/Evidence/gain-map-verification.md`.
