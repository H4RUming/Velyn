"""Local private-photo check that conversion preserves the measured improvement."""
import argparse
import json
from pathlib import Path
import time
import numpy as np
import torch
import torch.nn.functional as F
import coremltools as ct
from train_camera import score,mean_scores


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('package',type=Path);p.add_argument('pairs',type=Path)
    p.add_argument('private_scores',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();torch.set_num_threads(4);prior=json.loads(a.private_scores.read_text())
    model=ct.models.MLModel(str(a.package),compute_units=ct.ComputeUnit.CPU_AND_NE)
    rows=[];times=[]
    for i,row in enumerate(prior['rows']):
        path=Path(row['path'])
        if str(path)!=path.name:raise ValueError('Invalid pair path')
        with np.load(a.pairs/path,allow_pickle=False) as data:
            rgb=torch.from_numpy(data['rgb'].copy())[None].float()/255;h,w=map(int,data['shape']);top=(512-h)//2;left=(512-w)//2
            local=F.interpolate(rgb,size=(1024,1024),mode='bilinear',align_corners=False)
            thumb=F.interpolate(rgb[:,:,top:top+h,left:left+w],size=(256,256),mode='bilinear',align_corners=False)
            args={'image':local.numpy(),'thumbnail':thumb.numpy()}
            if i==0:model.predict(args)
            start=time.perf_counter();value=model.predict(args)['log_gain'];times.append(time.perf_counter()-start)
            if not np.isfinite(value).all():raise ValueError('Non-finite Core ML prediction')
            prediction=F.interpolate(torch.from_numpy(value),size=(512,512),mode='bilinear',align_corners=False)[:,0]
            rows.extend(score(prediction,torch.from_numpy(data['gain'].copy())[None].float(),torch.from_numpy(data['valid'].copy())[None]))
        if (i+1)%25==0:print(f'Compared {i+1} images locally',flush=True)
    differences=np.array([r['maeEV']-old['maeEV'] for r,old in zip(rows,prior['scores']['tunedRaw'])])
    report={'scope':'Mac Core ML CPU_AND_NE requested; 132 previously examined private comparison photos; not iPhone or confirmed all-NE placement',
            'photos':len(rows),'metrics':mean_scores(rows),'meanPhotoMAEDifferenceFromPyTorch':float(differences.mean()),
            'maxAbsolutePhotoMAEDifferenceFromPyTorch':float(np.abs(differences).max()),
            'medianPredictionSeconds':float(np.median(times)),'p95PredictionSeconds':float(np.quantile(times,.95))}
    a.output.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n');print(json.dumps(report,indent=2))


if __name__=='__main__':main()
