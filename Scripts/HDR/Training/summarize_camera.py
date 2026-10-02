"""Export aggregate research evidence, excluding photo identities and pixels."""
import argparse
import json
from pathlib import Path
import numpy as np


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('private_root',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();root=a.private_root
    def read(path):return json.loads((root/path).read_text())
    report=read('results/report.json');report['configuration'].pop('manifestSHA256',None)
    private=read('results/private-test-scores.json');groups=sorted({r['group'] for r in private['rows']});scores=private['scores'];comparisons={}
    for baseline in ['gmnetRaw1024','gmnetProtectedApprox','syntheticPilot']:
        delta=np.array([np.mean([scores['cameraAdapted'][i]['maeEV']-scores[baseline][i]['maeEV'] for i,row in enumerate(private['rows']) if row['group']==g]) for g in groups])
        rng=np.random.default_rng(20261002)
        bootstrap=delta[rng.integers(len(delta),size=(10000,len(delta)))].mean(1)
        comparisons[baseline]={'meanGroupDifferenceEV':float(delta.mean()),'bootstrap95':np.quantile(bootstrap,[.025,.975]).tolist(),
                               'improvedImages':sum(x['maeEV']<y['maeEV'] for x,y in zip(scores['cameraAdapted'],scores[baseline])),
                               'worstImageRegressionEV':max(x['maeEV']-y['maeEV'] for x,y in zip(scores['cameraAdapted'],scores[baseline]))}
    result={'date':'2026-10-02','dataset':read('pairs/summary.json'),'trainingAndTest':report,
            'pairedComparisons':comparisons,'coreML':read('coreml/conversion.json'),
            'legacyDevelopmentAudit':read('legacy-audit.json')['summary'],
            'cleanup':read('cleanup-final.json'),
            'limitations':['Single-owner camera collection; capture-day and pHash grouping are heuristics.',
                           'GMNet protected baseline is a tensor approximation, not the full app pipeline.',
                           'Legacy 15-scene audit is exploratory; overlap with the new collection was not ruled out.',
                           'No physical-device display, thermal, or export acceptance; candidate not bundled.']}
    if (root/'attenuation-context.json').exists():result['attenuationContext']=read('attenuation-context.json')
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')


if __name__=='__main__':main()
