"""Fine-tune published GMNet on authorized native pairs; keep all results private.

Original architecture/output convention retained. The fixed comparison split has
already been examined in earlier experiments and is not fresh final validation.
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
from model import MAX_EV
from train import save
from train_camera import load,score,mean_scores,baseline_predictions

ORIGINAL_SHA='83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f'


def training_gain(net,image,thumbnail,mixed=True):
    # Forward adapted from qtlark/GMNet (MIT, Copyright 2025 Yinuo Liao).
    # Keep global kernel/channel/headroom estimation in FP32, including training.
    with torch.autocast(image.device.type,enabled=False):
        y=net.res_y(net.down2(net.down1(thumbnail.float())))
        kernel,cse,qmax=net.sq_ker(y),net.sq_chn(y),net.sq_qmax(y)
    with torch.autocast(image.device.type,dtype=torch.float16,enabled=mixed):
        x=net.res1(net.down_x(image));b,c,h,w=x.shape
        mask=F.conv2d(x.reshape(1,b*c,h,w),kernel.reshape(b*c,1,3,3),padding=1,groups=b*c).reshape(b,c,h,w)
        x=net.res2(x*net.mask_est(mask))
        x=x*net.att_est(cse).to(x.dtype)
        x=net.res3(x)
        out=net.conv_last(net.act(net.HRconv(net.act(net.upsampler(net.upconv(x))))))
    return (qmax*out.float()).clamp(0,1)*MAX_EV


def thumbnails(data):
    values=[]
    for i in range(len(data['rgb'])):
        h,w=map(int,data['shape'][i].tolist());top=(512-h)//2;left=(512-w)//2
        image=data['rgb'][i:i+1,:,top:top+h,left:left+w].float()/255
        values.append(F.interpolate(image,size=(256,256),mode='bilinear',align_corners=False)[0])
    return torch.stack(values)


def grouped_summary(scores,rows):
    groups=sorted({r['group'] for r in rows})
    return {key:np.array([np.mean([values[i]['maeEV'] for i,r in enumerate(rows) if r['group']==g]) for g in groups]) for key,values in scores.items()}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('data',type=Path);p.add_argument('initial',type=Path);p.add_argument('output',type=Path)
    p.add_argument('--gmnet-source',type=Path,required=True);p.add_argument('--steps',type=int,default=6000)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
    if hashlib.sha256(a.initial.read_bytes()).hexdigest()!=ORIGINAL_SHA:raise ValueError('Unexpected pretrained GMNet')
    torch.set_num_threads(4);torch.manual_seed(20261002);torch.backends.cudnn.benchmark=True
    sys.path.insert(0,str(a.gmnet_source));from GMNet import GMNet
    raw=(a.data/'manifest.json').read_bytes();manifest=json.loads(raw)
    groups={k:{r['group'] for r in manifest['samples'] if r['split']==k} for k in ['train','validation','test']}
    if any(groups[x]&groups[y] for x,y in [('train','validation'),('train','test'),('validation','test')]):raise ValueError('Split leakage')
    train,train_rows=load(a.data,'train',manifest);val,val_rows=load(a.data,'validation',manifest);thumbs=thumbnails(train)
    net=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).cuda();net.load_state_dict(torch.load(a.initial,map_location='cpu',weights_only=True))
    original=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).cuda().eval();original.load_state_dict(net.state_dict())
    net.eval();initial_pred=baseline_predictions(val,net)['gmnetRaw1024']
    initial_score=mean_scores(score(initial_pred,val['gain'].float(),val['valid']));del initial_pred
    best=initial_score['maeEV'];history=[{'step':0,**initial_score}]
    metadata={'family':'GMNet','parameters':sum(p.numel() for p in net.parameters()),'seed':20261002,
              'initialSHA256':ORIGINAL_SHA,'manifestSHA256':hashlib.sha256(raw).hexdigest(),
              'steps':a.steps,'batch':24,'learningRate':1e-5,'minimumLearningRate':5e-7,
              'trainLocalSize':256,'inferenceLocalSize':1024,'thumbnailSize':256,
              'cropProtocol':'128px crop from the 512px proxy, upsampled to 256px to match 1024px inference scale',
              'output':'Unchanged positive-only GMNet: clamp normalized gain 0..1, multiply by log2(5)',
              'precision':'FP32 global branch, autocast FP16 local branch; full FP32 validation and comparison',
              'splitImages':manifest['counts'],'splitGroups':manifest['groups'],'testUsedForCheckpointSelection':False,
              'comparisonSetPreviouslyExamined':True,'device':torch.cuda.get_device_name(),'torch':str(torch.__version__),'cuda':torch.version.cuda}
    save(a.output/'best.pt',{'model':net.state_dict(),'metadata':metadata,'step':0,'validation':initial_score})
    optimizer=torch.optim.AdamW(net.parameters(),lr=1e-5,weight_decay=1e-4)
    scheduler=torch.optim.lr_scheduler.CosineAnnealingLR(optimizer,T_max=a.steps,eta_min=5e-7)
    scaler=torch.amp.GradScaler('cuda');clock=time.perf_counter()
    print(json.dumps({'initialValidation':initial_score,'configuration':metadata}),flush=True)
    for step in range(a.steps):
        net.train();rng=torch.Generator(device='cuda').manual_seed(20261002+step)
        ix=torch.randint(len(train_rows),(24,),device='cuda',generator=rng)
        top,left=torch.randint(385,(2,),device='cuda',generator=rng).tolist()
        image=train['rgb'][ix,:,top:top+128,left:left+128].float()/255
        image=F.interpolate(image,size=(256,256),mode='bilinear',align_corners=False)
        target=F.interpolate(train['gain'][ix,None,top:top+128,left:left+128].float(),size=(256,256),mode='bilinear',align_corners=False)[:,0].clamp(0,MAX_EV)
        # Require all interpolation contributors to be valid, including padding.
        mask=F.interpolate(train['valid'][ix,None,top:top+128,left:left+128].float(),size=(256,256),mode='bilinear',align_corners=False)[:,0]>.9999
        thumb=thumbs[ix].float()
        if step%2:image=image.flip(-1);target=target.flip(-1);mask=mask.flip(-1);thumb=thumb.flip(-1)
        optimizer.zero_grad(set_to_none=True);pred=training_gain(net,image,thumb)[:,0]
        point=(F.smooth_l1_loss(pred,target,beta=.2,reduction='none')*mask).sum()/mask.sum().clamp_min(1)
        dx=(pred[:,:,1:]-pred[:,:,:-1])-(target[:,:,1:]-target[:,:,:-1]);mx=mask[:,:,1:]&mask[:,:,:-1]
        dy=(pred[:,1:]-pred[:,:-1])-(target[:,1:]-target[:,:-1]);my=mask[:,1:]&mask[:,:-1]
        loss=point+.05*((dx.abs()*mx).sum()/mx.sum().clamp_min(1)+(dy.abs()*my).sum()/my.sum().clamp_min(1))
        if not torch.isfinite(loss):raise ValueError('Non-finite loss')
        scaler.scale(loss).backward();scaler.unscale_(optimizer);torch.nn.utils.clip_grad_norm_(net.parameters(),1)
        scaler.step(optimizer);scaler.update();scheduler.step()
        if (step+1)%100==0:print(json.dumps({'step':step+1,'loss':float(loss),'elapsedSeconds':time.perf_counter()-clock}),flush=True)
        if (step+1)%500==0:
            net.eval();v=baseline_predictions(val,net)['gmnetRaw1024'];metrics=mean_scores(score(v,val['gain'].float(),val['valid']));del v
            history.append({'step':step+1,**metrics})
            if metrics['maeEV']<best:
                best=metrics['maeEV'];save(a.output/'best.pt',{'model':net.state_dict(),'metadata':metadata,'step':step+1,'validation':metrics})
            print(json.dumps({'validationStep':step+1,'metrics':metrics}),flush=True)
    elapsed=time.perf_counter()-clock
    selected=torch.load(a.output/'best.pt',map_location='cuda',weights_only=True);net.load_state_dict(selected['model']);net.eval()
    test,rows=load(a.data,'test',manifest)
    before=baseline_predictions(test,original);after=baseline_predictions(test,net)
    predictions={'pretrainedRaw':before['gmnetRaw1024'],'pretrainedProtectedApprox':before['gmnetProtectedApprox'],
                 'tunedRaw':after['gmnetRaw1024'],'tunedProtectedApprox':after['gmnetProtectedApprox']}
    scores={k:score(v,test['gain'].float(),test['valid']) for k,v in predictions.items()}
    means=grouped_summary(scores,rows);delta=means['tunedRaw']-means['pretrainedRaw']
    rng=np.random.default_rng(20261002);bootstrap=delta[rng.integers(len(delta),size=(10000,len(delta)))].mean(1)
    report={'scope':'Previously examined comparison set; checkpoint chosen only on validation. No app codec/device acceptance.',
            'configuration':metadata,'selectedStep':selected['step'],'trainingSeconds':elapsed,'validation':history,
            'comparison':{k:mean_scores(v) for k,v in scores.items()},'meanGroupMAE':{k:float(v.mean()) for k,v in means.items()},
            'pairedGroupDifference95':np.quantile(bootstrap,[.025,.975]).tolist(),
            'checkpointSHA256':hashlib.sha256((a.output/'best.pt').read_bytes()).hexdigest()}
    (a.output/'report.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    (a.output/'private-test-scores.json').write_text(json.dumps({'rows':rows,'scores':scores})+'\n')
    print(json.dumps({'selectedStep':selected['step'],'comparison':report['comparison'],'meanGroupMAE':report['meanGroupMAE']}),flush=True)


if __name__=='__main__':main()
