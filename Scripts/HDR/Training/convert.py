"""Convert an explicit research checkpoint and audit CPU/NE-request numerics.

Does not install a model in the app. CPU_AND_NE is a requested compute policy;
successful prediction is not proof that every operation ran on the Neural Engine.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import time
import numpy as np
import torch
import coremltools as ct
from model import SignedGainNet


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('checkpoint',type=Path); p.add_argument('output',type=Path)
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    torch.set_num_threads(4); torch.manual_seed(20261001)
    state=torch.load(a.checkpoint,map_location='cpu',weights_only=True)
    model=SignedGainNet(state['metadata']['width']).eval(); model.load_state_dict(state['model'])
    sample=(torch.rand(1,3,512,512),torch.rand(1,3,128,128))
    with torch.no_grad(): traced=torch.jit.trace(model,sample)
    converted=ct.convert(traced,inputs=[ct.TensorType(name='image',shape=sample[0].shape),ct.TensorType(name='thumbnail',shape=sample[1].shape)],
                         outputs=[ct.TensorType(name='log_gain')],minimum_deployment_target=ct.target.iOS18,
                         compute_precision=ct.precision.FLOAT16,compute_units=ct.ComputeUnit.CPU_ONLY)
    converted.author='Velyn contributors'; converted.license='MIT'; converted.version='0.1-research'
    converted.short_description='Research-only scalar signed log2 gain; trained from scratch on synthetic CC0 HDR pairs'
    converted.user_defined_metadata['checkpointSHA256']=hashlib.sha256(a.checkpoint.read_bytes()).hexdigest()
    converted.user_defined_metadata['training']='Powered by Poly Haven; https://polyhaven.com; CC0 HDR assets'
    converted.user_defined_metadata['input']='sRGB code values 0..1; image 512 square edge padded; thumbnail 128 square'
    converted.user_defined_metadata['output']='Scalar log2 gain -2..log2(5), broadcast equally to RGB; not normalized PNG samples'
    package=a.output/'SignedGainNet.mlpackage'; converted.save(str(package))
    x=torch.linspace(0,1,512)[None,None,None,:].expand(1,3,512,512).clone()
    cases={'noise':sample,'gradient':(x,torch.nn.functional.interpolate(x,size=(128,128),mode='bilinear',align_corners=False))}
    for value in [0,.18,.5,1]: cases[f'neutral-{value}']=tuple(torch.full_like(t,value) for t in sample)
    rows=[]
    for mode,policy in [('CPU_ONLY',ct.ComputeUnit.CPU_ONLY),('CPU_AND_NE',ct.ComputeUnit.CPU_AND_NE)]:
        runtime=ct.models.MLModel(str(package),compute_units=policy)
        for name,inputs in cases.items():
            with torch.no_grad(): reference=model(*inputs).numpy()
            data={'image':inputs[0].numpy(),'thumbnail':inputs[1].numpy()}
            runtime.predict(data) # compilation/warmup excluded from the five-call timing
            times=[]
            for _ in range(5):
                start=time.perf_counter(); value=runtime.predict(data)['log_gain']; times.append(time.perf_counter()-start)
            error=np.abs(reference-value)
            row={'policy':mode,'case':name,'maxEV':float(error.max()),'meanEV':float(error.mean()),'medianSeconds':float(np.median(times)),
                 'minGainEV':float(value.min()),'maxGainEV':float(value.max())}
            rows.append(row)
            if not np.isfinite(value).all() or error.max()>.06: raise ValueError(f'Conversion failed: {row}')
    report={'scope':'macOS runtime numeric check, synthetic inputs only; not iPhone timing or confirmed operation placement',
            'platform':platform.platform(),'torch':str(torch.__version__),'coremltools':ct.__version__,
            'checkpointSHA256':hashlib.sha256(a.checkpoint.read_bytes()).hexdigest(),
            'precision':'FP16','packageBytes':sum(p.stat().st_size for p in package.rglob('*') if p.is_file()),'comparisons':rows}
    (a.output/'conversion.json').write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report,indent=2))


if __name__=='__main__': main()
