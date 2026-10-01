"""Publish numeric evidence only; input tensors and photos stay in private storage."""
import argparse
import json
from pathlib import Path
import statistics

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('models', type=Path); parser.add_argument('results', type=Path); parser.add_argument('output', type=Path)
args = parser.parse_args()
benchmarks = {}
for name in ['mac-backends', 'mac-backends1024', 'mac-static512', 'mac-precise512', 'mac-precise1024']:
    report = json.loads((args.models/(name+'.json')).read_text())
    rows = []
    for row in report['results']:
        result = {k: row[k] for k in ['backend','size','loadSeconds','preferredOperationCounts','estimatedCostByDevice','thermalStart','thermalEnd'] if k in row}
        result['inputs'] = [{k: m[k] for k in ['pattern','finite','warmupSeconds','seconds','maxErrorEV','meanErrorEV','samples']} for m in row.get('measurements', [])]
        result['medianSeconds'] = statistics.median(t for m in result['inputs'] for t in m['seconds'])
        if 'error' in row: result['error'] = row['error']
        rows.append(result)
    benchmarks[name] = rows
quality = json.loads((args.results/'accelerated.json').read_text())
signed = json.loads((args.results/'signed-cross-validation.json').read_text())
output = {'environment': 'Apple M2, macOS 27.0 (26A428), Core ML; no iPhone timing or power measurements',
          'timingProtocol': 'Two generated inputs, one warmup then three synchronous predictions each; load/warmup separate. Small-run timing, no power or sustained thermal claims.',
          'benchmarks': benchmarks, 'quality': quality,
          'signedExperiment': {'protocol': signed['protocol'], 'summary': signed['summary'],
                               'rows': [{'id':r['id'],'negativeFraction':r['negativeFraction'],
                                         'maeEV':{k:v['maeEV'] for k,v in r['metrics'].items()}} for r in signed['rows']]}}
args.output.write_text(json.dumps(output, indent=2, allow_nan=False)+'\n')
