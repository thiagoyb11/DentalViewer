"""Read-only independent verification of a local study against the Swift test export.

Restricted reference reader for native little-endian monochrome CT and the supported
Xelis snapshot. Uses only Python's standard library, not application geometry code.
Reports and Swift exports must remain under ignored output/.
"""
import argparse
import array
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import sys
import zipfile

LONG_VR = {b'OB', b'OD', b'OF', b'OL', b'OV', b'OW', b'SQ', b'UC', b'UR', b'UT', b'UN'}
CT_UID = '1.2.840.10008.5.1.4.1.1.2'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_dicom(path):
    with path.open('rb') as stream:
        prefix = stream.read(132)
        if len(prefix) != 132 or prefix[128:] != b'DICM':
            return None
        raw = prefix + stream.read()
    pos, syntax, tags, pixels = 132, '1.2.840.10008.1.2', {}, None

    def header(explicit):
        nonlocal pos
        require(pos + 8 <= len(raw), 'Truncated reference DICOM header')
        group, item = struct.unpack_from('<HH', raw, pos)
        key = group << 16 | item
        if group == 0xFFFE or not explicit:
            size = struct.unpack_from('<I', raw, pos + 4)[0]
            pos += 8
        elif raw[pos + 4:pos + 6] in LONG_VR:
            require(pos + 12 <= len(raw), 'Truncated long VR header')
            size = struct.unpack_from('<I', raw, pos + 8)[0]
            pos += 12
        else:
            size = struct.unpack_from('<H', raw, pos + 6)[0]
            pos += 8
        return key, size

    def skip(size, explicit, depth=0):
        nonlocal pos
        require(depth < 64, 'Reference sequence nesting limit')
        if size != 0xFFFFFFFF:
            require(pos + size <= len(raw), 'Reference DICOM value exceeds file')
            pos += size
            return
        while pos < len(raw):
            key, nested = header(explicit)
            if key in (0xFFFEE00D, 0xFFFEE0DD):
                require(nested == 0, 'Invalid sequence delimiter')
                return
            skip(nested, explicit, depth + 1)
        raise ValueError('Unterminated reference DICOM sequence')

    while pos < len(raw):
        require(pos + 8 <= len(raw), 'Incomplete reference DICOM dataset')
        is_meta = struct.unpack_from('<H', raw, pos)[0] == 2
        if not is_meta and syntax not in ('1.2.840.10008.1.2', '1.2.840.10008.1.2.1'):
            require(syntax.startswith('1.2.840.10008.1.2.4.') or syntax == '1.2.840.10008.1.2.5', 'Unsupported reference transfer syntax')
        explicit = is_meta or syntax != '1.2.840.10008.1.2'
        key, size = header(explicit)
        if key == 0x7FE00010:
            if size != 0xFFFFFFFF:
                require(pos + size <= len(raw), 'Truncated reference pixels')
                pixels = raw[pos:pos + size]
            break
        if size != 0xFFFFFFFF:
            require(pos + size <= len(raw), 'Truncated reference metadata')
            tags[key] = raw[pos:pos + size]
            if key == 0x00020010:
                syntax = tags[key].decode('ascii').strip(' \0')
        skip(size, explicit)
    return tags, pixels


def text(tags, key):
    return tags.get(key, b'').decode('ascii').strip(' \0')


def decimals(tags, key):
    values = [float(v) for v in text(tags, key).split('\\')]
    require(all(math.isfinite(v) for v in values), 'Nonfinite reference decimal value')
    return values


def integer(tags, key):
    return struct.unpack('<H', tags[key])[0]


class CurveReader:
    def __init__(self, raw, pos):
        self.raw, self.pos = raw, pos

    def read(self, fmt):
        size = struct.calcsize('<' + fmt)
        require(self.pos + size <= len(self.raw), 'Truncated reference curve')
        result = struct.unpack_from('<' + fmt, self.raw, self.pos)
        self.pos += size
        if 'f' in fmt:
            require(all(math.isfinite(v) for v in result), 'Nonfinite reference curve value')
        return result[0] if len(result) == 1 else list(result)

    def vector(self):
        require(self.read('I') == 3, 'Invalid vector dimensions')
        return self.read('3f')

    def general_header(self):
        require(self.read('I') == 0x10000003, 'Unknown general curve version')
        self.read('2I'); self.read('B'); self.read('4f')
        self.vector(); self.vector(); self.read('2f')
        require(self.read('B') == 1, 'Empty reference curve')

    def curve(self):
        require(self.read('I') == 0x10000002, 'Unknown curve version')
        self.read('4f')
        for _ in range(3):
            self.vector()
        self.read('3f'); self.vector(); self.read('3f')
        count = self.read('I')
        require(2 <= count <= 20000, 'Invalid sample count')
        points, verticals, tangents = [], [], []
        for _ in range(count):
            verticals.append(self.vector()); tangents.append(self.vector()); points.append(self.read('3f'))
        count = self.read('I')
        require(1 <= count <= 1000, 'Invalid control count')
        controls = [self.read('3f') for _ in range(count)]
        count = self.read('I')
        require(1 <= count <= 20000, 'Invalid frame count')
        frames = []
        for _ in range(count):
            require(self.read('I') == 0x10000001, 'Unknown frame version')
            distance, point = self.read('f'), self.read('3f')
            frames.append(dict(distance=distance, point=point, vertical=self.vector(), tangent=self.vector()))
        require(self.read('I') == len(controls), 'Invalid control index count')
        indices = [self.read('I') for _ in controls]
        require(all(i < len(frames) for i in indices), 'Invalid control frame index')
        self.read('f')
        return dict(points=points, controls=controls, verticals=verticals, tangents=tangents, frames=frames)


def read_xelis(payload):
    require(struct.unpack_from('<I', payload)[0] == 0x30000017, 'Unsupported snapshot payload')
    require(struct.unpack_from('<I', payload, 768)[0] == 0x10000001, 'Unknown bounds version')
    bounds = struct.unpack_from('<6f', payload, 772)
    require(bounds[::2] == (0, 0, 0), 'Unsupported local reference origin')
    candidates, offset = [], 0
    marker = struct.pack('<I', 0x10000002)
    while True:
        offset = payload.find(marker, offset)
        if offset < 0:
            break
        if offset >= 70:
            try:
                reader = CurveReader(payload, offset - 70)
                reader.general_header()
                arch = reader.curve()
                require(reader.read('2I') == [1, 0], 'No reference canal collection')
                count = reader.read('I')
                require(1 <= count <= 10, 'Invalid reference canal count')
                canals = []
                for i in range(count):
                    require(reader.read('3I') == [i + 1, 0x10000001, 2], 'Invalid reference canal record')
                    reader.read('6f'); reader.general_header(); canals.append(reader.curve())
                candidates.append((arch, canals))
            except (ValueError, struct.error):
                pass
        offset += 4
    require(len(candidates) == 1, 'No unique independently decoded curve collection')
    return list(bounds[1::2]), *candidates[0]


def vector_error(actual, expected):
    require(len(actual) == len(expected) == 3, 'Reference vector shape mismatch')
    return math.dist(actual, expected)


def curve_error(actual, expected, origin):
    position_error, axis_error, distance_error, positions = 0.0, 0.0, 0.0, 0
    for key in ('points', 'controls'):
        require(len(actual[key]) == len(expected[key]), 'Imported reference sample count mismatch')
        for a, b in zip(actual[key], expected[key]):
            b = [p + q for p, q in zip(b, origin)]
            position_error = max(position_error, vector_error(a, b)); positions += 1
    for key in ('verticals', 'tangents'):
        require(len(actual[key]) == len(expected[key]), 'Imported reference axis count mismatch')
        for a, b in zip(actual[key], expected[key]):
            axis_error = max(axis_error, vector_error(a, b))
    require(len(actual['frames']) == len(expected['frames']), 'Imported frame count mismatch')
    for a, b in zip(actual['frames'], expected['frames']):
        position_error = max(position_error, vector_error(a['point'], [p + q for p, q in zip(b['point'], origin)])); positions += 1
        for key in ('vertical', 'tangent'):
            axis_error = max(axis_error, vector_error(a[key], b[key]))
        distance_error = max(distance_error, abs(a['distance'] - b['distance']))
    return position_error, axis_error, distance_error, positions


def run(args):
    reference = json.loads(args.reference.read_text())
    slices, input_hashes = [], {}
    for path in args.study.rglob('*'):
        if not path.is_file():
            continue
        parsed = read_dicom(path)
        if parsed is None:
            continue
        tags, pixels = parsed
        if text(tags, 0x00080016) == CT_UID and text(tags, 0x0020000E) == reference['series_uid']:
            require(pixels is not None, 'Compressed reference CT is outside this audit')
            slices.append((decimals(tags, 0x00200032)[2], path, tags))
            input_hashes[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    slices.sort(key=lambda item: item[0])
    require(len(slices) == reference['dimensions'][2], 'Source and Swift slice counts differ')
    first = slices[0][2]
    width, height = integer(first, 0x00280011), integer(first, 0x00280010)
    require([width, height, len(slices)] == reference['dimensions'], 'Independent DICOM dimensions differ')
    origin = decimals(first, 0x00200032)
    row_column = decimals(first, 0x00280030)
    steps = [b[0] - a[0] for a, b in zip(slices, slices[1:])]
    dz = sorted(steps)[len(steps) // 2]
    spacing = [row_column[1], row_column[0], dz]
    require(vector_error(origin, reference['origin']) < 1e-10 and vector_error(spacing, reference['spacing']) < 1e-10, 'Independent origin or spacing differs')
    require(text(first, 0x0020000D) == reference['study_uid'], 'Study reference mismatch')
    require(sorted(text(item[2], 0x00080018) for item in slices) == reference['source_sop_uids'], 'SOP references differ')
    all_voxels, max_intensity_error = 0, 0.0
    for z, (_, path, tags) in enumerate(slices):
        _, pixels = read_dicom(path)
        bits, stored = integer(tags, 0x00280100), integer(tags, 0x00280101)
        require(bits in (8, 16), 'Unsupported reference pixel size')
        required = width * height * (bits // 8)
        require(len(pixels) == required + required % 2, 'Unexpected native reference pixel length')
        require(decimals(tags, 0x00200037) == [1, 0, 0, 0, 1, 0], 'Unsupported reference orientation')
        require(decimals(tags, 0x00280030) == row_column, 'Variable source pixel spacing')
        values = array.array('B' if bits == 8 else 'H', pixels[:required])
        if bits == 16 and sys.byteorder != 'little':
            values.byteswap()
        mask = (1 << stored) - 1
        values = array.array('H', (v & mask for v in values))
        require(sum(values) == reference['slice_raw_sums'][z], 'Independent pixel sum differs')
        if sys.byteorder != 'little':
            values.byteswap()
        require(hashlib.sha256(values.tobytes()).hexdigest() == reference['slice_raw_sha256'][z], 'Independent full-slice pixel hash differs')
        if sys.byteorder != 'little':
            values.byteswap()
        slope = decimals(tags, 0x00281053)[0] if 0x00281053 in tags else 1
        intercept = decimals(tags, 0x00281052)[0] if 0x00281052 in tags else 0
        signed = integer(tags, 0x00280103) == 1
        for sample in reference['intensity_samples']:
            x, y, sz = sample['voxel']
            if sz != z:
                continue
            value = values[y * width + x]
            if signed and value & (1 << (stored - 1)):
                value -= 1 << stored
            max_intensity_error = max(max_intensity_error, abs(sample['value'] - (value * slope + intercept)))
        all_voxels += len(values)
    require(max_intensity_error < 0.0001, 'Independent rescaled intensities differ')
    project_path = Path(reference['source_project_path'])
    require(project_path.resolve().is_relative_to(args.study.resolve()), 'Project reference is outside selected study')
    input_hashes[str(project_path)] = hashlib.sha256(project_path.read_bytes()).hexdigest()
    project_tags, _ = read_dicom(project_path)
    require(text(project_tags, 0x0020000D) == reference['study_uid'], 'Project study UID mismatch')
    metadata = project_tags[0x75731003]
    require(metadata.startswith(b'LucionSnapshotIdentifier_Version_30000001\0'), 'Unsupported snapshot metadata')
    reader = CurveReader(metadata, 1060)
    require(reader.read('I') == 1, 'Invalid SOP collection version')
    count = reader.read('I')
    require(count == len(slices), 'Project SOP reference count mismatch')
    uids = []
    for _ in range(count):
        require(reader.read('3B') == [255, 254, 255], 'Unknown SOP string encoding')
        size = reader.read('B')
        require(size < 255, 'Long SOP references unsupported')
        start = reader.pos; reader.pos += size * 2
        uids.append(metadata[start:reader.pos].decode('utf-16-le'))
    require(sorted(uids) == reference['source_sop_uids'], 'Independent project SOP references differ')
    with zipfile.ZipFile(io.BytesIO(project_tags[0x75731004])) as archive:
        require(archive.namelist() == ['-'], 'Unexpected snapshot ZIP contents')
        payload = archive.read('-')  # Standard library verifies the archive CRC.
    bounds, arch, canals = read_xelis(payload)
    expected_bounds = [(n - 1) * s for n, s in zip(reference['dimensions'], spacing)]
    require(vector_error(bounds, expected_bounds) < 0.001, 'Independent saved volume bounds mismatch')
    require(len(canals) == len(reference['canals']), 'Independent canal count differs')
    errors = [curve_error(reference['arch'], arch, origin)]
    errors += [curve_error(a, b, origin) for a, b in zip(reference['canals'], canals)]
    max_position_error = max(e[0] for e in errors)
    max_axis_error = max(e[1] for e in errors)
    max_frame_error = max(e[2] for e in errors)
    require(max_position_error < 1e-8 and max_axis_error < 1e-10 and max_frame_error < 1e-10, 'Independent original curve geometry differs')
    cumulative = [0.0]
    for a, b in zip(arch['points'], arch['points'][1:]):
        cumulative.append(cumulative[-1] + math.dist(a, b))
    arc_error = abs(reference['arch_length_mm'] - cumulative[-1])
    require(arc_error < 1e-8, 'Independent panoramic arc length differs')
    report = dict(status='pass', source_slices_checked=len(slices), source_voxels_checked=all_voxels,
        original_positions_checked=sum(e[3] for e in errors), maximum_original_position_difference_mm=max_position_error,
        maximum_original_axis_difference=max_axis_error, maximum_saved_frame_distance_difference_mm=max_frame_error,
        maximum_arc_length_difference_mm=arc_error, maximum_intensity_difference=max_intensity_error,
        reference_kind='Original DICOM pixels and saved Xelis coordinates; independent Python decoding, not anatomical ground truth.')
    if args.screen_reference:
        live = json.loads(args.screen_reference.read_text())
        rect_x, rect_y, rect_w, rect_h = live['native']['image_rect_approx_px']
        def distance_at(column):
            column = min(len(cumulative) - 1, max(0, column))
            a = int(column); b = min(a + 1, len(cumulative) - 1)
            return cumulative[a] + (cumulative[b] - cumulative[a]) * (column - a)
        observations = []
        for measurement in live['measurements']:
            a, b = measurement['native_input_endpoints_px']
            columns = [(p[0] - rect_x) / rect_w * len(cumulative) - 0.5 for p in (a, b)]
            rows = [(p[1] - rect_y) / rect_h * len(slices) - 0.5 for p in (a, b)]
            measured = math.hypot(distance_at(columns[1]) - distance_at(columns[0]), (rows[1] - rows[0]) * spacing[2])
            native_difference = abs(measured - measurement['native_display_mm'])
            xelis_difference = abs(measured - measurement['xelis_display_mm'])
            require(native_difference < 0.05, 'Historical native display reference changed')
            require(xelis_difference < live['screen_comparison_tolerance_mm'], 'Historical screen comparison exceeds its regression tolerance')
            observations.append(dict(name=measurement['name'], native_geometry_display_difference_mm=native_difference, xelis_geometry_difference_mm=xelis_difference))
        report['historical_screen_comparison'] = dict(observations=observations,
            tolerance_mm=live['screen_comparison_tolerance_mm'], scope='Approximate screen endpoints recorded previously; not a paired 3D-coordinate equivalence test.')
    require(all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == value for path, value in input_hashes.items()), 'Original study changed during independent audit')
    report['original_files_unchanged_during_audit'] = True
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print('PASS: independent full-pixel and original-coordinate verification; report:', args.report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('study', type=Path)
    parser.add_argument('--reference', type=Path, default=Path('output/technical-validation-private-reference.json'))
    parser.add_argument('--report', type=Path, default=Path('output/technical-validation-study.json'))
    parser.add_argument('--screen-reference', type=Path)
    args = parser.parse_args()
    try:
        run(args)
    except (ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        raise SystemExit('FAIL: ' + str(error)) from error


if __name__ == '__main__':
    main()
