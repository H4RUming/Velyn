"""Exploratory signed-gain residuals. All 15 scenes are now development data.

Each prediction excludes that scene from training. No weights/photos are exported
to the repository; this is cross-validation, not a new independent holdout.
"""
import argparse
import json
import math
from pathlib import Path
import numpy as np
import torch
from experiment import load, learning_tensor, ResidualGain, summarize
from metrics import LUMA, measure


class Residual(torch.nn.Module):
    def __init__(self, signed):
        super().__init__()
        self.layers = ResidualGain().layers
        self.minimum = -2 if signed else 0

    def forward(self, x):
        return (x[:, 3:4] + 1.5 * torch.tanh(self.layers(x))).clamp(self.minimum, math.log2(5))


def train(samples, signed):
    torch.manual_seed(20261001)
    rng = np.random.default_rng(20261001)
    model = Residual(signed)
    optimizer = torch.optim.Adam(model.parameters(), lr=.002)
    items = []
    for s in samples:
        y, ref = s['y'], np.maximum(s['reference'] @ LUMA, 1e-8)
        target = np.log2(ref / y).clip(model.minimum, math.log2(5))
        items.append((learning_tensor(s), torch.tensor(target, dtype=torch.float32)[None, None],
                      torch.tensor((y > .01) & (ref > .01), dtype=torch.float32)[None, None]))
    for _ in range(120):
        batch = [[], [], []]
        for _ in range(4):
            item = items[int(rng.integers(len(items)))]; h, w = item[1].shape[-2:]
            top, left = int(rng.integers(max(1, h-63))), int(rng.integers(max(1, w-63)))
            for bucket, tensor in zip(batch, item): bucket.append(tensor[:, :, top:top+64, left:left+64])
        x, y, mask = [torch.cat(bucket) for bucket in batch]
        pred = model(x)
        loss = ((pred-y).abs()*mask).sum()/mask.sum().clamp_min(1) + .05*(pred-x[:, 3:4]).abs().mean()
        optimizer.zero_grad(); loss.backward(); optimizer.step()
    return model.eval()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixtures', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args(); torch.set_num_threads(4)
    samples = [load(p.parent) for p in sorted(args.fixtures.glob('*/prepared.json'))]
    rows = []
    for i, sample in enumerate(samples):
        training = [s for j, s in enumerate(samples) if i != j]
        assert sample['meta']['id'] not in [s['meta']['id'] for s in training]
        outputs = {'production/v11': sample['renders']['v11']}
        negative = {}
        for signed in [False, True]:
            model = train(training, signed)
            with torch.no_grad(): gain = model(learning_tensor(sample)).numpy()[0, 0]
            name = 'signed' if signed else 'positive'
            outputs[name] = sample['base'] * np.exp2(gain)[..., None]
            negative[name] = float(np.mean(gain < -.02))
        rows.append({'id': sample['meta']['id'], 'trainingIDs': [s['meta']['id'] for s in training],
                     'negativeFraction': negative,
                     'metrics': {name: measure(rgb, sample['reference'], sample['base']) for name, rgb in outputs.items()}})
        args.output.write_text(json.dumps({'protocol': '15-scene exploratory leave-one-scene-out; no fresh holdout',
                                          'rows': rows, 'summary': summarize(rows)}, indent=2, allow_nan=False))
        print(sample['meta']['id'], {k: round(v['maeEV'], 4) for k,v in rows[-1]['metrics'].items()}, flush=True)


if __name__ == '__main__': main()
