"""Compare actual app renders against the archived v1.1 evaluation fixtures."""
import argparse
import json
from pathlib import Path
import numpy as np
from experiment import load, summarize
from metrics import measure

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('baseline', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('candidates', nargs='+', type=Path)
args = parser.parse_args()
rows = []
for p in sorted(args.baseline.glob('*/prepared.json')):
    old = load(p.parent)
    metrics = {'production/v11': measure(old['renders']['v11'], old['reference'], old['base'])}
    deltas = {}
    for root in args.candidates:
        new = load(root/p.parent.name)
        assert new['meta']['originalPreserved']
        # Repeated Core Image decoding may differ by a few float ULPs.
        base_delta = float(np.max(abs(new['base']-old['base'])))
        reference_delta = float(np.max(abs(new['reference']-old['reference'])))
        assert base_delta < 1e-5 and reference_delta < 1e-5
        metrics[root.name] = measure(new['renders']['v11'], old['reference'], old['base'])
        a = np.maximum(new['renders']['v11'], 1e-8)
        b = np.maximum(old['renders']['v11'], 1e-8)
        deltas[root.name] = {'meanRGBLogDifferenceEV': float(np.mean(abs(np.log2(a/b)))),
                             'baseRepeatMaximum': base_delta, 'referenceRepeatMaximum': reference_delta}
    rows.append({'id': old['meta']['id'], 'metrics': metrics, 'renderDifference': deltas})
args.output.write_text(json.dumps({'protocol': 'Actual app input padding, map storage, gating, and rendering; 15 previously used scenes',
                                  'rows': rows, 'summary': summarize(rows)}, indent=2, allow_nan=False))
print(json.dumps(summarize(rows), indent=2))
