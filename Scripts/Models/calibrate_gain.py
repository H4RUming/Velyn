"""Print the pinned FP32 calibration samples used by GainModelCalibration.swift."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
import torch
sys.path.insert(0, str(Path(__file__).parent / 'gmnet'))
from GMNet import GMNet

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('checkpoint', type=Path)
args = parser.parse_args()
assert hashlib.sha256(args.checkpoint.read_bytes()).hexdigest() == '83bf27bcdbf6eacfdef37f0e24ed6d79152b7386620c012ae509a59a895c875f'
model = GMNet(in_nc=3, out_nc=1, nf=64, nb=16).eval()
model.load_state_dict(torch.load(args.checkpoint, weights_only=True, map_location='cpu'), strict=True)
torch.set_num_threads(4)

def tensor(side, pattern):
    if pattern == 0: return torch.full((1, 3, side, side), .5)
    y, x = torch.meshgrid(torch.arange(side), torch.arange(side), indexing='ij')
    return torch.stack([((x*(c+1)+y*(3-c)) % side)/(side-1) for c in range(3)])[None]

result = {}
for side in [512, 1024]:
    result[side] = {}
    for pattern in [0, 1]:
        with torch.no_grad():
            gain = model((tensor(side, pattern), tensor(256, pattern)))[1].clamp(0, 1)*math.log2(5)
        positions = [side//8, side//2, side*7//8]
        result[side][pattern] = [float(gain[0, 0, y, x]) for y in positions for x in positions]
print(json.dumps(result, indent=2))
