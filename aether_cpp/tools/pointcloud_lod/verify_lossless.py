#!/usr/bin/env python3
"""Does PotreeConverter 2.0 store every input point exactly once?

T1  byte-level count: octree.bin size / bytesPerPoint == input count
T2  per-axis sorted positions agree to within 2 LSB of the int32 grid
T2b the int32 LSB is FINER than the float32 input's own ULP
    (i.e. the quantisation destroys no information the input had)
T3a NEGATIVE CONTROL, count-preserving: drop one point, duplicate another.
    T1 cannot see this. T2 must FAIL.
T3b NEGATIVE CONTROL: shift one point by 100 LSB. T2 must FAIL.
"""
import sys, json, os
import numpy as np

octdir, plypath = sys.argv[1], sys.argv[2]
meta = json.load(open(os.path.join(octdir, 'metadata.json')))
bpp = sum(a['size'] for a in meta['attributes'])
sc  = np.array(meta['scale'], dtype=np.float64)
off = np.array(meta['offset'], dtype=np.float64)
assert meta['encoding'] == 'DEFAULT', meta['encoding']

with open(plypath, 'rb') as f:
    hdr = b''
    while b'end_header\n' not in hdr: hdr += f.read(1)
    doff = f.tell()
n_in = int([l for l in hdr.decode().splitlines() if l.startswith('element vertex')][0].split()[-1])
dt = np.dtype([('x','<f4'),('y','<f4'),('z','<f4'),('r','u1'),('g','u1'),('b','u1')])
src = np.memmap(plypath, dtype=dt, mode='r', offset=doff, shape=(n_in,))

out = np.memmap(os.path.join(octdir,'octree.bin'), dtype=np.uint8, mode='r')
n_out = out.size // bpp
B = np.frombuffer(out[:n_out*bpp].tobytes(), dtype=np.uint8).reshape(n_out,bpp)[:,0:12].copy().view(np.int32)
Bw = B.astype(np.float64) * sc + off

print(f"[meta] bytesPerPoint={bpp}  scale={sc}")
print(f"[meta] SELF-REPORTED points={meta['points']:,}   <-- never used as evidence\n")

# ---- T1 ----
t1 = (out.size % bpp == 0) and (n_out == n_in)
print(f"[T1] octree.bin {out.size:,} B / {bpp} = {n_out:,}   input {n_in:,}   "
      f"{'PASS' if t1 else 'FAIL'} (delta {n_out-n_in:+,})")

# ---- T2 ----
TOL_LSB = 2.0
def axis_cmp(A_in, A_out, ax):
    if A_in.size != A_out.size: return False, float('inf')
    d = np.abs(np.sort(A_out) - np.sort(A_in)).max() / sc[ax]
    return d <= TOL_LSB, d

t2 = True
print(f"\n[T2] per-axis sorted agreement, tolerance {TOL_LSB} LSB")
for ax, nm in enumerate('xyz'):
    ok, d = axis_cmp(src[nm].astype(np.float64), Bw[:,ax], ax)
    t2 &= ok
    print(f"     {nm}: max deviation {d:.3f} LSB   {'PASS' if ok else 'FAIL'}")

# ---- T2b: is the grid finer than float32 itself? ----
print(f"\n[T2b] quantisation vs the input's own precision")
for ax, nm in enumerate('xyz'):
    mag = float(np.abs(src[nm]).max())
    ulp = float(np.spacing(np.float32(mag)))
    print(f"     {nm}: int32 LSB = {sc[ax]:.3e}   float32 ULP at |max|={mag:.3f} is {ulp:.3e}"
          f"   -> grid is {ulp/sc[ax]:.1f}x FINER than the input")

# ---- T3a: count-preserving corruption ----
Cw = Bw.copy()
Cw[12345] = Cw[0]                      # duplicate one, losing another: count unchanged
t3a = not all(axis_cmp(src[nm].astype(np.float64), Cw[:,ax], ax)[0] for ax,nm in enumerate('xyz'))
print(f"\n[T3a] NEGATIVE CONTROL (count-preserving drop+duplicate): "
      f"{'PASS - judge rejected it' if t3a else 'FAIL - judge is blind to point loss'}")

# ---- T3b: one point moved ----
Dw = Bw.copy()
Dw[777, 0] += 100 * sc[0]
t3b = not axis_cmp(src['x'].astype(np.float64), Dw[:,0], 0)[0]
print(f"[T3b] NEGATIVE CONTROL (one point shifted 100 LSB): "
      f"{'PASS - judge rejected it' if t3b else 'FAIL - judge is blind'}")

ok = t1 and t2 and t3a and t3b
print(f"\n==== {'ALL PASS' if ok else 'FAILED'} ====")
sys.exit(0 if ok else 1)
