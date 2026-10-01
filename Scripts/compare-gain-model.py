"""Compare original GMNet with CPU Core ML on tensors from audit-hdr-reference.swift.

Requires the explicit local GMNet PyTorch checkpoint, numpy and torch.
No downloads. Photo-derived tensors/results must remain outside the repository.
"""
from pathlib import Path
import argparse
import json
import sys

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent / "Models" / "gmnet"))
from GMNet import GMNet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("audit_directory", type=Path)
    args = parser.parse_args()
    torch.set_num_threads(4)
    net = GMNet(in_nc=3, out_nc=1, nf=64, nb=16).eval()
    net.load_state_dict(torch.load(args.checkpoint, map_location="cpu", weights_only=True), strict=True)
    root = args.audit_directory
    image = np.fromfile(root / "model-input.f32", dtype=np.float32).reshape(1, 3, 512, 512)
    thumbnail = np.fromfile(root / "thumbnail-input.f32", dtype=np.float32).reshape(1, 3, 256, 256)
    with torch.no_grad():
        _, output = net((torch.from_numpy(image), torch.from_numpy(thumbnail)))
    reference = np.clip(output.numpy(), 0, 1) * np.log2(5)
    converted = np.fromfile(root / "coreml-log-gain.f32", dtype=np.float32).reshape(reference.shape)
    error = np.abs(reference - converted)
    report = {
        "environment": "macOS CPU; original PyTorch weights and CPU Core ML; identical photo tensors",
        "meanAbsoluteErrorEV": float(error.mean()),
        "maxAbsoluteErrorEV": float(error.max()),
        "p99AbsoluteErrorEV": float(np.percentile(error, 99)),
        "referenceMinEV": float(reference.min()),
        "referenceMaxEV": float(reference.max()),
    }
    text = json.dumps(report, indent=2) + "\n"
    (root / "conversion-photo-report.json").write_text(text)
    print(text)
    if not np.isfinite(error).all() or error.max() >= 0.06:
        raise SystemExit("Core ML conversion exceeded the existing 0.06 EV gate")


if __name__ == "__main__":
    main()
