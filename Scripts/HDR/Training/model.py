"""Velyn SignedGainNet v0: an original small CNN for scalar log2 gain.

No pretrained weights. Standard convolutions, resize, pooling and pointwise ops
keep the first architecture suitable for a later Core ML conversion experiment.
"""
import math
import torch
from torch import nn
import torch.nn.functional as F

MIN_EV=-2.0
MAX_EV=math.log2(5)


class Residual(nn.Module):
    def __init__(self,c):
        super().__init__()
        self.body=nn.Sequential(nn.Conv2d(c,c,3,padding=1),nn.ReLU(),nn.Conv2d(c,c,3,padding=1))
    def forward(self,x): return F.relu(x+.2*self.body(x))


class SignedGainNet(nn.Module):
    def __init__(self,width=24):
        super().__init__(); c=width
        self.width=width
        self.e1=nn.Sequential(nn.Conv2d(3,c,3,stride=2,padding=1),nn.ReLU(),Residual(c))
        self.e2=nn.Sequential(nn.Conv2d(c,c*2,3,stride=2,padding=1),nn.ReLU(),Residual(c*2))
        self.e3=nn.Sequential(nn.Conv2d(c*2,c*4,3,stride=2,padding=1),nn.ReLU(),Residual(c*4),Residual(c*4))
        self.global_branch=nn.Sequential(nn.Conv2d(3,16,3,2,1),nn.ReLU(),nn.Conv2d(16,32,3,2,1),nn.ReLU(),
            nn.Conv2d(32,48,3,2,1),nn.ReLU(),nn.AdaptiveAvgPool2d(1),nn.Conv2d(48,c*8,1))
        self.d2=nn.Sequential(nn.Conv2d(c*6,c*2,3,padding=1),nn.ReLU(),Residual(c*2))
        self.d1=nn.Sequential(nn.Conv2d(c*3,c,3,padding=1),nn.ReLU(),Residual(c))
        self.head=nn.Conv2d(c,1,3,padding=1)
        nn.init.zeros_(self.head.weight); nn.init.zeros_(self.head.bias)
    def forward(self,rgb,thumbnail):
        a=self.e1(rgb); b=self.e2(a); c=self.e3(b)
        scale,bias=self.global_branch(thumbnail).chunk(2,dim=1)
        c=c*(1+.1*torch.tanh(scale))+.1*bias
        d=self.d2(torch.cat([F.interpolate(c,size=b.shape[-2:],mode='bilinear',align_corners=False),b],dim=1))
        d=self.d1(torch.cat([F.interpolate(d,size=a.shape[-2:],mode='bilinear',align_corners=False),a],dim=1))
        d=F.interpolate(self.head(d),size=rgb.shape[-2:],mode='bilinear',align_corners=False)
        return (2.5*torch.tanh(d/2.5)).clamp(MIN_EV,MAX_EV)
