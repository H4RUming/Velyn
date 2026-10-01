"""Local-only audit on existing camera fixtures; never sends photos to a server.

Previously examined scenes are development data, not an untouched test set.
The candidate is a float tensor simulation; current GMNet uses saved app renders.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time
import numpy as np
import torch
import torch.nn.functional as F
from model import SignedGainNet, MIN_EV, MAX_EV
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from experiment import load, gate
from metrics import LUMA, measure


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('checkpoint',type=Path); p.add_argument('fixtures',type=Path)
    p.add_argument('current',type=Path); p.add_argument('output',type=Path)
    a=p.parse_args(); torch.set_num_threads(4)
    state=torch.load(a.checkpoint,map_location='cpu',weights_only=True)
    model=SignedGainNet(state['metadata']['width']).eval(); model.load_state_dict(state['model'])
    records=[]
    for path in sorted(a.fixtures.glob('*/prepared.json')):
        sample=load(path.parent); m=sample['meta']; h,w=m['height'],m['width']; shape=sample['y'].shape
        image=np.fromfile(path.parent/'source-srgb.f32',np.float32).reshape(h,w,4)[...,:3]
        source=torch.from_numpy(image.transpose(2,0,1).copy())[None].clamp(0,1)
        thumb=F.interpolate(source,size=(128,128),mode='bilinear',align_corners=False)
        size=(max(2,round(512*h/max(h,w)/2)*2),max(2,round(512*w/max(h,w)/2)*2))
        resized=F.interpolate(source,size=size,mode='bicubic',align_corners=False).clamp(0,1)
        dh,dw=512-size[0],512-size[1]; pads=(dw//2,dw-dw//2,dh//2,dh-dh//2)
        inp=F.pad(resized,pads,mode='replicate')
        started=time.perf_counter()
        with torch.no_grad():
            g=model(inp,thumb)[:,:,pads[2]:pads[2]+size[0],pads[0]:pads[0]+size[1]]
            g=F.interpolate(g,size=shape,mode='bilinear',align_corners=False).numpy()[0,0]
        elapsed=time.perf_counter()-started
        base,reference=sample['base'],sample['reference']; y=sample['y']; ry=np.maximum(reference@LUMA,1e-8)
        target=np.log2(ry/y); valid=(y>.01)&(ry>.01)
        current=np.fromfile(a.current/path.parent.name/'v11.f32',np.float32).reshape(*shape,4)[...,:3]
        protected=np.clip(g*.75*gate(y,'adaptive',m['protectionBlend']),-2,2)
        outputs={'SDR':base,'currentGMNet':current,'signedRaw':base*np.exp2(g)[...,None],
                 'signedProtected':base*np.exp2(protected)[...,None],
                 'boundedScalarOracle':base*np.exp2(target.clip(MIN_EV,MAX_EV))[...,None]}
        negative=valid&(target<-.05); predicted=valid&(g<-.05)
        records.append({'id':path.parent.name,'secondsCPU':elapsed,
                        'metrics':{k:measure(v,reference,base) for k,v in outputs.items()},
                        'negative':{'targetFraction':float(negative.sum()/valid.sum()),
                                    'predictedFraction':float(predicted.sum()/valid.sum()),
                                    'precision':float((negative&predicted).sum()/max(1,predicted.sum())),
                                    'recall':float((negative&predicted).sum()/max(1,negative.sum()))}})
    if not records: raise ValueError('No prepared camera fixtures')
    summary={}
    for key in records[0]['metrics']:
        errors=np.array([r['metrics'][key]['maeEV'] for r in records])
        baseline=np.array([r['metrics']['currentGMNet']['maeEV'] for r in records])
        summary[key]={'meanMAE_EV':float(errors.mean()),'improvedScenes':int((errors<baseline-1e-6).sum()),
                      'worstRegressionEV':float((errors-baseline).max()),
                      'meanBaseColorShift':float(np.mean([r['metrics'][key]['baseColorShift'] for r in records]))}
    result={'scope':'Local macOS CPU; 15 previously used camera scenes, not fresh validation. Candidate float simulation, baseline actual app 1024px NE render. No export or device display claim.',
            'checkpointSHA256':hashlib.sha256(a.checkpoint.read_bytes()).hexdigest(),'summary':summary,'samples':records}
    a.output.write_text(json.dumps(result,indent=2)+'\n'); print(json.dumps(summary,indent=2))


if __name__=='__main__': main()
