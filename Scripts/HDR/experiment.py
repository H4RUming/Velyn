"""Reproducible local ablation; no network access and no app/model replacement.

Development selects a frozen shortlist. Validation consumes it without retuning.
Arrays and learned prototype weights remain in the explicit private output folder.
"""
from pathlib import Path
import argparse
import hashlib
import json
import math
import sys
import time
import numpy as np
import torch
import torch.nn.functional as F
from metrics import LUMA, measure, self_test

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Models/gmnet'))
from GMNet import GMNet


def resize(a, shape):
    return F.interpolate(torch.from_numpy(a.copy())[None,None],size=shape,mode='bilinear',align_corners=False).numpy()[0,0]


def load(root):
    m=json.loads((root/'prepared.json').read_text()); shape=(m['sampleHeight'],m['sampleWidth'])
    def rgb(name): return np.fromfile(root/(name+'.f32'),np.float32).reshape(*shape,4)[...,:3].astype(np.float64)
    base,reference=rgb('base'),rgb('reference')
    y=np.maximum(base@LUMA,1e-8)
    renders={k:rgb(k) for k in ['legacy','v11','v11-bilinear','full-edge','full-bilinear']}
    gains={k:np.clip(np.log2(np.maximum(renders['full-'+k]@LUMA,1e-8)/y),0,np.log2(5)) for k in ['edge','bilinear']}
    return dict(root=root,meta=m,base=base,reference=reference,y=y,gains=gains,renders=renders)


def gate(y, kind, blend):
    def smooth(x):
        t=np.clip(x,0,1); return t*t*(3-2*t)
    linear=smooth((y-.18)/.62)
    perceptual=np.where(y<=.0031308,12.92*y,1.055*np.maximum(y,0)**(1/2.4)-.055)
    p=smooth((perceptual-.18)/.62)
    return {'none':np.ones_like(y),'linear':linear,'perceptual':p,
            'adaptive':linear*(1-blend)+p*blend,'shadow':smooth((y-.01)/.17)}[kind]


def variants(sample):
    y=sample['y']; blend=sample['meta']['protectionBlend']
    outputs={'SDR':sample['base'],**{'production/'+k:v for k,v in sample['renders'].items()}}
    def add(name,g):outputs[name]=sample['base']*np.exp2(np.clip(g,0,np.log2(5)))[...,None]
    for resize_name in ['edge','bilinear']:
        g=sample['gains'][resize_name]
        for kind in ['none','linear','perceptual','adaptive','shadow']:
            for strength in [.5,.75,1]:
                applied=g*gate(y,kind,blend)*strength
                add(f'{resize_name}/{kind}/{strength}/cap2',np.minimum(applied,2))
        for cap in [1,np.log2(5)]:
            for kind in ['none','adaptive']:
                add(f'{resize_name}/{kind}/0.75/cap{cap:.3f}',np.minimum(g*gate(y,kind,blend)*.75,cap))
        for offset in [.1,.25,.4]:
            add(f'{resize_name}/offset{offset}',g*.75-offset)
    return outputs


def infer_inputs(sample,net):
    root=sample['root']; cache=root/'input-variants.npz'
    if cache.exists():return dict(np.load(cache)),json.loads((root/'input-timing.json').read_text())
    m=sample['meta']; h,w=m['height'],m['width']; shape=sample['y'].shape
    rgb=np.fromfile(root/'source-srgb.f32',np.float32).reshape(h,w,4)[...,:3]
    thumb=np.fromfile(root/'thumbnail-srgb.f32',np.float32).reshape(256,256,4)[...,:3]
    source=torch.from_numpy(rgb.transpose(2,0,1).copy())[None].clamp(0,1)
    thumbnail=torch.from_numpy(thumb.transpose(2,0,1).copy())[None].clamp(0,1)
    gains={}; times={}
    for mode in ['native512-u8','native512-float','native1024-float','padded512-float','flipY512-float','flipX512-float']:
        edge=1024 if '1024' in mode else 512
        size=(max(2,round(edge*h/max(w,h)/2)*2),max(2,round(edge*w/max(w,h)/2)*2))
        inp=F.interpolate(source,size=size,mode='bicubic',align_corners=False).clamp(0,1); t=thumbnail
        if 'u8' in mode:inp=torch.round(inp*255)/255;t=torch.round(t*255)/255
        pads=None
        if 'padded' in mode:
            dh,dw=512-size[0],512-size[1]; pads=(dw//2,dw-dw//2,dh//2,dh-dh//2); inp=F.pad(inp,pads,mode='replicate')
        axis=2 if 'flipY' in mode else 3 if 'flipX' in mode else None
        if axis is not None:inp=inp.flip(axis);t=t.flip(axis)
        start=time.perf_counter()
        with torch.no_grad(): _,g=net((inp,t));g=g.clamp(0,1)*math.log2(5)
        times[mode]=time.perf_counter()-start
        if axis is not None:g=g.flip(axis)
        if pads is not None:g=g[:,:,pads[2]:pads[2]+size[0],pads[0]:pads[0]+size[1]]
        gains[mode]=F.interpolate(g,size=shape,mode='bilinear',align_corners=False).numpy()[0,0]
    gains['ensemble512-float']=(gains['native512-float']+gains['flipY512-float']+gains['flipX512-float'])/3
    times['ensemble512-float']=sum(times[k] for k in ['native512-float','flipY512-float','flipX512-float'])
    np.savez(cache,**gains);(root/'input-timing.json').write_text(json.dumps(times,indent=2))
    return gains,times


def input_outputs(sample,gains):
    result={};y=sample['y'];blend=sample['meta']['protectionBlend']
    for name,g in gains.items():
        for kind in ['none','adaptive']:
            applied=np.minimum(g*.75*gate(y,kind,blend),2)
            result['input/'+name+'/'+kind]=sample['base']*np.exp2(applied)[...,None]
    # Reconstruct upstream gamma-2.2 convention as a diagnostic. This changes
    # base RGB relationships and is NOT proposed as an unconditional color fix.
    rgb=np.maximum(sample['base'],0)
    encoded=np.where(rgb<=.0031308,12.92*rgb,1.055*rgb**(1/2.4)-.055)
    gamma=encoded**2.2
    result['gamma22/full']=gamma*np.exp2(sample['gains']['bilinear'])[...,None]
    result['gamma22/adaptive']=gamma*np.exp2(np.minimum(sample['gains']['bilinear']*.75*gate(y,'adaptive',blend),2))[...,None]
    return result


def features(sample):
    y=sample['y']; g=sample['gains']['bilinear']
    return np.array([1,np.mean(g),np.std(g),np.quantile(y,.5),np.quantile(y,.9),np.mean(y>.5)],np.float64)


def oracle_scale(sample):
    y=sample['y'];r=np.maximum(sample['reference']@LUMA,1e-8)
    mask=(y>.01)&(r>.01);target=np.log2(r[mask]/y[mask]);g=sample['gains']['bilinear'][mask]
    scales=np.linspace(0,2,101)
    return float(scales[np.argmin([np.mean(np.abs(np.minimum(g*s,math.log2(5))-target)) for s in scales])])


def fit_calibration(samples):
    x=np.stack([features(s) for s in samples]);y=np.array([oracle_scale(s) for s in samples])
    # Strong ridge regularization; never fit or select lambda on validation.
    regularizer=np.eye(x.shape[1])*2;regularizer[0,0]=.001
    return np.linalg.solve(x.T@x+regularizer,x.T@y)


class ResidualGain(torch.nn.Module):
    def __init__(self):
        super().__init__();self.layers=torch.nn.Sequential(torch.nn.Conv2d(4,12,3,padding=1),torch.nn.ReLU(),torch.nn.Conv2d(12,12,3,padding=1),torch.nn.ReLU(),torch.nn.Conv2d(12,1,3,padding=1))
        torch.nn.init.zeros_(self.layers[-1].weight);torch.nn.init.zeros_(self.layers[-1].bias)
    def forward(self,x):return (x[:,3:4]+1.5*torch.tanh(self.layers(x))).clamp(0,math.log2(5))


def learning_tensor(sample):
    rgb=np.maximum(sample['base'],0)
    encoded=np.where(rgb<=.0031308,12.92*rgb,1.055*rgb**(1/2.4)-.055).clip(0,1)
    return torch.from_numpy(np.concatenate([encoded,sample['gains']['bilinear'][...,None]],-1).transpose(2,0,1).astype(np.float32))[None]


def train_residual(samples,steps=120):
    torch.manual_seed(20261001);rng=np.random.default_rng(20261001)
    model=ResidualGain();optimizer=torch.optim.Adam(model.parameters(),lr=.002)
    items=[]
    for s in samples:
        y=s['y'];ref=np.maximum(s['reference']@LUMA,1e-8)
        target=np.log2(ref/y).clip(0,math.log2(5))
        items.append((learning_tensor(s),torch.from_numpy(target.astype(np.float32))[None,None],torch.from_numpy(((y>.01)&(ref>.01)).astype(np.float32))[None,None]))
    for _ in range(steps):
        inputs=[];targets=[];masks=[]
        for _ in range(4):
            x,y,mask=items[int(rng.integers(len(items)))];h,w=y.shape[-2:]
            top=int(rng.integers(max(1,h-64+1)));left=int(rng.integers(max(1,w-64+1)))
            inputs.append(x[:,:,top:top+64,left:left+64]);targets.append(y[:,:,top:top+64,left:left+64]);masks.append(mask[:,:,top:top+64,left:left+64])
        x,y,mask=torch.cat(inputs),torch.cat(targets),torch.cat(masks)
        pred=model(x);loss=((pred-y).abs()*mask).sum()/mask.sum().clamp_min(1)
        # Keep a weak proximity prior so tiny training data cannot rewrite all gain.
        loss=loss+.05*(pred-x[:,3:4]).abs().mean()
        optimizer.zero_grad();loss.backward();optimizer.step()
    return model.eval()


def learned_outputs(sample,coefficients,cnn):
    scale=float(np.clip(features(sample)@coefficients,0,2))
    calibrated=np.minimum(sample['gains']['bilinear']*scale,math.log2(5))
    with torch.no_grad():g=cnn(learning_tensor(sample)).numpy()[0,0]
    return {'learned/scene-scale':sample['base']*np.exp2(calibrated)[...,None],
            'learned/residual-cnn':sample['base']*np.exp2(g)[...,None]}


def summarize(rows):
    names=sorted(set.intersection(*(set(r['metrics']) for r in rows)))
    summary={}
    for name in names:
        values=[r['metrics'][name] for r in rows]
        summary[name]={k:float(np.mean([v[k] for v in values if v[k] is not None])) for k in ['maeEV','p95EV','puPSNR','puSSIM','uvError','baseColorShift']}
        summary[name]['worstRegressionEV']=max(r['metrics'][name]['maeEV']-r['metrics']['production/v11']['maeEV'] for r in rows)
        summary[name]['improvedScenes']=sum(r['metrics'][name]['maeEV']<r['metrics']['production/v11']['maeEV']-1e-5 for r in rows)
    return summary


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixtures',type=Path);parser.add_argument('output',type=Path);parser.add_argument('checkpoint',type=Path)
    parser.add_argument('--phase',choices=['development','validation'],required=True)
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    self_test();torch.set_num_threads(4)
    assert hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()=='83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f'
    samples=[load(p.parent) for p in sorted(args.fixtures.glob('*/prepared.json')) if json.loads(p.read_text())['group']==args.phase]
    net=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).eval();net.load_state_dict(torch.load(args.checkpoint,map_location='cpu',weights_only=True))
    if args.phase=='validation':
        lock=json.loads((args.output/'frozen.json').read_text());coefficients=np.array(lock['calibration'])
        cnn=ResidualGain().eval();cnn.load_state_dict(torch.load(args.output/'residual.pt',map_location='cpu',weights_only=True))
    rows=[]
    for index,s in enumerate(samples):
        start=time.perf_counter();outputs=variants(s)
        gains,timing=infer_inputs(s,net);outputs.update(input_outputs(s,gains))
        if args.phase=='development':
            train=[t for i,t in enumerate(samples) if i!=index]
            coefficients=fit_calibration(train);cnn=train_residual(train)
        outputs.update(learned_outputs(s,coefficients,cnn))
        metrics={name:measure(rgb,s['reference'],s['base']) for name,rgb in outputs.items()}
        # Viewing-condition sensitivity, fixed for both candidate/reference.
        sensitivity={name:measure(rgb,s['reference'],s['base'],white=100) for name,rgb in outputs.items()}
        row={'id':s['meta']['id'],'metrics':metrics,'white100':sensitivity,'inputSeconds':timing,'originalPreserved':s['meta']['originalPreserved']}
        rows.append(row)
        (args.output/(args.phase+'-partial.json')).write_text(json.dumps(rows,indent=2,allow_nan=False))
        print(s['meta']['id'],'done',round(time.perf_counter()-start,1),'seconds',flush=True)
    summary=summarize(rows)
    result={'environment':'macOS CPU/CoreML/CoreImage; 512px evaluation; no physical display measurement',
            'phase':args.phase,'whiteNits':203,'rows':rows,'summary':summary}
    (args.output/(args.phase+'.json')).write_text(json.dumps(result,indent=2,allow_nan=False))
    if args.phase=='development':
        baseline=summary['production/v11']
        eligible=[k for k,v in summary.items() if v['maeEV']<baseline['maeEV'] and v['puPSNR']>=baseline['puPSNR'] and v['puSSIM']>=baseline['puSSIM']-.002 and v['worstRegressionEV']<=.03 and v['uvError']<=baseline['uvError']+.0001]
        ranked=sorted(summary,key=lambda k:summary[k]['maeEV'])
        shortlist=sorted(eligible,key=lambda k:summary[k]['maeEV'])[:3]
        diagnostic=[k for k in ranked if not k.startswith('production/')][:3]
        coefficients=fit_calibration(samples);cnn=train_residual(samples)
        torch.save(cnn.state_dict(),args.output/'residual.pt')
        lock={'shortlist':shortlist,'diagnostic':diagnostic,'calibration':coefficients.tolist(),'cnnParameters':sum(p.numel() for p in cnn.parameters()),'trainingScenes':[s['meta']['id'] for s in samples],
              'note':'Frozen using development only; learned development results use leave-one-scene-out. Diagnostics are not qualified for promotion.'}
        (args.output/'frozen.json').write_text(json.dumps(lock,indent=2))
        print('Frozen shortlist:',shortlist,'diagnostic:',diagnostic,flush=True)
    print(json.dumps({k:summary[k] for k in sorted(summary,key=lambda k:summary[k]['maeEV'])[:6]},indent=2),flush=True)


if __name__=='__main__':main()
