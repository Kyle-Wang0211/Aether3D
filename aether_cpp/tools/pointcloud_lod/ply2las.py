#!/usr/bin/env python3
"""PLY (binary_little_endian, xyz f32 + rgb u8) -> LAS 1.2 point format 2.

Pure format bridge for testing PotreeConverter 2.0, which reads only LAS/LAZ.
Not shipped. Streams in chunks so 36M points fit comfortably.
"""
import sys, struct, numpy as np

src, dst = sys.argv[1], sys.argv[2]

# ---- parse PLY header ----
with open(src, 'rb') as f:
    hdr = b''
    while b'end_header\n' not in hdr:
        hdr += f.read(1)
    data_off = f.tell()
hdr_txt = hdr.decode('ascii')
assert 'binary_little_endian' in hdr_txt, hdr_txt
n = int([l for l in hdr_txt.splitlines() if l.startswith('element vertex')][0].split()[-1])
props = [l.split() for l in hdr_txt.splitlines() if l.startswith('property')]
assert [p[2] for p in props] == ['x','y','z','red','green','blue'], props
assert [p[1] for p in props] == ['float','float','float','uchar','uchar','uchar'], props
dt = np.dtype([('x','<f4'),('y','<f4'),('z','<f4'),('r','u1'),('g','u1'),('b','u1')])
assert dt.itemsize == 15

arr = np.memmap(src, dtype=dt, mode='r', offset=data_off, shape=(n,))
print(f'[ply] {n:,} points, {dt.itemsize} B/point, data at {data_off}', flush=True)

# ---- bbox in one pass ----
lo = np.array([arr['x'].min(), arr['y'].min(), arr['z'].min()], dtype=np.float64)
hi = np.array([arr['x'].max(), arr['y'].max(), arr['z'].max()], dtype=np.float64)
ctr = (lo + hi) / 2.0
ext = float((hi - lo).max())
scale = max(ext / 2.0e9, 1e-9)          # fill the int32 range, no overflow
print(f'[bbox] min={lo} max={hi} extent={ext:.6f} scale={scale:.3e}', flush=True)

HDR = 227
REC = 26
h = bytearray(HDR)
h[0:4] = b'LASF'
h[24] = 1; h[25] = 2                                   # LAS 1.2
h[26:58]  = b'PocketWorld'.ljust(32, b'\0')
h[58:90]  = b'ply2las.py'.ljust(32, b'\0')
struct.pack_into('<H', h, 94, HDR)                     # header size
struct.pack_into('<I', h, 96, HDR)                     # offset to point data
struct.pack_into('<I', h, 100, 0)                      # num VLRs
h[104] = 2                                             # point data format 2 (xyz+rgb)
struct.pack_into('<H', h, 105, REC)
struct.pack_into('<I', h, 107, n)                      # legacy point count
struct.pack_into('<I', h, 111, n)                      # by-return[0]
struct.pack_into('<ddd', h, 131, scale, scale, scale)
struct.pack_into('<ddd', h, 155, *ctr)
struct.pack_into('<dddddd', h, 179,
                 hi[0], lo[0], hi[1], lo[1], hi[2], lo[2])

CH = 2_000_000
written = 0
with open(dst, 'wb') as out:
    out.write(h)
    for s in range(0, n, CH):
        e = min(s + CH, n)
        c = arr[s:e]
        rec = np.zeros(e - s, dtype=np.dtype([
            ('X','<i4'),('Y','<i4'),('Z','<i4'),('int','<u2'),('flg','u1'),
            ('cls','u1'),('ang','i1'),('usr','u1'),('psid','<u2'),
            ('R','<u2'),('G','<u2'),('B','<u2')]))
        assert rec.dtype.itemsize == REC
        rec['X'] = np.rint((c['x'].astype(np.float64) - ctr[0]) / scale)
        rec['Y'] = np.rint((c['y'].astype(np.float64) - ctr[1]) / scale)
        rec['Z'] = np.rint((c['z'].astype(np.float64) - ctr[2]) / scale)
        rec['flg'] = 1                                  # return 1 of 1
        rec['R'] = c['r'].astype(np.uint16) * 257       # 8-bit -> 16-bit
        rec['G'] = c['g'].astype(np.uint16) * 257
        rec['B'] = c['b'].astype(np.uint16) * 257
        out.write(rec.tobytes())
        written += e - s
print(f'[las] wrote {written:,} points', flush=True)
assert written == n, (written, n)

# ---- self-check: the bridge must prove it did not drop a point ----
import os
sz = os.path.getsize(dst)
assert sz == HDR + n * REC, (sz, HDR + n * REC)
print(f'[check] file size {sz:,} == 227 + {n:,}*26  OK', flush=True)
