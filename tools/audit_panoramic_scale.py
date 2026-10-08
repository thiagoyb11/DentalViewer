"""Independent read-only audit of the saved Xelis curve, using Python struct.
Input: already extracted project-payload.bin. Does not use viewer geometry code.
"""
import json, math, struct, sys
from pathlib import Path
if len(sys.argv) != 2:
    raise SystemExit('Uso: python3 tools/audit_panoramic_scale.py /ruta/privada/project-payload.bin')
raw = Path(sys.argv[1]).read_bytes()
class Reader:
    def __init__(self, offset): self.pos = offset
    def read(self, fmt):
        values = struct.unpack_from('<'+fmt, raw, self.pos)
        self.pos += struct.calcsize('<'+fmt)
        return values[0] if len(values) == 1 else values
    def vector(self):
        assert self.read('I') == 3
        return self.read('3f')
    def curve(self):
        assert self.read('I') == 0x10000002
        self.read('4f')
        for _ in range(3): self.vector()
        self.read('3f'); self.vector(); self.read('3f')
        n = self.read('I'); assert 2 <= n <= 20000
        positions, verticals, tangents = [], [], []
        for _ in range(n):
            verticals.append(self.vector()); tangents.append(self.vector()); positions.append(self.read('3f'))
        c = self.read('I'); assert 2 <= c <= 1000
        controls = [self.read('3f') for _ in range(c)]
        f = self.read('I'); assert 2 <= f <= 20000
        frames = []
        for _ in range(f):
            assert self.read('I') == 0x10000001
            d, p = self.read('f'), self.read('3f')
            frames.append((d,p)); self.vector(); self.vector()
        assert self.read('I') == c
        indices = [self.read('I') for _ in range(c)]
        tolerance = self.read('f')
        return positions, controls, frames, verticals, tangents, indices, tolerance
marker = struct.pack('<I', 0x10000002)
found, offset = [], 0
while True:
    offset = raw.find(marker, offset)
    if offset < 0: break
    try:
        r = Reader(offset)
        result = r.curve()
        if struct.unpack_from("<3I",raw,r.pos) == (1,0,2): found.append((offset,result))
    except (AssertionError, struct.error): pass
    offset += 4
assert len(found) == 1
start, (points, controls, frames, verticals, tangents, indices, tolerance) = found[0]
segments = [math.dist(a,b) for a,b in zip(points,points[1:])]
length = sum(segments)
cumulative = [0]
for d in segments: cumulative.append(cumulative[-1]+d)
frame_length = sum(math.dist(a[1],b[1]) for a,b in zip(frames,frames[1:]))
report = dict(source_offset=start, sample_count=len(points), control_count=len(controls), frame_count=len(frames),
    dense_length_mm=length, frame_polyline_length_mm=frame_length,
    max_column_distance_deviation_mm=max(abs(d-length*i/(len(points)-1)) for i,d in enumerate(cumulative)),
    duplicate_segments=sum(d == 0 for d in segments),
    max_axis_dot=max(abs(sum(a*b for a,b in zip(v,t))) for v,t in zip(verticals,tangents)), saved_frame_distance_mm=[frames[0][0],frames[-1][0]],
    segment_mm=dict(min=min(segments),max=max(segments),mean=length/len(segments)),
    vertical_norm_range=[min(math.dist(v,(0,0,0)) for v in verticals),max(math.dist(v,(0,0,0)) for v in verticals)],
    dense_first=points[0],dense_last=points[-1],tolerance=tolerance)
print(json.dumps(report,indent=2))
