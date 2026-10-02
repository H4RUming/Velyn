"""Aggregate two private prepare.swift runs without publishing photo identifiers."""
import argparse
import json
from pathlib import Path

import numpy as np
from metrics import measure


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('original', type=Path)
    parser.add_argument('camera', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    inputs = json.loads(args.manifest.read_text())
    variants = {
        'originalDefaults': (args.original, 'default'),
        'originalDirect': (args.original, 'full-bilinear'),
        'cameraOldProtection': (args.camera, 'v11'),
        'cameraDefault': (args.camera, 'default'),
        'cameraEdgeAware': (args.camera, 'full-edge'),
    }
    scores = {key: [] for key in variants}
    decode_delta = 0.0
    for row in inputs:
        identifier = row['id']
        if not identifier or not all(c.isascii() and (c.isalnum() or c in '-_') for c in identifier):
            raise ValueError('Invalid identifier')
        new, old = args.camera / identifier, args.original / identifier
        metadata = json.loads((new / 'prepared.json').read_text())
        previous = json.loads((old / 'prepared.json').read_text())
        if not metadata['originalPreserved'] or not previous['originalPreserved']:
            raise ValueError('Original integrity failed')
        shape = (metadata['sampleHeight'], metadata['sampleWidth'], 4)
        def pixels(path):
            result = np.fromfile(path, dtype=np.float32).reshape(shape)[..., :3]
            if not np.isfinite(result).all():
                raise ValueError('Non-finite pixels')
            return result
        base, reference = pixels(new / 'base.f32'), pixels(new / 'reference.f32')
        for name, value in [('base.f32', base), ('reference.f32', reference)]:
            delta = float(np.max(np.abs(value - pixels(old / name))))
            decode_delta = max(decode_delta, delta)
            if delta > 1e-6:
                raise ValueError('Unaligned source decodes')
        for key, (directory, variant) in variants.items():
            scores[key].append(measure(pixels(directory / identifier / (variant + '.f32')), reference, base))
    keys = ['maeEV', 'p95EV', 'puPSNR', 'puSSIM', 'uvError', 'baseColorShift', 'meanRatio']
    report = {
        'scope': 'macOS Core Image/Core ML actual engine; previously examined private comparison photos; not fresh validation or iPhone display/performance evidence',
        'photos': len(inputs), 'groups': len({row['group'] for row in inputs}),
        'originalsBytePreserved': True, 'maxRepeatedDecodeDifference': decode_delta,
        'metrics': {key: {metric: float(np.mean([row[metric] for row in values])) for metric in keys}
                    for key, values in scores.items()},
        'comparisons': {},
    }
    for key in ['originalDefaults', 'originalDirect', 'cameraOldProtection']:
        differences = np.array([a['maeEV'] - b['maeEV'] for a, b in zip(scores['cameraDefault'], scores[key])])
        report['comparisons'][key] = {
            'improvedPhotos': int((differences < 0).sum()),
            'meanDifferenceEV': float(differences.mean()),
            'worstIncreaseEV': float(differences.max()),
        }
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')


if __name__ == '__main__':
    main()
