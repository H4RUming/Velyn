"""Fine-tune on explicitly authorized native camera pairs, never synthetic labels.

Run inside a disposable private server workspace. No image/EXIF output in logs.
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
from model import SignedGainNet,MIN_EV,MAX_EV
from train import save


def load(root,split,manifest):
    rows=[r for r in manifest['samples'] if r['split']==split]; items=[]
    for row in rows:
        relative=Path(row['path'])
        if relative.name!=str(relative) or relative.suffix!='.npz':raise ValueError('Invalid pair path')
        path=root/relative
        if hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256']:raise ValueError('Pair hash mismatch')
        with np.load(path,allow_pickle=False) as z:
            if z['rgb'].shape!=(3,512,512) or z['gain'].shape!=(512,512):raise ValueError('Invalid pair dimensions')
            items.append({k:torch.from_numpy(z[k].copy()) for k in z.files})
    return {k:torch.stack([item[k] for item in items]).cuda() for k in items[0]},rows


def score(pred,target,mask):
    values=[]
    for i in range(len(pred)):
        valid=mask[i]; p=pred[i];t=target[i];neg=valid&(t<-.05);pn=valid&(p<-.05)
        values.append({'maeEV':float((p-t).abs()[valid].mean()),
                       'boundedMAE_EV':float((p-t.clamp(MIN_EV,MAX_EV)).abs()[valid].mean()),
                       'negativeFraction':float(neg.sum()/valid.sum()),'predictedNegativeFraction':float(pn.sum()/valid.sum()),
                       'negativePrecision':float((neg&pn).sum()/pn.sum().clamp_min(1)),
                       'negativeRecall':float((neg&pn).sum()/neg.sum().clamp_min(1)),
                       'truePositivePixels':int((neg&pn).sum()),'predictedNegativePixels':int(pn.sum()),'targetNegativePixels':int(neg.sum())})
    return values


@torch.no_grad()
def predict(model,data):
    model.eval(); result=[]
    for i in range(0,len(data['rgb']),8):
        result.append(model(data['rgb'][i:i+8].float()/255,data['thumbnail'][i:i+8].float()/255)[:,0].float())
    return torch.cat(result)


def mean_scores(rows):
    result={k:float(np.mean([r[k] for r in rows])) for k in rows[0] if not k.endswith('Pixels')}
    tp=sum(r['truePositivePixels'] for r in rows)
    result['negativePrecision']=tp/max(1,sum(r['predictedNegativePixels'] for r in rows))
    result['negativeRecall']=tp/max(1,sum(r['targetNegativePixels'] for r in rows))
    return result


@torch.no_grad()
def baseline_predictions(data,gmnet):
    raw=[];protected=[]
    for i in range(len(data['rgb'])):
        inp=data['rgb'][i:i+1].float()/255
        h,w=map(int,data['shape'][i].tolist());top=(512-h)//2;left=(512-w)//2
        local=F.interpolate(inp,size=(1024,1024),mode='bilinear',align_corners=False)
        thumb=F.interpolate(inp[:,:,top:top+h,left:left+w],size=(256,256),mode='bilinear',align_corners=False)
        _,g=gmnet((local,thumb));g=F.interpolate(g.clamp(0,1)*MAX_EV,size=(512,512),mode='bilinear',align_corners=False)[0,0]
        y=data['luminance'][i].float()
        inside=y[top:top+h,left:left+w];q=torch.quantile(inside.flatten(),torch.tensor([.1,.9],device='cuda')).clamp_min(.0001)
        span=torch.log2(q[1]/q[0]);t=((6-span)/2).clamp(0,1);blend=t*t*(3-2*t) if span>=.25 else 0
        def smooth(x): t=x.clamp(0,1);return t*t*(3-2*t)
        code=torch.where(y<=.0031308,12.92*y,1.055*y.clamp_min(0).pow(1/2.4)-.055)
        gate=smooth((y-.18)/.62)*(1-blend)+smooth((code-.18)/.62)*blend
        raw.append(g);protected.append((g*.75*gate).clamp_max(2))
    return {'gmnetRaw1024':torch.stack(raw),'gmnetProtectedApprox':torch.stack(protected)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('data',type=Path);p.add_argument('initial',type=Path);p.add_argument('output',type=Path)
    p.add_argument('--gmnet-source',type=Path,required=True);p.add_argument('--steps',type=int,default=6000)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False);torch.set_num_threads(4);torch.manual_seed(20261002)
    torch.backends.cudnn.benchmark=True
    raw=(a.data/'manifest.json').read_bytes();manifest=json.loads(raw)
    groups={k:{r['group'] for r in manifest['samples'] if r['split']==k} for k in ['train','validation','test']}
    if any(groups[x]&groups[y] for x,y in [('train','validation'),('train','test'),('validation','test')]):raise ValueError('Split leakage')
    train,train_rows=load(a.data,'train',manifest);val,val_rows=load(a.data,'validation',manifest)
    initial=torch.load(a.initial,map_location='cpu',weights_only=True)
    model=SignedGainNet(initial['metadata']['width']).cuda();model.load_state_dict(initial['model'])
    initial_model=SignedGainNet(initial['metadata']['width']).cuda().eval();initial_model.load_state_dict(initial['model'])
    initial_val=mean_scores(score(predict(model,val),val['gain'].float(),val['valid']))
    optimizer=torch.optim.AdamW(model.parameters(),lr=5e-5,weight_decay=1e-4)
    scheduler=torch.optim.lr_scheduler.CosineAnnealingLR(optimizer,T_max=a.steps,eta_min=2e-6)
    scaler=torch.amp.GradScaler('cuda');best=initial_val['maeEV'];start=time.perf_counter()
    metadata={'width':initial['metadata']['width'],'parameters':sum(p.numel() for p in model.parameters()),'seed':20261002,
              'manifestSHA256':hashlib.sha256(raw).hexdigest(),'initialSHA256':hashlib.sha256(a.initial.read_bytes()).hexdigest(),
              'steps':a.steps,'batch':24,'cropSize':256,'fullSize':512,'splitImages':manifest['counts'],'splitGroups':manifest['groups'],
              'device':torch.cuda.get_device_name(),'torch':str(torch.__version__),'cuda':torch.version.cuda,'testUsedForSelection':False}
    save(a.output/'best.pt',{'model':model.state_dict(),'metadata':metadata,'step':0,'validation':initial_val})
    history=[{'step':0,**initial_val}];print(json.dumps({'initialValidation':initial_val,'counts':manifest['counts']}),flush=True)
    for step in range(a.steps):
        model.train();rng=torch.Generator(device='cuda').manual_seed(20261002+step)
        ix=torch.randint(len(train_rows),(24,),generator=rng,device='cuda')
        # One crop offset per minibatch avoids an expensive gather and preserves
        # pixel alignment. Global thumbnail always depicts the complete image.
        top,left=torch.randint(257,(2,),generator=rng,device='cuda').tolist()
        rgb=train['rgb'][ix,:,top:top+256,left:left+256].float()/255;thumb=train['thumbnail'][ix].float()/255
        target=train['gain'][ix,top:top+256,left:left+256].float().clamp(MIN_EV,MAX_EV)
        mask=train['valid'][ix,top:top+256,left:left+256]
        if step%2:rgb=rgb.flip(-1);thumb=thumb.flip(-1);target=target.flip(-1);mask=mask.flip(-1)
        optimizer.zero_grad(set_to_none=True)
        with torch.autocast('cuda',dtype=torch.float16):prediction=model(rgb,thumb)[:,0]
        pred=prediction.float();point=(F.smooth_l1_loss(pred,target,beta=.2,reduction='none')*mask).sum()/mask.sum().clamp_min(1)
        dx=(pred[:,:,1:]-pred[:,:,:-1])-(target[:,:,1:]-target[:,:,:-1]);mx=mask[:,:,1:]&mask[:,:,:-1]
        dy=(pred[:,1:]-pred[:,:-1])-(target[:,1:]-target[:,:-1]);my=mask[:,1:]&mask[:,:-1]
        loss=point+.05*((dx.abs()*mx).sum()/mx.sum().clamp_min(1)+(dy.abs()*my).sum()/my.sum().clamp_min(1))
        if not torch.isfinite(loss):raise ValueError('Non-finite training loss')
        scaler.scale(loss).backward();scaler.unscale_(optimizer);torch.nn.utils.clip_grad_norm_(model.parameters(),1)
        scaler.step(optimizer);scaler.update();scheduler.step()
        if (step+1)%500==0:
            metrics=mean_scores(score(predict(model,val),val['gain'].float(),val['valid']))
            history.append({'step':step+1,**metrics});print(json.dumps({'step':step+1,'validation':metrics,'elapsedSeconds':time.perf_counter()-start}),flush=True)
            if metrics['maeEV']<best:
                best=metrics['maeEV'];save(a.output/'best.pt',{'model':model.state_dict(),'metadata':metadata,'step':step+1,'validation':metrics})
    training_seconds=time.perf_counter()-start
    chosen=torch.load(a.output/'best.pt',map_location='cuda',weights_only=True);model.load_state_dict(chosen['model'])
    # Only now load the locked final test. No training decisions follow it.
    test,test_rows=load(a.data,'test',manifest)
    sys.path.insert(0,str(a.gmnet_source));from GMNet import GMNet
    gm=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).cuda().eval()
    weights=a.gmnet_source/'G_realworld.pth'
    if hashlib.sha256(weights.read_bytes()).hexdigest()!='83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f':raise ValueError('Unexpected baseline checkpoint')
    gm.load_state_dict(torch.load(weights,map_location='cpu',weights_only=True))
    predictions=baseline_predictions(test,gm)
    predictions.update(identity=torch.zeros_like(test['gain']),syntheticPilot=predict(initial_model,test),cameraAdapted=predict(model,test))
    scores={k:score(v,test['gain'].float(),test['valid']) for k,v in predictions.items()}
    summary={k:mean_scores(v) for k,v in scores.items()}
    group_ids=sorted(groups['test']);scene_means={k:np.array([np.mean([v[i]['maeEV'] for i,r in enumerate(test_rows) if r['group']==g]) for g in group_ids]) for k,v in scores.items()}
    difference=scene_means['cameraAdapted']-scene_means['gmnetProtectedApprox']
    rng=np.random.default_rng(20261002);boots=difference[rng.integers(len(difference),size=(10000,len(difference)))].mean(1)
    report={'scope':'Private camera dataset, unseen capture groups. Tensor inference; protected GMNet is an approximation without app edge-aware interpolation or codecs.',
            'configuration':metadata,'selectedStep':chosen['step'],'trainingSeconds':training_seconds,'validation':history,
            'test':summary,'meanGroupMAE':{k:float(v.mean()) for k,v in scene_means.items()},
            'pairedGroupDifference95':np.quantile(boots,[.025,.975]).tolist(),
            'checkpointSHA256':hashlib.sha256((a.output/'best.pt').read_bytes()).hexdigest(),
            'testImagesImprovedAgainstProtectedGMNet':sum(a['maeEV']<b['maeEV'] for a,b in zip(scores['cameraAdapted'],scores['gmnetProtectedApprox']))}
    (a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    # Anonymous per-image results stay private to allow local regression review.
    (a.output/'private-test-scores.json').write_text(json.dumps({'rows':test_rows,'scores':scores})+'\n')
    print(json.dumps({'selectedStep':chosen['step'],'test':summary,'groupMeans':report['meanGroupMAE']}),flush=True)


if __name__=='__main__':main()
