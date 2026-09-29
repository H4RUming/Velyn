#!/usr/bin/env python3
"""Generate an original synthetic CFA DNG. No user photos or third-party assets."""
import struct
from pathlib import Path

width, height = 640, 480
entries = []
def tag(key, kind, count, payload):
    entries.append((key, kind, count, payload))
def short(key, *values): tag(key, 3, len(values), struct.pack('<'+'H'*len(values), *values))
def long(key, value): tag(key, 4, 1, struct.pack('<I', value))
def ascii_tag(key, value): tag(key, 2, len(value)+1, value.encode()+b'\0')
def rational(key, values, signed=False):
    tag(key, 10 if signed else 5, len(values), b''.join(struct.pack('<ii' if signed else '<II', a,b) for a,b in values))
long(254, 0)
long(256, width)
long(257, height)
short(258, 16)
short(259, 1)
short(262, 32803)
ascii_tag(271, 'Velyn')
ascii_tag(272, 'Synthetic CFA fixture')
long(273, 0)
short(274, 6)
short(277, 1)
long(278, height)
long(279, width*height*2)
short(284, 1)
short(33421, 2, 2)
tag(33422, 1, 4, bytes([0,1,1,2]))
tag(50706, 1, 4, bytes([1,4,0,0]))
tag(50707, 1, 4, bytes([1,1,0,0]))
ascii_tag(50708, 'Velyn synthetic test camera')
short(50714, 0)
long(50717, 65535)
rational(50721, [(1,1),(0,1),(0,1),(0,1),(1,1),(0,1),(0,1),(0,1),(1,1)], signed=True)
rational(50728, [(1,1),(1,1),(1,1)])
short(50778, 21)
entries.sort()
base = 8 + 2 + len(entries)*12 + 4
extra = bytearray()
encoded = []
for key, kind, count, data in entries:
    if len(data) > 4:
        offset = base+len(extra)
        extra.extend(data)
        if len(extra)%2: extra.append(0)
        value = struct.pack('<I', offset)
    else: value = data.ljust(4,b'\0')
    encoded.append([key, kind, count, value])
pixel_offset = base+len(extra)
for entry in encoded:
    if entry[0] == 273: entry[3] = struct.pack('<I', pixel_offset)
output = bytearray(b'II*\0'+struct.pack('<I',8)+struct.pack('<H',len(encoded)))
for key,kind,count,value in encoded:
    output.extend(struct.pack('<HHI',key,kind,count)+value)
output.extend(struct.pack('<I',0))
output.extend(extra)
for y in range(height):
    for x in range(width): output.extend(struct.pack('<H', 1000 + x*60 + y*20))
path = Path(__file__).resolve().parents[1] / 'Tests/VelynEngineTests/Fixtures/synthetic.dng'
path.parent.mkdir(parents=True, exist_ok=True)
path.write_bytes(output)
print(f'Generated {len(output)} bytes: {path.name}')
