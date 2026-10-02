"""Convert an explicitly selected private GMNet checkpoint, without app install.

Uses the existing equivalent static-kernel implementation and retains the original
MIT attribution. Global operators stay FP32, as in Velyn's calibrated GMNet path.
"""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import sys
import time
import numpy as np
import torch
import coremltools as ct
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Models'))
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Models/gmnet'))
from gain_conversion import StaticKernelGMNet
from gmnet.GMNet import GMNet
from train_gmnet_camera import ORIGINAL_SHA,MAX_EV


class Gain(torch.nn.Module):
    def __init__(self,net):super().__init__();self.net=net
    def forward(self,image,thumbnail):return self.net((image,thumbnail))[1].clamp(0,1)*MAX_EV


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('checkpoint',type=Path);p.add_argument('output',type=Path)
    p.add_argument('--size',type=int,choices=[512,1024],default=1024)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);torch.set_num_threads(4);torch.manual_seed(20261002)
    state=torch.load(a.checkpoint,map_location='cpu',weights_only=True)
    if state['metadata'].get('family')!='GMNet' or state['metadata']['initialSHA256']!=ORIGINAL_SHA:raise ValueError('Unknown checkpoint origin')
    original=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).eval();original.load_state_dict(state['model'],strict=True)
    net=StaticKernelGMNet(in_nc=3,out_nc=1,nf=64,nb=16).eval();net.load_state_dict(state['model'],strict=True)
    net.sq_ker.pool=torch.nn.AvgPool2d(22,stride=21)
    model=Gain(net).eval();reference=Gain(original).eval()
    sample=(torch.rand(1,3,a.size,a.size),torch.rand(1,3,256,256))
    x=torch.linspace(0,1,a.size)[None,None,None,:].expand(1,3,a.size,a.size).clone()
    cases={'noise':sample,'gradient':(x,torch.nn.functional.interpolate(x,size=(256,256),mode='bilinear',align_corners=False))}
    for value in [0,.18,.5,1]:cases[f'neutral-{value}']=tuple(torch.full_like(v,value) for v in sample)
    static_errors=[]
    with torch.no_grad():
        for name,inputs in cases.items():
            error=float((reference(*inputs)-model(*inputs)).abs().max());static_errors.append({'case':name,'maxEV':error})
            if error>1e-4:raise ValueError('Static-kernel equivalence failed')
        traced=torch.jit.trace(model,sample)
    def use_half(op):
        names=[v for k,values in op.scopes.items() if k.name=='TORCHSCRIPT_MODULE_NAME' for v in values]
        return not any(v in ['down1','down2','res_y','sq_ker','sq_chn','sq_qmax'] for v in names)
    converted=ct.convert(traced,inputs=[ct.TensorType(name='image',shape=sample[0].shape),ct.TensorType(name='thumbnail',shape=sample[1].shape)],
                         outputs=[ct.TensorType(name='log_gain')],minimum_deployment_target=ct.target.iOS18,
                         compute_precision=ct.transform.FP16ComputePrecision(op_selector=use_half),compute_units=ct.ComputeUnit.CPU_ONLY)
    converted.author='Yinuo Liao et al.; fine-tuning and conversion by Velyn'
    converted.license='MIT; Copyright (c) 2025 Yinuo Liao';converted.version='research-camera-v1'
    converted.short_description='Private camera-adapted GMNet; research candidate, not the app default'
    digest=hashlib.sha256(a.checkpoint.read_bytes()).hexdigest()
    converted.user_defined_metadata['checkpointSHA256']=digest
    converted.user_defined_metadata['input']=f'sRGB 0..1; {a.size}px square edge-padded local image; 256px full-image thumbnail'
    converted.user_defined_metadata['output']='Positive scalar log2 gain 0..log2(5), broadcast equally to RGB'
    package=a.output/'GMNetCamera.mlpackage';converted.save(str(package));rows=[]
    for name,policy in [('CPU_ONLY',ct.ComputeUnit.CPU_ONLY),('CPU_AND_NE',ct.ComputeUnit.CPU_AND_NE)]:
        runtime=ct.models.MLModel(str(package),compute_units=policy)
        for case,inputs in cases.items():
            with torch.no_grad():truth=reference(*inputs).numpy()
            data={'image':inputs[0].numpy(),'thumbnail':inputs[1].numpy()};runtime.predict(data);times=[]
            for _ in range(3):
                start=time.perf_counter();prediction=runtime.predict(data)['log_gain'];times.append(time.perf_counter()-start)
            diff=np.abs(prediction-truth)
            row={'policy':name,'case':case,'maxEV':float(diff.max()),'meanEV':float(diff.mean()),'medianSeconds':float(np.median(times))}
            rows.append(row)
            if not np.isfinite(prediction).all() or diff.max()>.06:raise ValueError(f'Conversion check failed: {row}')
    report={'scope':'Mac synthetic tensor comparison; not iPhone timing, display acceptance or proof of all-NE placement',
            'platform':platform.platform(),'checkpointSHA256':digest,'inputSize':a.size,'precision':'FP32 global / FP16 local',
            'packageBytes':sum(p.stat().st_size for p in package.rglob('*') if p.is_file()),'staticEquivalence':static_errors,'comparisons':rows}
    (a.output/'conversion.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n');print(json.dumps(report,indent=2))


if __name__=='__main__':main()
