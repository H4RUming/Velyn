"""Train a reproducible signed gain pilot; never read or train on the test split."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import time
import numpy as np
import torch
import torch.nn.functional as F
from model import SignedGainNet
from pairs import make_pairs


def load_split(root,split,manifest):
    rows=[v for source in manifest['sources'] for v in source['views'] if v['split']==split]
    tensors=[]
    for row in rows:
        relative=Path(row['path'])
        if relative.is_absolute() or '..' in relative.parts: raise ValueError('Invalid fixture path')
        value=np.load(root/relative)
        if value.shape!=(256,256,3) or not np.isfinite(value).all(): raise ValueError('Invalid HDR fixture')
        tensors.append(torch.from_numpy(value.transpose(2,0,1).copy()))
    if not tensors: raise ValueError(f'Empty {split} split')
    return torch.stack(tensors),rows


def statistics(pred,target,valid):
    error=(pred-target).abs()
    positive=valid&(target>.05); negative=valid&(target<-.05)
    def mean(x,mask): return float(x[mask].mean()) if mask.any() else None
    return {'maeEV':mean(error,valid),'positiveMAE':mean(error,positive),'negativeMAE':mean(error,negative),
            'negativePrecision':float(((pred<-.05)&negative).sum()/((pred<-.05)&valid).sum().clamp_min(1)),
            'negativeRecall':float(((pred<-.05)&negative).sum()/negative.sum().clamp_min(1)),
            'negativeFraction':float(negative.sum()/valid.sum().clamp_min(1))}


@torch.no_grad()
def evaluate(model,values,batch):
    model.eval(); predicted=[]; targets=[]; masks=[]
    # All validation views use a fixed recipe seed, unrelated to training steps.
    for start in range(0,len(values),batch):
        rgb,thumb,target,valid,_=make_pairs(values[start:start+batch],900000+start)
        pred=model(rgb,thumb)
        predicted.append(pred.float().cpu()); targets.append(target.cpu()); masks.append(valid.cpu())
    pred=torch.cat(predicted); target=torch.cat(targets); valid=torch.cat(masks)
    model.train()
    return {'model':statistics(pred,target,valid),'identity':statistics(torch.zeros_like(pred),target,valid)}


def save(path,value):
    temp=path.with_suffix('.tmp'); torch.save(value,temp); temp.replace(path)


def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('data',type=Path); p.add_argument('output',type=Path)
    p.add_argument('--steps',type=int,default=6000); p.add_argument('--batch',type=int,default=24)
    p.add_argument('--width',type=int,default=24); p.add_argument('--seed',type=int,default=20261001)
    p.add_argument('--resume',action='store_true')
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    if (a.output/'last.pt').exists() and not a.resume: raise ValueError('Existing run; use --resume or a new directory')
    torch.set_num_threads(4); random.seed(a.seed); np.random.seed(a.seed); torch.manual_seed(a.seed)
    if not torch.cuda.is_available(): raise RuntimeError('CUDA is required for this server experiment')
    torch.cuda.manual_seed_all(a.seed); torch.backends.cudnn.benchmark=True
    raw=(a.data/'manifest.json').read_bytes(); manifest=json.loads(raw)
    if len(manifest['sources'])+len(manifest['failures'])!=len(manifest['selected']):
        raise ValueError('Data preparation is still incomplete')
    if manifest['failures']: print('Source failures recorded:',len(manifest['failures']),flush=True)
    group_sets={split:{s['group'] for s in manifest['sources'] if s['split']==split} for split in ['train','validation','test']}
    assert not group_sets['train']&group_sets['validation'] and not group_sets['train']&group_sets['test'] and not group_sets['validation']&group_sets['test']
    train,train_rows=load_split(a.data,'train',manifest); val,val_rows=load_split(a.data,'validation',manifest)
    train=train.cuda(); val=val.cuda()
    model=SignedGainNet(a.width).cuda(); optimizer=torch.optim.AdamW(model.parameters(),lr=2e-4,weight_decay=1e-4)
    scheduler=torch.optim.lr_scheduler.CosineAnnealingLR(optimizer,T_max=a.steps,eta_min=1e-5)
    scaler=torch.amp.GradScaler('cuda'); start_step=0; best=float('inf')
    metadata={'seed':a.seed,'steps':a.steps,'batch':a.batch,'width':a.width,'parameters':sum(p.numel() for p in model.parameters()),
              'torch':str(torch.__version__),'cuda':torch.version.cuda,'device':torch.cuda.get_device_name(),
              'manifestSHA256':hashlib.sha256(raw).hexdigest(),'trainViews':len(train),'validationViews':len(val),
              'groups':{k:len(v) for k,v in group_sets.items()},'testUsedDuringTraining':False,
              'protocol':'Synthetic SDR from CC0 HDR panoramas, 256px perspective views. No real camera target and no user photos. Identity initialization; no pretrained weights.'}
    if a.resume:
        state=torch.load(a.output/'last.pt',map_location='cuda',weights_only=True)
        if state['metadata']!=metadata: raise ValueError('Resume metadata mismatch')
        model.load_state_dict(state['model']); optimizer.load_state_dict(state['optimizer']); scheduler.load_state_dict(state['scheduler']); scaler.load_state_dict(state['scaler'])
        start_step=state['step']; best=state['best']
    (a.output/'run.json').write_text(json.dumps(metadata,indent=2)+'\n'); print(json.dumps(metadata),flush=True)
    initial=evaluate(model,val,a.batch); print('initial',initial,flush=True)
    clock=time.perf_counter(); model.train()
    for step in range(start_step,a.steps):
        generator=torch.Generator(device='cuda').manual_seed(a.seed+step)
        indices=torch.randint(len(train),(a.batch,),device='cuda',generator=generator)
        hdr=train[indices]
        if step%2: hdr=hdr.flip(-1)
        rgb,thumb,target,valid,_=make_pairs(hdr,a.seed+step*7)
        optimizer.zero_grad(set_to_none=True)
        with torch.autocast('cuda',dtype=torch.float16): pred=model(rgb,thumb)
        pred=pred.float()
        robust=F.smooth_l1_loss(pred,target,reduction='none',beta=.2)
        # Equal per-pixel reconstruction, plus edge differences. No target sign
        # rebalancing that would over-reward darkening rare negative regions.
        point=(robust*valid).sum()/valid.sum().clamp_min(1)
        dx=(pred[:,:,:,1:]-pred[:,:,:,:-1])-(target[:,:,:,1:]-target[:,:,:,:-1])
        dy=(pred[:,:,1:]-pred[:,:,:-1])-(target[:,:,1:]-target[:,:,:-1])
        loss=point+.05*(dx.abs().mean()+dy.abs().mean())
        if not torch.isfinite(loss): raise RuntimeError('Non-finite training loss')
        scaler.scale(loss).backward(); scaler.unscale_(optimizer); torch.nn.utils.clip_grad_norm_(model.parameters(),1)
        scaler.step(optimizer); scaler.update(); scheduler.step()
        if (step+1)%100==0:
            torch.cuda.synchronize(); elapsed=time.perf_counter()-clock
            progress={'step':step+1,'loss':float(loss),'elapsedSeconds':elapsed,'stepsPerSecond':(step+1-start_step)/elapsed,
                      'peakGPUMemoryMiB':torch.cuda.max_memory_allocated()/2**20}
            (a.output/'progress.json').write_text(json.dumps(progress)+'\n'); print(json.dumps(progress),flush=True)
        if (step+1)%1000==0 or step+1==a.steps:
            score=evaluate(model,val,a.batch); improved=score['model']['maeEV']<best
            if improved: best=score['model']['maeEV']
            state={'model':model.state_dict(),'metadata':metadata,'step':step+1,'validation':score,'best':best,
                   'optimizer':optimizer.state_dict(),'scheduler':scheduler.state_dict(),'scaler':scaler.state_dict()}
            save(a.output/'last.pt',state)
            if improved: save(a.output/'best.pt',state)
            with (a.output/'validation.jsonl').open('a') as f: f.write(json.dumps({'step':step+1,**score})+'\n')
            print('validation',step+1,score,flush=True)
    (a.output/'complete.json').write_text(json.dumps({'steps':a.steps,'bestValidationMAE':best,'elapsedSeconds':time.perf_counter()-clock})+'\n')


if __name__=='__main__': main()
