"""Compare explicitly downloaded DITM/HDRUNet weights on local HDR pairs.

No downloads or uploads. All scenes are previously used development data.
HDRUNet has scene-relative targets, so its absolute output is not assumed to
be calibrated in nits. Midtone anchoring uses SDR input only, never reference HDR.
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
from experiment import load
from metrics import LUMA, measure
from prepare_signed_models import verify


def linearize_srgb(rgb):
    """Extended sRGB decoding: preserve model values above display white."""
    return np.where(rgb <= .04045, rgb/12.92, ((rgb+.055)/1.055)**2.4)


def summarize(rows):
    summary = {}
    for name in rows[0]['metrics']:
        summary[name] = {key: float(np.mean([r['metrics'][name][key] for r in rows]))
                         for key in ['maeEV','p95EV','puPSNR','puSSIM','uvError','baseColorShift']}
        deltas = [r['metrics'][name]['maeEV']-r['metrics']['production/current-ne1024']['maeEV'] for r in rows]
        summary[name].update(worstRegressionEV=max(deltas), improvedScenes=sum(d < -1e-5 for d in deltas))
    return summary


def load_models(directory):
    verify(directory)
    sys.path.insert(0, str(directory)); sys.path.insert(0, str(directory/'hdrunet/codes'))
    from ditm import DITM
    from models.modules.UNet_arch import HDRUNet
    # Allow only the checkpoint's known NumPy scalar metadata; never unrestricted pickle.
    with torch.serialization.safe_globals([(np.core.multiarray.scalar, 'numpy._core.multiarray.scalar'),
                                          np.dtype, type(np.dtype(np.float64)), type(np.dtype(np.float32))]):
        checkpoint = torch.load(directory/'team07_ditm.pth', map_location='cpu', weights_only=True)
    ditm = DITM(base=32).eval()
    ditm.load_state_dict({k.removeprefix('module.'):v for k,v in checkpoint['model_state_dict'].items()}, strict=True)
    hdrunet = HDRUNet().eval()
    hdrunet.load_state_dict(torch.load(directory/'hdrunet/pretrained_models/pretrained_model.pth', map_location='cpu', weights_only=True), strict=True)
    return {'ditm': ditm, 'hdrunet': hdrunet}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('models', type=Path); parser.add_argument('fixtures', type=Path)
    parser.add_argument('current', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args(); args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4); models = load_models(args.models)
    rows = []
    for path in sorted(args.fixtures.glob('*/prepared.json')):
        s = load(path.parent); meta = s['meta']; shape = s['y'].shape
        current = np.fromfile(args.current/path.parent.name/'v11.f32',np.float32).reshape(*shape,4)[...,:3].astype(np.float64)
        baseline_gain = np.log2(np.maximum(current@LUMA,1e-8)/s['y'])
        source = np.fromfile(s['root']/'source-srgb.f32',np.float32).reshape(meta['height'],meta['width'],4)[...,:3]
        x = F.interpolate(torch.from_numpy(source.transpose(2,0,1).copy())[None],size=shape,mode='bicubic',align_corners=False).clamp(0,1)
        outputs = {'production/current-ne1024': current}; diagnostics = {}; inference = {}
        predictions = {}
        for name, model in models.items():
            cache = args.output/f'{meta["id"]}-{name}.npy'
            identity = hashlib.sha256(x.numpy().tobytes()+repr(tuple(x.shape)).encode()+name.encode()+b'signed-model-input-v1').hexdigest()
            stamp = cache.with_suffix('.json')
            cached = json.loads(stamp.read_text()) if stamp.exists() else {}
            if cache.exists() and cached.get('inputSHA256') == identity:
                result = np.load(cache)
                inference[name] = cached['inferenceSeconds']
            else:
                start = time.perf_counter()
                with torch.no_grad():
                    if name == 'hdrunet':
                        h,w=shape; padded=F.pad(x,(0,(-w)%4,0,(-h)%4),mode='reflect')
                        prediction=model((padded,padded))[:,:,:h,:w]
                    else: prediction=model(x)
                inference[name] = time.perf_counter()-start
                result=prediction.numpy()[0].transpose(1,2,0)
                assert np.isfinite(result).all()
                np.save(cache,result)
                stamp.write_text(json.dumps({'inputSHA256':identity,'inferenceSeconds':inference[name]})+'\n')
            assert result.shape == (*shape,3) and np.isfinite(result).all()
            predictions[name]=result
        # HDRUNet's paper explicitly uses gamma-corrected HDR targets. The exact
        # transfer curve for arbitrary camera JPEGs is not known. Test extended
        # sRGB and power 2.24; keep the raw interpretation as a diagnostic only.
        predictions['hdrunet-raw-diagnostic'] = predictions.pop('hdrunet')
        predictions['hdrunet-srgb'] = linearize_srgb(np.maximum(predictions['hdrunet-raw-diagnostic'],0))
        predictions['hdrunet-gamma224'] = np.maximum(predictions['hdrunet-raw-diagnostic'],0)**2.24
        for name,result in predictions.items():
            rgb = np.maximum(result.astype(np.float64),1e-8)
            absolute = np.clip(rgb,0,1)*1000/203 if name=='ditm' else rgb
            gain = np.log2(np.maximum(absolute@LUMA,1e-8)/s['y'])
            anchor_pixels = (s['y'] >= .03)&(s['y'] <= .5)&((rgb@LUMA) > 1e-5)
            anchor = float(np.median(gain[anchor_pixels])) if anchor_pixels.sum()>=32 else 0
            anchored = gain-anchor
            def apply(g): return s['base']*np.exp2(np.clip(g,-2,np.log2(5)))[...,None]
            if name=='ditm': outputs[name+'/absolute-rgb']=absolute
            outputs[name+'/signed']=apply(gain)
            outputs[name+'/anchored-signed']=apply(anchored)
            # Numeric, private intermediates for the real Swift storage/export path.
            gains = np.clip(anchored,-2,np.log2(5)).astype('<f4')
            gains.tofile(args.output/f'{meta["id"]}-{name}-signed.f32')
            for strength in [.25,.5,1.0]:
                # Keep the current positive gain; evaluate a conservative attenuation residual.
                correction = np.maximum(np.minimum(anchored,0),-2)*strength
                outputs[name+f'/attenuation-{strength}']=apply(baseline_gain+correction)
            target_gain=np.log2(np.maximum(s['reference']@LUMA,1e-8)/s['y'])
            valid=(s['y']>.01)&((s['reference']@LUMA)>.01)
            predicted=(anchored<-.02)&valid; actual=(target_gain<-.02)&valid
            diagnostics[name]={'anchorEV':anchor,'negativeOutputFraction':float(np.mean(result<0)),
                               'predictedNegativeFraction':float(predicted.sum()/max(1,valid.sum())),
                               'actualNegativeFraction':float(actual.sum()/max(1,valid.sum())),
                               'negativePrecision':float((predicted&actual).sum()/max(1,predicted.sum())),
                               'negativeRecall':float((predicted&actual).sum()/max(1,actual.sum()))}
        rows.append({'id':meta['id'],'metrics':{k:measure(v,s['reference'],s['base']) for k,v in outputs.items()},
                     'diagnostics':diagnostics,'inferenceSeconds':inference})
        report={'protocol':'15 previously used scenes; macOS PyTorch CPU, 512px evaluation; SDR-only median anchoring; no fresh holdout',
                'hdrunetInterpretation':'Nonlinear HDR output (paper sections 1 and 4.1). Extended sRGB and power 2.24 are explicit transfer assumptions; raw interpretation is diagnostic only. No known absolute nit calibration.',
                'parameters':{k:sum(p.numel() for p in m.parameters()) for k,m in models.items()},'rows':rows,'summary':summarize(rows)}
        (args.output/'comparison.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
        print(meta['id'],{k:round(v['maeEV'],4) for k,v in rows[-1]['metrics'].items()},flush=True)
    print(json.dumps(report['summary'],indent=2),flush=True)


if __name__=='__main__':main()
