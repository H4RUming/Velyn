"""Convert pinned GMNet real-world checkpoint to a local, bounded Core ML model.
Requires torch==2.7.0 coremltools==9.0 numpy==1.26.4. See gmnet/LICENSE.
No photographs, downloads or training are performed by this script.
"""
from pathlib import Path
import argparse, hashlib, json, math, sys
import numpy as np
import torch
import coremltools as ct
sys.path.insert(0,str(Path(__file__).parent/'gmnet'))
from GMNet import GMNet
from gain_conversion import StaticKernelGMNet

parser=argparse.ArgumentParser()
parser.add_argument('checkpoint',type=Path)
parser.add_argument('--output',type=Path,default=Path('Velyn/Models/VelynGainMap.mlpackage'))
parser.add_argument('--report',type=Path,default=Path('.work/gmnet/conversion.json'))
parser.add_argument('--size',type=int,choices=[512,1024],default=512)
parser.add_argument('--static-kernel',action='store_true')
parser.add_argument('--precise-global',action='store_true')
args=parser.parse_args()
expected='83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f'
assert hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()==expected
net=(StaticKernelGMNet if args.static_kernel else GMNet)(in_nc=3,out_nc=1,nf=64,nb=16).eval()
net.load_state_dict(torch.load(args.checkpoint,map_location='cpu',weights_only=True),strict=True)
# For the fixed 256 thumbnail, downsampling produces 64x64. This is exactly
# AdaptiveAvgPool2d(3): bins [0:22], [21:43], [42:64], supported by Core ML.
net.sq_ker.pool=torch.nn.AvgPool2d(22,stride=21)
class Wrapper(torch.nn.Module):
    def __init__(self,net): super().__init__();self.net=net
    def forward(self,image,thumbnail):
        _,normalized_log_gain=self.net((image,thumbnail))
        return torch.clamp(normalized_log_gain,0,1)*math.log2(5)
model=Wrapper(net).eval()
torch.set_num_threads(4);torch.manual_seed(20260929)
sample=(torch.rand(1,3,args.size,args.size),torch.rand(1,3,256,256))
with torch.no_grad(): traced=torch.jit.trace(model,sample)
if args.static_kernel:
    original=GMNet(in_nc=3,out_nc=1,nf=64,nb=16).eval()
    original.load_state_dict(net.state_dict(),strict=True)
    with torch.no_grad():
        for level in [None,0.0,0.5,1.0]:
            inputs=sample if level is None else tuple(torch.full_like(t,level) for t in sample)
            error=(Wrapper(original)(*inputs)-model(*inputs)).abs().max().item()
            assert error<0.0001,('static kernel equivalence',level,error)
def use_half(op):
    scope=[value for key,values in op.scopes.items() if key.name=='TORCHSCRIPT_MODULE_NAME' for value in values]
    return not any(s in ['down1','down2','res_y','sq_ker','sq_chn','sq_qmax'] for s in scope)
precision=ct.transform.FP16ComputePrecision(op_selector=use_half) if args.precise_global else ct.precision.FLOAT16
converted=ct.convert(traced,inputs=[ct.TensorType(name='image',shape=sample[0].shape),ct.TensorType(name='thumbnail',shape=sample[1].shape)],outputs=[ct.TensorType(name='log_gain')],minimum_deployment_target=ct.target.iOS18,compute_precision=precision,compute_units=ct.ComputeUnit.CPU_AND_GPU)
converted.author='Yinuo Liao et al.; Core ML conversion by Velyn'
converted.license='MIT; Copyright (c) 2025 Yinuo Liao'
converted.short_description='GMNet real-world SDR-to-HDR log2 gain prediction; on-device only'
converted.version='1.0'
converted.user_defined_metadata['source']='qtlark/GMNet@59db6aac16f8fa7071a9447e357d9e7316ce0f8c'
converted.user_defined_metadata['input']=f'RGB sRGB code values 0...1; local {args.size} square edge padded; global 256 square'
converted.user_defined_metadata['output']='Per-pixel log2 brightness ratio, bounded to 0...log2(5)'
args.output.parent.mkdir(parents=True,exist_ok=True);converted.save(str(args.output))
errors=[]
# Validate conversion on CPU; accelerator correctness is checked separately on device.
converted=ct.models.MLModel(str(args.output),compute_units=ct.ComputeUnit.CPU_ONLY)
for level in [None,0.0,0.5,1.0]:
    inputs=sample if level is None else (torch.full_like(sample[0],level),torch.full_like(sample[1],level))
    with torch.no_grad(): reference=model(*inputs).numpy()
    prediction=converted.predict({'image':inputs[0].numpy(),'thumbnail':inputs[1].numpy()})['log_gain']
    assert np.isfinite(prediction).all()
    diff=np.abs(reference-prediction)
    errors.append({'input':level,'max_error_ev':float(diff.max()),'mean_error_ev':float(diff.mean()),'min_gain_ev':float(prediction.min()),'max_gain_ev':float(prediction.max())})
    assert diff.max()<0.06,errors[-1]
report={'parameters':sum(p.numel() for p in net.parameters()),'checkpoint_sha256':expected,'local_size':args.size,'static_kernel':args.static_kernel,'coreml_precision':'global FP32/local FP16' if args.precise_global else 'FLOAT16','comparisons':errors}
args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
