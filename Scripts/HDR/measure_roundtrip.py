"""Compare decoded HDR to its actual candidate, and decoded SDR to its SDR base."""
from pathlib import Path
import argparse,json
import numpy as np
from metrics import measure


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('candidates',type=Path);p.add_argument('signed',type=Path);p.add_argument('results',type=Path);a=p.parse_args()
    rows=[]
    for path in sorted(a.candidates.glob('*/roundtrip.json')):
        root=path.parent;d=json.loads((root/'dimensions.json').read_text());shape=(d['height'],d['width'],4)
        def rgb(name):return np.fromfile(root/(name+'.f32'),np.float32).reshape(shape)[...,:3].astype(float)
        base,candidate=rgb('base'),rgb('candidate');row={'id':root.name,'formats':{}}
        for format in ['jpeg','heic']:
            hdr=measure(rgb(format+'-hdr'),candidate,base);sdr=measure(rgb(format+'-sdr'),base,base)
            row['formats'][format]={'hdrMAE':hdr['maeEV'],'hdrP95':hdr['p95EV'],'hdrUV':hdr['uvError'],
                                    'sdrMAE':sdr['maeEV'],'hasGainMap':json.loads(path.read_text())[format]['hasGainMap']}
        rows.append(row)
    (a.results/'roundtrip.json').write_text(json.dumps(rows,indent=2))
    p=a.signed/'synthetic-signed';base=np.fromfile(p/'base.f32',np.float32).reshape(128,256,4);signed={}
    for format in ['jpeg','heic']:
        decoded=np.fromfile(p/(format+'-hdr.f32'),np.float32).reshape(128,256,4)
        gain=decoded[:,:,:3].mean(-1)/base[:,:,:3].mean(-1)
        v={'leftGain':float(np.median(gain[8:-8,8:120])),'rightGain':float(np.median(gain[8:-8,136:-8])),
           'maxNeutralChannelSpread':float(np.max(np.ptp(decoded[:,:,:3],axis=2)))}
        assert abs(v['leftGain']-.5)<.03 and abs(v['rightGain']-4)<.15 and v['maxNeutralChannelSpread']<.02
        signed[format]=v
    (a.results/'signed-roundtrip.json').write_text(json.dumps(signed,indent=2))
    print(f'Measured {len(rows)*2} photo exports; signed synthetic JPEG/HEIC neutral checks passed')


if __name__=='__main__':main()
