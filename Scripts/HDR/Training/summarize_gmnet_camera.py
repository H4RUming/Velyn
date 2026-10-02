"""Compare paired GMNet fine-tuning results with the earlier own-model run.

Exports only aggregate statistics, excluding private image IDs and manifests.
"""
import argparse
import json
from pathlib import Path
import numpy as np


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('gmnet_root',type=Path);p.add_argument('own_root',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args()
    def read(root,path):return json.loads((root/path).read_text())
    report=read(a.gmnet_root,'results/report.json');old_report=read(a.own_root,'results/report.json')
    if report['configuration']['manifestSHA256']!=old_report['configuration']['manifestSHA256']:raise ValueError('Different datasets')
    new=read(a.gmnet_root,'results/private-test-scores.json');old=read(a.own_root,'results/private-test-scores.json')
    if new['rows']!=old['rows']:raise ValueError('Comparison order or split changed')
    initial=np.array([r['maeEV'] for r in new['scores']['pretrainedRaw']])
    previous=np.array([r['maeEV'] for r in old['scores']['gmnetRaw1024']])
    if np.max(np.abs(initial-previous))>1e-4:raise ValueError('Baseline does not reproduce')
    scores={**new['scores'],'ownCameraAdapted':old['scores']['cameraAdapted']}
    group_ids=sorted({r['group'] for r in new['rows']});means={};comparisons={}
    for key,values in scores.items():
        means[key]=np.array([np.mean([v['maeEV'] for i,v in enumerate(values) if new['rows'][i]['group']==g]) for g in group_ids])
    for baseline in ['pretrainedRaw','pretrainedProtectedApprox','ownCameraAdapted']:
        differences=np.array([x['maeEV']-y['maeEV'] for x,y in zip(scores['tunedRaw'],scores[baseline])])
        delta=means['tunedRaw']-means[baseline];rng=np.random.default_rng(20261002)
        bootstrap=delta[rng.integers(len(delta),size=(10000,len(delta)))].mean(1)
        comparisons[baseline]={'meanPhotoDifferenceEV':float(differences.mean()),'meanGroupDifferenceEV':float(delta.mean()),
                               'improvedPhotos':int((differences<0).sum()),'worstRegressionEV':float(differences.max()),
                               'pairedGroupBootstrap95':np.quantile(bootstrap,[.025,.975]).tolist()}
    report['configuration'].pop('manifestSHA256')
    result={'date':'2026-10-02','training':report,'ownCameraModel':old_report['test']['cameraAdapted'],
            'meanGroupMAE':{k:float(v.mean()) for k,v in means.items()},'pairedComparisons':comparisons,
            'baselineReproductionMaxPhotoMAEDifference':float(np.abs(initial-previous).max()),
            'coreML':read(a.gmnet_root,'coreml/conversion.json'),'cleanup':read(a.gmnet_root,'cleanup-final.json'),
            'scope':'Repeated comparison on 132 photos/30 groups. No photos used for training or checkpoint selection from this split, but its results have been examined previously. Not fresh final validation.',
            'limits':['Architecture, capacity, crop/input scale and learning rate differ from the own-model run; this does not isolate pretraining alone.',
                      'Protected outputs approximate app tone policy; no edge-aware enlargement, codec, display or iPhone acceptance.',
                      'Private checkpoints were not published or installed as app defaults.']}
    if (a.gmnet_root/'coreml-camera.json').exists():result['coreMLCameraComparison']=read(a.gmnet_root,'coreml-camera.json')
    a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')
    print(json.dumps({'comparison':report['comparison'],'ownCameraModel':result['ownCameraModel'],'pairedComparisons':comparisons},indent=2))


if __name__=='__main__':main()
