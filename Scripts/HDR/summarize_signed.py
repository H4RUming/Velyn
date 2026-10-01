"""Publish only numeric signed-model evidence; never copy image tensors or paths."""
import argparse
import json
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('comparison',type=Path); parser.add_argument('roundtrip',type=Path); parser.add_argument('output',type=Path)
    args=parser.parse_args()
    quality=json.loads(args.comparison.read_text()); codec=json.loads(args.roundtrip.read_text())
    keys=['maeEV','p95EV','puPSNR','puSSIM','uvError','baseColorShift']
    report={'environment':'Apple M2 / macOS 27 / PyTorch 2.7 CPU, four threads / Core Image and ImageIO; not iPhone evidence',
            'protocol':quality['protocol'],'hdrunetInterpretation':quality['hdrunetInterpretation'],
            'parameters':quality['parameters'],'summary':quality['summary'],
            'scenes':[{'id':r['id'],'metrics':{name:{k:m[k] for k in keys} for name,m in r['metrics'].items()},
                       'diagnostics':r['diagnostics']} for r in quality['rows']],
            'codecs':codec}
    args.output.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')


if __name__=='__main__':main()
