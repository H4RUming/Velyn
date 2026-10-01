"""Explicit CC0 HDR download and scene-grouped perspective fixtures.

Powered by Poly Haven (https://polyhaven.com). Network is developer-only.
No user photos, app library, credentials or automatic app downloads are used.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import math
from pathlib import Path
import re
import time
import urllib.request
import numpy as np
from scipy.ndimage import map_coordinates
import OpenEXR

AGENT='VelynHDRResearch/0.1 (+https://github.com/H4RUming/Velyn)'
SEED=20261001
LUMA=np.array([.2126,.7152,.0722],np.float32)


def fetch(url,path,expected_md5=None):
    if path.exists():
        data=path.read_bytes()
        if expected_md5 is None or hashlib.md5(data).hexdigest()==expected_md5: return data
        raise ValueError(f'Changed download: {path.name}')
    path.parent.mkdir(parents=True,exist_ok=True)
    for attempt in range(4):
        try:
            request=urllib.request.Request(url,headers={'User-Agent':AGENT})
            with urllib.request.urlopen(request,timeout=60) as response: data=response.read()
            if expected_md5 and hashlib.md5(data).hexdigest()!=expected_md5: raise ValueError('MD5 mismatch')
            temp=path.with_suffix(path.suffix+'.part'); temp.write_bytes(data); temp.replace(path)
            return data
        except Exception:
            if attempt==3: raise
            time.sleep(2**attempt)


def groups(catalog):
    # Connected components join nearby captures and names in the same capture
    # family before splitting. Never split crops from one location across sets.
    ids=sorted(catalog); parent=list(range(len(ids)))
    def root(i):
        while parent[i]!=i:
            parent[i]=parent[parent[i]]; i=parent[i]
        return i
    def join(i,j): parent[root(j)]=root(i)
    def family(name):
        tokens=[s for s in name.split('_') if not s.isdigit() and s not in {'dawn','dusk','sunrise','sunset','noon','night','morning','afternoon','overcast','clear'}]
        return '_'.join(tokens[:2])
    for i,a in enumerate(ids):
        for j in range(i):
            b=ids[j]
            near=False
            ca,cb=catalog[a].get('coords'),catalog[b].get('coords')
            if ca and cb and len(ca)==2 and len(cb)==2 and any(ca) and any(cb):
                dy=(ca[0]-cb[0])*111.2; dx=(ca[1]-cb[1])*111.2*math.cos(math.radians((ca[0]+cb[0])/2))
                near=dx*dx+dy*dy<4 # two kilometres, including adjacent coordinate cells
            if near or family(a)==family(b): join(i,j)
    result={}
    for i,name in enumerate(ids): result.setdefault(ids[root(i)],[]).append(name)
    return result


def project(rgb,yaw,pitch,size=256,fov=90):
    y,x=np.mgrid[0:size,0:size].astype(np.float32)
    x=(2*(x+.5)/size-1)*math.tan(math.radians(fov/2))
    y=-(2*(y+.5)/size-1)*math.tan(math.radians(fov/2))
    z=np.ones_like(x)
    p=math.radians(pitch); yy=y*math.cos(p)+z*math.sin(p); zz=-y*math.sin(p)+z*math.cos(p)
    a=math.radians(yaw); xx=x*math.cos(a)+zz*math.sin(a); zz=-x*math.sin(a)+zz*math.cos(a)
    longitude=np.arctan2(xx,zz); latitude=np.arctan2(yy,np.sqrt(xx*xx+zz*zz))
    h,w=rgb.shape[:2]; u=(longitude/(2*math.pi)+.5)*w-.5; v=(.5-latitude/math.pi)*h-.5
    # Wrap longitude only; polar samples clamp vertically.
    padded=np.concatenate([rgb[:,-1:],rgb,rgb[:,:1]],axis=1)
    return np.stack([map_coordinates(padded[...,c],[np.clip(v,0,h-1),np.mod(u,w)+1],order=1,mode='nearest') for c in range(3)],axis=-1)


def prepare_one(row,output,views):
    name=row['id']; time.sleep(.4)
    if 'sourceURL' in row:
        item={'url':row['sourceURL'],'md5':row['md5']}
    else:
        files=json.loads(fetch('https://api.polyhaven.com/files/'+name,output/'metadata'/f'{name}.json'))
        item=files['hdri']['1k']['exr']
    url=item['url']
    if not url.startswith('https://dl.polyhaven.org/'): raise ValueError('Unexpected asset host')
    path=output/'originals'/f'{name}.exr'; data=fetch(url,path,item['md5'])
    if 'sha256' in row and hashlib.sha256(data).hexdigest()!=row['sha256']: raise ValueError('Source SHA-256 mismatch')
    with OpenEXR.File(str(path)) as f:
        channels=f.channels()
        if 'RGB' in channels: rgb=channels['RGB'].pixels.astype(np.float32)
        elif 'RGBA' in channels: rgb=channels['RGBA'].pixels[...,:3].astype(np.float32)
        else: rgb=np.stack([channels[k].pixels for k in 'RGB'],axis=-1).astype(np.float32)
    if not np.isfinite(rgb).all() or rgb.ndim!=3 or rgb.shape[2]!=3: raise ValueError('Invalid HDR image')
    rgb=np.maximum(rgb,0)
    rng=np.random.default_rng(int(hashlib.sha256(name.encode()).hexdigest()[:8],16))
    records=[]
    for index in range(views):
        yaw=float(rng.uniform(0,360/ views)+index*360/views); pitch=float(rng.uniform(-12,18))
        image=project(rgb,yaw,pitch)
        white=float(np.quantile(image@LUMA,.95))
        if white<1e-6: continue
        image=np.clip(image*(.8/white),0,64).astype(np.float16)
        relative=f'views/{name}-{index}.npy'; target=output/relative; target.parent.mkdir(exist_ok=True)
        np.save(target,image)
        records.append({'id':f'{name}-{index}','asset':name,'group':row['group'],'split':row['split'],'path':relative,
                        'yaw':yaw,'pitch':pitch,'normalizationWhite':white})
    return {'id':name,'group':row['group'],'split':row['split'],'sourceURL':url,'license':'CC0-1.0',
            'md5':item['md5'],'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'views':records}


def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('output',type=Path)
    p.add_argument('--limit',type=int,default=500); p.add_argument('--views',type=int,default=3); p.add_argument('--workers',type=int,default=2)
    p.add_argument('--frozen-manifest',type=Path,help='Rebuild the recorded split and sources without querying the live catalog')
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    print('Powered by Poly Haven — CC0 HDRIs; https://polyhaven.com',flush=True)
    if a.frozen_manifest:
        frozen=json.loads(a.frozen_manifest.read_text())
        plan={k:v for k,v in frozen.items() if k not in {'sources','failures'}}
        if frozen['failures'] or len(frozen['sources'])!=len(frozen['selected']): raise ValueError('Incomplete frozen dataset')
        rows=frozen['sources']; a.views=plan['viewsPerSource']
        if any(not re.fullmatch('[a-z0-9_]+',r['id']) for r in rows): raise ValueError('Invalid asset ID')
    else:
        catalog=json.loads(fetch('https://api.polyhaven.com/assets?t=hdris',a.output/'catalog.json'))
        catalog={k:v for k,v in catalog.items() if v.get('date_published',0)<=time.time() and re.fullmatch('[a-z0-9_]+',k)}
        grouped=groups(catalog)
        ordered=sorted(grouped,key=lambda k:hashlib.sha256((str(SEED)+k).encode()).hexdigest())[:a.limit]
        rows=[]
        for i,group in enumerate(ordered):
            # One panorama per location group. Choose reproducibly without quality labels.
            name=min(grouped[group],key=lambda k:hashlib.sha256(k.encode()).hexdigest())
            split='test' if i%10==0 else 'validation' if i%10==1 else 'train'
            rows.append({'id':name,'group':group,'split':split})
        plan={'seed':SEED,'catalogAssets':len(catalog),'locationGroups':len(grouped),'selected':rows,'viewsPerSource':a.views,
              'licenseURL':'https://polyhaven.com/license','apiTermsURL':'https://github.com/Poly-Haven/Public-API/blob/master/ToS.md',
              'protocol':'One panorama per 2km/name connected group. Grouped split before perspective projection. Synthesized SDR labels; not camera-native SDR/HDR pairs.'}
    plan_path=a.output/'plan.json'
    if plan_path.exists() and json.loads(plan_path.read_text())!=plan: raise ValueError('Refusing to change existing split; use a new output directory')
    plan_path.write_text(json.dumps(plan,indent=2)+'\n')
    print(f'{plan["catalogAssets"]} assets, {plan["locationGroups"]} groups, {len(rows)} chosen',flush=True)
    complete=[]; failures=[]
    with ThreadPoolExecutor(max_workers=a.workers) as pool:
        tasks={pool.submit(prepare_one,r,a.output,a.views):r for r in rows}
        for future in as_completed(tasks):
            row=tasks[future]
            try:
                complete.append(future.result()); print(f'Prepared {len(complete)}/{len(rows)} {row["id"]}',flush=True)
            except Exception as e:
                failures.append({'id':row['id'],'error':str(e)}); print(f'Failed {row["id"]}: {e}',flush=True)
            result={**plan,'sources':sorted(complete,key=lambda r:r['id']),'failures':failures}
            temp=a.output/'manifest.tmp'; temp.write_text(json.dumps(result,indent=2)+'\n'); temp.replace(a.output/'manifest.json')
    if len(complete)<len(rows)*.95: raise RuntimeError('More than 5% of sources failed; do not train on a silently incomplete collection')
    print('Complete',len(complete),'sources',sum(len(r['views']) for r in complete),'views',flush=True)


if __name__=='__main__': main()
