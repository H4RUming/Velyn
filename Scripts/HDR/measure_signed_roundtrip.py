"""Export numeric-only signed-model storage/codec evidence. No photo pixels."""
import argparse
import json
from pathlib import Path
import numpy as np
from metrics import LUMA


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('roundtrips',type=Path); p.add_argument('predictions',type=Path); p.add_argument('output',type=Path)
    a=p.parse_args(); records=json.loads((a.roundtrips/'roundtrip.json').read_text())
    for r in records:
        folder=a.roundtrips/(r['id']+'-'+r['model']); h,w=r['height'],r['width']
        def pixels(name):
            v=np.fromfile(folder/(name+'.f32'),np.float32).reshape(h,w,4)[...,:3].astype(np.float64)
            assert np.isfinite(v).all()
            return v
        base=pixels('sdr-rendered'); rendered=pixels('rendered'); preview=pixels('preview')
        ev=np.fromfile(a.predictions/(r['id']+'-'+r['model']+'-signed.f32'),np.float32).reshape(h,w)
        expected=base*np.exp2(ev)[...,None]
        valid=(base@LUMA>.01)&(rendered@LUMA>.01)
        def error(x,y,mask=valid):
            d=np.abs(np.log2(np.maximum(x@LUMA,1e-8)/np.maximum(y@LUMA,1e-8)))
            return {'meanEV':float(d[mask].mean()),'p95EV':float(np.percentile(d[mask],95))}
        r['storageAndRender']=error(rendered,expected)
        r['preview']=error(preview,rendered)
        for fmt in ['jpg','heic']:
            if r[fmt].get('rejected',False): continue
            decoded=pixels(fmt+'-hdr'); sdr=pixels(fmt+'-sdr')
            r[fmt]['hdrError']=error(decoded,rendered)
            r[fmt]['sdrError']=error(sdr,base)
            negative=(ev<-.02)&valid
            r[fmt]['negativeRegionError']=error(decoded,rendered,negative) if negative.any() else None
            r[fmt]['negativePreservedFraction']=float(((decoded@LUMA < (sdr@LUMA)*.99)&negative).sum()/max(1,negative.sum()))
    result={'environment':'macOS 27 / Apple M2; ImageIO eager HDR/SDR decode; 512px aligned private photo fixtures; not physical iPhone acceptance',
            'rows':records,'attemptedExports':len(records)*2,
            'rejectedExports':sum(r[f].get('rejected',False) for r in records for f in ['jpg','heic']),
            'allSuccessfulExportsHaveGainMaps':all(r[f]['hasGainMap'] for r in records for f in ['jpg','heic'] if not r[f].get('rejected',False)),
            'allOriginalsPreserved':all(r['originalPreserved'] for r in records)}
    a.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='rows'},indent=2))
    for stage in ['storageAndRender','preview']:
        print(stage,'worst scene mean EV',max(r[stage]['meanEV'] for r in records))
    for fmt in ['jpg','heic']:
        successful=[r for r in records if not r[fmt].get('rejected',False)]
        if successful:
            print(fmt,'worst scene HDR mean EV',max(r[fmt]['hdrError']['meanEV'] for r in successful),
                  'mean negative preserved',np.mean([r[fmt]['negativePreservedFraction'] for r in successful]))


if __name__=='__main__':main()
