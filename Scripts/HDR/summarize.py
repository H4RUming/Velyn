"""Export numeric-only experiment evidence; never copy photo-derived rasters."""
from pathlib import Path
import argparse,csv,json
import numpy as np


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('results',type=Path);p.add_argument('output',type=Path);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
    data={phase:json.loads((a.results/(phase+'.json')).read_text()) for phase in ['development','validation']}
    frozen=json.loads((a.results/'frozen.json').read_text())
    assert set(frozen['trainingScenes']).isdisjoint(r['id'] for r in data['validation']['rows'])
    assert [len(data[p]['rows']) for p in data]==[8,7]
    assert all(len(r['metrics'])==68 and r['originalPreserved'] for d in data.values() for r in d['rows'])
    rows=[]
    for phase,d in data.items():
        for scene in d['rows']:
            for name,m in scene['metrics'].items():
                row={'group':phase,'sample':scene['id'],'variant':name}
                row.update({k:v for k,v in m.items() if k!='regions'})
                row.update({region+'MAE':v['maeEV'] for region,v in m['regions'].items()})
                row.update({region+'Pixels':v['pixels'] for region,v in m['regions'].items()})
                row.update({'white100PSNR':scene['white100'][name]['puPSNR'],'white100SSIM':scene['white100'][name]['puSSIM']})
                rows.append(row)
    with (a.output/'hdr-experiment-results.csv').open('w') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    codec=json.loads((a.results/'roundtrip.json').read_text())
    assert len(codec)==37 and all(v['hasGainMap'] for r in codec for v in r['formats'].values())
    summary={'environment':data['development']['environment'],'whiteNits':[203,100],'variantsPerImage':68,'developmentImages':8,'validationImages':7,
             'frozenShortlist':frozen['shortlist'],'diagnosticOnly':frozen['diagnostic'],'cnnParameters':frozen['cnnParameters'],
             'summary':{phase:d['summary'] for phase,d in data.items()},
             'inputTimingSeconds':{mode:float(np.mean([r['inputSeconds'][mode] for d in data.values() for r in d['rows']])) for mode in data['development']['rows'][0]['inputSeconds']},
             'codec':{format:{'files':len(codec),'meanHDRMAE':float(np.mean([r['formats'][format]['hdrMAE'] for r in codec])),
                              'worstHDRMAE':max(r['formats'][format]['hdrMAE'] for r in codec),
                              'meanSDRMAE':float(np.mean([r['formats'][format]['sdrMAE'] for r in codec]))} for format in ['jpeg','heic']},
             'representationLimits':json.loads((a.results/'representation-limits.json').read_text()),
             'syntheticSignedRoundtrip':json.loads((a.results/'signed-roundtrip.json').read_text()),
             'limitations':['Small convenience sample; validation and part of development share a source repository.','Learned development scores are leave-one-image-out; validation uses weights fit on all eight development images.','512px evaluation and sampled Python candidates are not full-resolution production validation.','No physical-device display, thermal, or NPU acceptance.','No candidate was deployed or published in an app release.']}
    (a.output/'hdr-experiment-summary.json').write_text(json.dumps(summary,indent=2,allow_nan=False))
    print('Validated 15 original-preservation checks, 1020 image/variant rows, 74 codec files; wrote numeric-only evidence.')


if __name__=='__main__':main()
