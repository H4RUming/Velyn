"""Post-selection representation diagnostics, not another fitted candidate.

An oracle uses the known reference only to quantify what a representation cannot
express. It is not a predictor or an eligible production treatment.
"""
from pathlib import Path
import argparse,json
import numpy as np
from experiment import load
from metrics import LUMA


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('fixtures',type=Path);p.add_argument('output',type=Path);p.add_argument('codec_directory',type=Path);a=p.parse_args()
    rows=[]
    for path in sorted(a.fixtures.glob('*/prepared.json')):
        s=load(path.parent);y=s['y'];r=np.maximum(s['reference']@LUMA,1e-8);mask=(y>.01)&(r>.01);target=np.log2(r/y)
        rows.append({'id':s['meta']['id'],'group':s['meta']['group'],
                     'scalarGain5xMAEFloor':float(np.abs(np.clip(target,0,np.log2(5))-target)[mask].mean()),
                     'signedQuarterTo8xMAEFloor':float(np.abs(np.clip(target,-2,3)-target)[mask].mean()),
                     'negativeReferenceGainFraction':float(np.mean(target[mask]<-.02)),
                     'referenceGainAbove5xFraction':float(np.mean(target[mask]>np.log2(5))),
                     'referenceBeyondPU21Fraction':float(np.mean(r*203>10000))})
    a.output.write_text(json.dumps(rows,indent=2))
    # Generated neutral ramp with gain 0.5x on the left and 4x on the right.
    # This checks whether ImageIO can preserve attenuation without a color cast.
    folder=a.codec_directory/'synthetic-signed';folder.mkdir(parents=True,exist_ok=True)
    w,h=256,128;y=np.tile(np.linspace(.1,1,w,dtype=np.float32),(h,1))
    rgb=np.repeat(y[...,None],3,-1);gain=np.ones((h,w,1),np.float32)*4;gain[:,:w//2]=.5
    for name,image in [('base',rgb),('candidate',rgb*gain)]:
        np.concatenate([image,np.ones((h,w,1),np.float32)],-1).astype(np.float32).tofile(folder/(name+'.f32'))
    (folder/'dimensions.json').write_text(json.dumps({'width':w,'height':h}))
    print('Representation bounds and synthetic signed-gain fixture written')


if __name__=='__main__':main()
