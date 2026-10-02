"""Predict scalar log2 HDR gain from sRGB code values. No network calls."""
import argparse
import io
import math
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image, ImageCms, ImageOps
from safetensors.torch import load_file

from GMNet import GMNet


def load_model(directory=Path(__file__).parent, device='cpu'):
    model = GMNet(in_nc=3, out_nc=1, nf=64, nb=16)
    model.load_state_dict(load_file(str(Path(directory) / 'model.safetensors')), strict=True)
    return model.eval().to(device)


@torch.inference_mode()
def predict_log_gain(model, image, size=1024):
    """Return [1,1,H,W] EV. Input: float [1,3,H,W], encoded sRGB in [0,1]."""
    if size not in (512, 1024):
        raise ValueError('Supported local input sizes are 512 and 1024')
    if image.ndim != 4 or image.shape[:2] != (1, 3) or min(image.shape[-2:]) < 1:
        raise ValueError('Expected one RGB image with shape [1,3,H,W]')
    if not image.is_floating_point() or not torch.isfinite(image).all() or image.min() < 0 or image.max() > 1:
        raise ValueError('Expected finite sRGB code values in [0,1]')
    image = image.to(device=next(model.parameters()).device, dtype=torch.float32)
    height, width = image.shape[-2:]
    scale = size / max(height, width)
    h, w = max(1, round(height * scale)), max(1, round(width * scale))
    top, left = (size-h)//2, (size-w)//2
    local = F.interpolate(image, size=(h, w), mode='bilinear', align_corners=False)
    local = F.pad(local, (left, size-w-left, top, size-h-top), mode='replicate')
    thumbnail = F.interpolate(image, size=(256, 256), mode='bilinear', align_corners=False)
    gain = model((local, thumbnail))[1].clamp(0, 1) * math.log2(5)
    gain = gain[:, :, top:top+h, left:left+w]
    return F.interpolate(gain, size=(height, width), mode='bilinear', align_corners=False)


def read_srgb(path):
    with Image.open(path) as original:
        image = ImageOps.exif_transpose(original)
        profile = original.info.get('icc_profile')
        image = image.convert('RGB')
        if profile:
            image = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(profile)),
                                             ImageCms.createProfile('sRGB'), outputMode='RGB')
        values = np.asarray(image, dtype=np.float32) / 255
    return torch.from_numpy(values.copy()).permute(2, 0, 1)[None]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path)
    parser.add_argument('output', type=Path, help='Output .npy containing scalar float32 EV')
    parser.add_argument('--size', type=int, choices=[512, 1024], default=1024)
    parser.add_argument('--device', default='cpu')
    args = parser.parse_args()
    torch.set_num_threads(min(4, torch.get_num_threads()))
    model = load_model(device=args.device)
    gain = predict_log_gain(model, read_srgb(args.image), size=args.size)
    np.save(args.output, gain[0, 0].cpu().numpy(), allow_pickle=False)
    print('Saved scalar log2 gain. This array is not an HDR image container.')


if __name__ == '__main__':
    main()
