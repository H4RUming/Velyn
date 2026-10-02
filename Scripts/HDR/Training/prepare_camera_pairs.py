"""Prepare explicitly authorized private camera pairs; keep output outside Git.

Only anonymous IDs, split groups and required pixel tensors leave this tool.
Original file names, EXIF dates, location and camera metadata are not exported.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import numpy as np
from scipy.fft import dctn
import torch
import torch.nn.functional as F

LUMA=np.array([.2126,.7152,.0722],np.float32)


def encode(x): return np.where(x<=.0031308,12.92*x,1.055*np.maximum(x,0)**(1/2.4)-.055)


def resize(x,size):
    return F.interpolate(torch.from_numpy(x.copy())[None],size=size,mode='bilinear',align_corners=False).numpy()[0]


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('decoded',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False,mode=0o700);torch.set_num_threads(2)
    rows=json.loads((a.decoded/'decoded.json').read_text()); accepted=[]; rejected=Counter()
    for row in rows:
        if row['status']!='decoded':rejected[row['status']]+=1;continue
        h,w=row['height'],row['width'];folder=a.decoded/row['id']
        base=np.fromfile(folder/'base.f32',np.float32).reshape(h,w,4)[...,:3]
        ref=np.fromfile(folder/'reference.f32',np.float32).reshape(h,w,4)[...,:3]
        y=np.maximum(base@LUMA,1e-7);ry=np.maximum(ref@LUMA,1e-7)
        target=np.log2(ry/y);valid=(y>.01)&(ry>.01)
        if not np.isfinite(target).all() or valid.mean()<.05:rejected['invalid-pair']+=1;continue
        if np.mean(np.abs(target[valid]))<.005:rejected['identical-SDR-HDR']+=1;continue
        rgb=np.round(encode(base).clip(0,1)*255).astype(np.uint8).transpose(2,0,1)
        thumb=np.round(resize(rgb.astype(np.float32),(128,128))).clip(0,255).astype(np.uint8)
        small=resize((y[None]**(1/2.2)).astype(np.float32),(32,32))[0]
        freq=dctn(small,type=2,norm='ortho')[:8,:8].ravel()[1:]
        phash=freq>np.median(freq)
        dh,dw=512-h,512-w
        if dh<0 or dw<0:raise ValueError('Unexpected decoding size')
        pads=((dh//2,dh-dh//2),(dw//2,dw-dw//2))
        image=np.pad(rgb,((0,0),*pads),mode='edge')
        gain=np.pad(target,pads,mode='edge').astype(np.float16)
        mask=np.pad(valid,pads,mode='constant')
        path=a.output/(row['id']+'.npz')
        np.savez_compressed(path,rgb=image,thumbnail=thumb,gain=gain,valid=mask,
                            luminance=np.pad(y,pads,mode='edge').astype(np.float16),shape=np.array([h,w],np.int32))
        accepted.append({'id':row['id'],'captureDay':row.get('captureTime','')[:10],
                         'phash':phash,'path':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
                         'negativeFraction':float((target[valid]<-.05).mean()),
                         'outOfRangeFraction':float(((target[valid]<-2)|(target[valid]>np.log2(5))).mean())})
    n=len(accepted);parent=list(range(n))
    def root(i):
        while parent[i]!=i:parent[i]=parent[parent[i]];i=parent[i]
        return i
    # Conservative same-day grouping plus cross-day visual duplicate protection.
    for i in range(n):
        for j in range(i):
            day=accepted[i]['captureDay']
            same_day=bool(day) and day==accepted[j]['captureDay']
            similar=np.count_nonzero(accepted[i]['phash']!=accepted[j]['phash'])<=6
            if same_day or similar:parent[root(i)]=root(j)
    groups={}
    for i in range(n):groups.setdefault(root(i),[]).append(i)
    if len(groups)<10:raise ValueError('Too few independent capture groups for train/validation/test')
    rng=np.random.default_rng(20261002);items=list(groups.values());rng.shuffle(items);items.sort(key=len,reverse=True)
    counts={k:0 for k in ['train','validation','test']};targets={'train':n*.7,'validation':n*.15,'test':n*.15};records=[]
    for group_id,members in enumerate(items):
        split=max(counts,key=lambda k:targets[k]-counts[k]);counts[split]+=len(members)
        for i in members:
            r=accepted[i]
            records.append({k:r[k] for k in ['id','path','sha256']}|{'group':f'group-{group_id:04d}','split':split})
    if min(counts.values())<20:raise ValueError('Split too small for a meaningful pilot')
    manifest={'schema':'private-camera-pairs-v1','seed':20261002,'samples':sorted(records,key=lambda r:r['id']),
              'protocol':'macOS ImageIO embedded SDR and HDR decode; linear sRGB luminance ratio. Same capture day or pHash distance <=6 stays in one split. EXIF removed before transfer.',
              'counts':counts,'groups':{k:len({r['group'] for r in records if r['split']==k}) for k in counts}}
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    summary={'imagesScanned':len(rows),'acceptedPairs':n,'rejected':dict(rejected),'splitImages':counts,'splitGroups':manifest['groups'],
             'meanNegativeFraction':float(np.mean([r['negativeFraction'] for r in accepted])),
             'meanOutOfRangeFraction':float(np.mean([r['outOfRangeFraction'] for r in accepted]))}
    (a.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))


if __name__=='__main__':main()
