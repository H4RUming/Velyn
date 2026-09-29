"""Generate a synthetic transparent WebP fixture; requires Pillow with WebP support."""
from pathlib import Path
from PIL import Image
image = Image.new('RGBA', (128, 96), (0, 0, 0, 0))
for y in range(96):
    for x in range(128):
        image.putpixel((x,y), (x*2, y*2, 100, 255 if x < 64 else 96))
image.save(Path(__file__).resolve().parents[1] / 'Tests/VelynEngineTests/Fixtures/synthetic.webp', 'WEBP', lossless=True)
