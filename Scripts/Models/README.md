# GMNet Core ML conversion

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
.work/gmnet-venv/bin/python Scripts/Models/convert_gain_map.py /path/to/G_realworld.pth
```

The script checks the checkpoint hash and uses `torch.load(weights_only=True)`.
It converts 1,921,827 parameters to FP16. The 64×64 to 3×3 adaptive pool is replaced
by an equivalent fixed 22×22 / stride 21 pool. No learned weight is retrained.
Inputs are sRGB RGB code values in 0…1: local 512×512 and global 256×256.
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

Model hashes are recorded in `Docs/model-integrity.json`. Current verification
and remaining device checks are described in `Docs/Evidence/gain-map-verification.md`.
