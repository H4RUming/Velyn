"""Synthetic browsing fixtures only; no photographic or user content. Requires Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw
import math
root = Path(__file__).resolve().parents[1] / '.work/picker-fixtures'
root.mkdir(parents=True, exist_ok=True)
colors = [(193,111,86),(66,109,129),(148,144,103),(112,118,161),(183,148,110),(79,123,108)]
for i in range(18):
    base = colors[i % len(colors)]
    im = Image.new('RGB',(600,450))
    draw = ImageDraw.Draw(im)
    for y in range(450):
        factor = 0.7 + 0.4*y/449
        draw.line((0,y,600,y),fill=tuple(min(255,int(c*factor)) for c in base))
    draw.ellipse((340-i*5,60,455-i*5,175),fill=(235,223,198))
    draw.polygon([(0,350),(130,210+i*3),(280,335),(445,230),(600,340),(600,450),(0,450)],fill=tuple(int(c*0.5) for c in base))
    draw.text((20,20),f'SYNTHETIC {i+1:02}',fill=(255,255,255))
    im.save(root/f'fixture-{i:02}.jpg',quality=94)
