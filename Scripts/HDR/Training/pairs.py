"""Deterministic on-GPU HDR-to-SDR degradations for a bounded pilot.

These synthetic tone recipes are not a camera ISP, and do not supply native
camera labels. Fixed evaluation seeds are separate from training augmentation.
"""
import torch
import torch.nn.functional as F
from model import MIN_EV, MAX_EV


def linearize(x): return torch.where(x<=.04045,x/12.92,((x+.055)/1.055).pow(2.4))
def encode(x): return torch.where(x<=.0031308,12.92*x,1.055*x.clamp_min(0).pow(1/2.4)-.055)
def luminance(x): return (x*x.new_tensor([.2126,.7152,.0722])[None,:,None,None]).sum(1,keepdim=True)


def make_pairs(hdr,seed):
    rng=torch.Generator(device=hdr.device).manual_seed(seed)
    n=hdr.shape[0]
    def uniform(a,b): return a+(b-a)*torch.rand((n,1,1,1),generator=rng,device=hdr.device)
    # Simulate modest exposure and WB variety before the shared scalar tone map.
    h=hdr.float()*torch.exp2(uniform(-1,1))
    wb=.9+.2*torch.rand((n,3,1,1),generator=rng,device=hdr.device)
    h=h*wb
    y=luminance(h).clamp_min(1e-7)
    # Smooth highlight compression bounds the reference but retains HDR contrast.
    reference_y=8*y/(8+y)
    reference=h*(reference_y/y)
    y=reference_y
    mode=torch.rand((n,1,1,1),generator=rng,device=hdr.device)
    knee=uniform(.5,1.5)
    positive=y/(1+y/knee)
    # 55% positive-only; 25% shadow lift; 10% local contrast; 10% identity SDR.
    lifted=positive.clamp_min(1e-7).pow(uniform(.65,.9))
    low=F.interpolate(F.avg_pool2d(torch.log2(y),16),size=y.shape[-2:],mode='bilinear',align_corners=False)
    local=positive*torch.exp2((-low-2).clamp(-1,1)*uniform(.1,.35))
    sdr_y=torch.where(mode<.55,positive,torch.where(mode<.8,lifted,torch.where(mode<.9,local,y)))
    sdr=(reference*(sdr_y/y)).clamp(0,1)
    rgb=encode(sdr).clamp(0,1)
    # Quantization plus small bounded sensor/codec-like perturbation; target is
    # computed AFTER degradation so the gain label matches the actual input.
    noise=torch.randn(rgb.shape,generator=rng,device=hdr.device)*uniform(0,.002)
    rgb=((rgb+noise).clamp(0,1)*255).round()/255
    sy=luminance(linearize(rgb)).clamp_min(1e-7)
    unbounded=torch.log2(y/sy)
    target=unbounded.clamp(MIN_EV,MAX_EV)
    valid=(sy>.003)&(y>.003)
    thumb=F.interpolate(rgb,size=(128,128),mode='bilinear',align_corners=False)
    return rgb,thumb,target,valid,unbounded
