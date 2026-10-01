"""Bounded synthetic CUDA training throughput check, no photo inputs."""
import argparse,json,time
from pathlib import Path
import torch
import torch.nn.functional as F
from model import SignedGainNet
from pairs import make_pairs
p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args()
torch.set_num_threads(4);torch.manual_seed(20261001);torch.backends.cudnn.benchmark=True
model=SignedGainNet().cuda();optimizer=torch.optim.AdamW(model.parameters(),lr=2e-4)
hdr=torch.exp(torch.randn(24,3,256,256,device='cuda')-2)
scaler=torch.amp.GradScaler('cuda');times=[]
for step in range(120):
    torch.cuda.synchronize();start=time.perf_counter()
    rgb,thumb,target,valid,_=make_pairs(hdr,step)
    optimizer.zero_grad(set_to_none=True)
    with torch.autocast('cuda',dtype=torch.float16): pred=model(rgb,thumb)
    loss=F.smooth_l1_loss(pred.float(),target,beta=.2)
    scaler.scale(loss).backward();scaler.step(optimizer);scaler.update()
    torch.cuda.synchronize()
    if step>=20:times.append(time.perf_counter()-start)
record={'device':torch.cuda.get_device_name(),'torch':str(torch.__version__),'cuda':torch.version.cuda,
        'parameters':sum(x.numel() for x in model.parameters()),'batch':24,'size':256,
        'measuredSteps':len(times),'meanStepSeconds':sum(times)/len(times),'peakAllocatedMiB':torch.cuda.max_memory_allocated()/2**20,
        'scope':'Synthetic forward/backward and pair generation only; excludes data download, validation, checkpointing and conversion.'}
a.output.write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
