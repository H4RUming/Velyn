"""Build an explicit public inference package; never copy a training directory."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys

import torch
from safetensors.torch import save_file, load_file

ROOT = Path(__file__).resolve().parents[2]
CHECKPOINT_SHA = 'cc92ee36615c30e4b076215e6bffaba551e3b6351f86174aed8da1e5ed3bcf41'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Use a new output directory; existing files are never uploaded implicitly')
    if hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() != CHECKPOINT_SHA:
        raise ValueError('Unexpected checkpoint')
    source = torch.load(args.checkpoint, map_location='cpu', weights_only=True)
    sys.path.insert(0, str(ROOT / 'Scripts/Models/gmnet'))
    from GMNet import GMNet
    net = GMNet(in_nc=3, out_nc=1, nf=64, nb=16)
    net.load_state_dict(source['model'], strict=True)
    weights = {key: value.detach().cpu().float().contiguous() for key, value in net.state_dict().items()}
    if not all(torch.isfinite(value).all() for value in weights.values()):
        raise ValueError('Non-finite tensors')
    args.output.mkdir(parents=True)
    save_file(weights, str(args.output / 'model.safetensors'), metadata={'format': 'pt'})
    restored = load_file(str(args.output / 'model.safetensors'))
    if set(weights) != set(restored) or not all(torch.equal(weights[k], restored[k]) for k in weights):
        raise ValueError('Weight round trip failed')
    explicit_files = {
        'README.md': ROOT / 'Scripts/HuggingFace/model-card.md',
        'inference.py': ROOT / 'Scripts/HuggingFace/inference.py',
        'GMNet.py': ROOT / 'Scripts/Models/gmnet/GMNet.py',
        'arch_util.py': ROOT / 'Scripts/Models/gmnet/arch_util.py',
        'LICENSE': ROOT / 'Scripts/Models/gmnet/LICENSE',
    }
    for name, source_path in explicit_files.items():
        shutil.copyfile(source_path, args.output / name)
    (args.output / 'NOTICE').write_text(
        'GMNet: Copyright (c) 2025 Yinuo Liao. MIT License; see LICENSE.\n'
        'Source: https://github.com/qtlark/GMNet\n'
        'Revision: 59db6aac16f8fa7071a9447e357d9e7316ce0f8c\n'
        'Velyn fine-tuning, conversion and inference additions: Copyright (c) 2026 Velyn contributors. MIT.\n'
        'Source: https://github.com/H4RUming/Velyn\n'
        'The private training dataset is not included or licensed by this release.\n')
    (args.output / 'requirements.txt').write_text('torch>=2.7\nsafetensors>=0.4\nnumpy>=1.26\nPillow>=10\n')
    config = {
        'model_name': 'Velyn-GMNet-Camera-v1', 'architecture': 'GMNet',
        'in_nc': 3, 'out_nc': 1, 'nf': 64, 'nb': 16, 'parameters': sum(v.numel() for v in net.parameters()),
        'input': {'image': 'float32 NCHW encoded sRGB [0,1], batch=1, RGB, local 512 or 1024 square, centered edge padding',
                  'thumbnail': 'float32 [1,3,256,256] encoded sRGB [0,1], full image resized to square'},
        'output': {'name': 'log_gain', 'units': 'log2 brightness ratio in EV', 'minimum': 0, 'maximum': 2.321928094887362,
                   'shape': '[1,1,local_size,local_size]', 'application': 'Multiply linear-light RGB by exp2(EV), equally across RGB'},
        'pytorch_forward': 'The original model returns (out,qmax*out). Clamp the second tensor to [0,1], then multiply by log2(5).',
        'coreml_forward': 'The named log_gain output is already bounded EV. Do not scale it again.',
        'source_checkpoint_sha256': CHECKPOINT_SHA, 'app_release': 'v1.2.0',
    }
    (args.output / 'config.json').write_text(json.dumps(config, indent=2) + '\n')
    integrity = json.loads((ROOT / 'Docs/model-integrity.json').read_text())['gmnet']['sha256']
    for name in ['VelynGainMap.mlpackage', 'VelynGainMap1024.mlpackage']:
        for relative, digest in integrity.items():
            if relative.startswith(name + '/'):
                path = ROOT / 'Velyn/Models' / relative
                if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    raise ValueError('Core ML integrity mismatch')
                target = args.output / 'coreml' / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
    # Hash every explicitly staged file. The uploader consumes only this list.
    files = sorted(path for path in args.output.rglob('*') if path.is_file())
    lines = [f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.relative_to(args.output).as_posix()}' for path in files]
    (args.output / 'SHA256SUMS.txt').write_text('\n'.join(lines) + '\n')
    print(json.dumps({'files': len(files) + 1, 'parameters': config['parameters'],
                      'learnedTensors': len(weights), 'identicalWeightRoundTrip': True,
                      'bytes': sum(path.stat().st_size for path in args.output.rglob('*') if path.is_file())}))


if __name__ == '__main__':
    main()
