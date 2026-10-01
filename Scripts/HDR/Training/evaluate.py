"""One frozen, scene-disjoint synthetic test after validation selection.

The GMNet comparison uses its published weights and 512px input without app
protection. These are synthetic luminance targets, not native camera quality.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import numpy as np
import torch
import torch.nn.functional as F
from model import SignedGainNet, MAX_EV
from pairs import make_pairs
from train import load_split, statistics


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('data',type=Path); p.add_argument('checkpoint',type=Path); p.add_argument('output',type=Path)
    p.add_argument('--gmnet-source',type=Path,required=True); p.add_argument('--gmnet-weights',type=Path,required=True)
    a=p.parse_args(); torch.set_num_threads(4)
    raw=(a.data/'manifest.json').read_bytes(); manifest=json.loads(raw)
    checkpoint=torch.load(a.checkpoint,map_location='cpu',weights_only=True)
    if hashlib.sha256(raw).hexdigest()!=checkpoint['metadata']['manifestSHA256']: raise ValueError('Changed data manifest')
    model=SignedGainNet(checkpoint['metadata']['width']).cuda().eval(); model.load_state_dict(checkpoint['model'])
    sys.path.insert(0,str(a.gmnet_source)); from GMNet import GMNet
    baseline=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).cuda().eval()
    digest=hashlib.sha256(a.gmnet_weights.read_bytes()).hexdigest()
    if digest!='83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f': raise ValueError('Unknown GMNet weights')
    baseline.load_state_dict(torch.load(a.gmnet_weights,map_location='cpu',weights_only=True))
    values,rows=load_split(a.data,'test',manifest); results=[]; all_pred={k:[] for k in ['identity','signed','gmnet']}; targets=[]; masks=[]
    # Per-view recipe seeds make the final test independent of batching.
    with torch.no_grad():
        for i,row in enumerate(rows):
            rgb,thumb,target,valid,unbounded=make_pairs(values[i:i+1].cuda(),1800000+i)
            pred=model(rgb,thumb)
            _,g=baseline((F.interpolate(rgb,size=(512,512),mode='bilinear',align_corners=False),
                          F.interpolate(rgb,size=(256,256),mode='bilinear',align_corners=False)))
            gm=F.interpolate(g.clamp(0,1)*MAX_EV,size=(256,256),mode='bilinear',align_corners=False)
            predictions={'identity':torch.zeros_like(pred),'signed':pred,'gmnet':gm}
            results.append({'id':row['id'],'group':row['group'],
                            'unrepresentableFraction':float((((unbounded < -2)|(unbounded > MAX_EV))&valid).sum()/valid.sum()),
                            'metrics':{k:statistics(v,target,valid) for k,v in predictions.items()}})
            for k,v in predictions.items(): all_pred[k].append(v.cpu())
            targets.append(target.cpu()); masks.append(valid.cpu())
    target=torch.cat(targets); valid=torch.cat(masks)
    pooled={k:statistics(torch.cat(v),target,valid) for k,v in all_pred.items()}
    groups=sorted({r['group'] for r in results})
    scene_means={k:[np.mean([r['metrics'][k]['maeEV'] for r in results if r['group']==group]) for group in groups] for k in all_pred}
    difference=np.array(scene_means['signed'])-np.array(scene_means['gmnet'])
    rng=np.random.default_rng(20261001)
    bootstrap=difference[rng.integers(len(groups),size=(10000,len(groups)))].mean(1)
    output={'scope':'Frozen synthetic test, no camera ground truth or app codec/display path',
            'checkpointSHA256':hashlib.sha256(a.checkpoint.read_bytes()).hexdigest(),'selectedStep':checkpoint['step'],
            'manifestSHA256':hashlib.sha256(raw).hexdigest(),'views':len(rows),'groups':len(groups),
            'pooledPixels':pooled,'meanSceneMAE':{k:float(np.mean(v)) for k,v in scene_means.items()},
            'signedMinusGMNetSceneBootstrap95':np.quantile(bootstrap,[.025,.975]).tolist(),'samples':results}
    a.output.write_text(json.dumps(output,indent=2)+'\n'); print(json.dumps({k:v for k,v in output.items() if k!='samples'},indent=2))


if __name__=='__main__': main()
