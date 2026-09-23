#!/usr/bin/env python3
"""T4: colour must survive too. The position-only judge is blind to colour loss."""
import sys, json, os
import numpy as np
octdir, plypath = sys.argv[1], sys.argv[2]
meta = json.load(open(os.path.join(octdir,'metadata.json')))
names = [a['name'] for a in meta['attributes']]
sizes = [a['size'] for a in meta['attributes']]
bpp = sum(sizes)

if 'rgb' not in names:
    print(f"[T4] FAIL - octree has no 'rgb' attribute at all. attributes={list(zip(names,sizes))}")
    sys.exit(1)
rgb_off = sum(sizes[:names.index('rgb')])
rgb_sz  = sizes[names.index('rgb')]
print(f"[T4] bytesPerPoint={bpp}  rgb at byte {rgb_off}, {rgb_sz} bytes ({[ (a['name'],a['size']) for a in meta['attributes']]})")

with open(plypath,'rb') as f:
    hdr=b''
    while b'end_header\n' not in hdr: hdr+=f.read(1)
    doff=f.tell()
n_in=int([l for l in hdr.decode().splitlines() if l.startswith('element vertex')][0].split()[-1])
dt=np.dtype([('x','<f4'),('y','<f4'),('z','<f4'),('r','u1'),('g','u1'),('b','u1')])
src=np.memmap(plypath,dtype=dt,mode='r',offset=doff,shape=(n_in,))

out=np.memmap(os.path.join(octdir,'octree.bin'),dtype=np.uint8,mode='r')
n_out=out.size//bpp
rows=np.frombuffer(out[:n_out*bpp].tobytes(),dtype=np.uint8).reshape(n_out,bpp)
RGB=rows[:,rgb_off:rgb_off+6].copy().view(np.uint16)      # uint16 per channel
# the bridge widened 8-bit -> 16-bit with *257; undo it
RGB8 = (RGB // 257).astype(np.uint8)

ok = True
for i,ch in enumerate('rgb'):
    a=np.sort(src[{'r':'r','g':'g','b':'b'}[ch]]); b=np.sort(RGB8[:,i])
    same = a.size==b.size and np.array_equal(a,b)
    ok &= same
    print(f"     {ch}: input hist == output hist ? {'PASS' if same else 'FAIL'}"
          f"  (in n={a.size:,} mean={a.mean():.2f} / out n={b.size:,} mean={b.mean():.2f})")

# negative control: flip one channel value
C=RGB8.copy(); C[999,0]=np.uint8((int(C[999,0])+37)%256)
neg = not np.array_equal(np.sort(src['r']), np.sort(C[:,0]))
print(f"[T4neg] NEGATIVE CONTROL (one red value changed): "
      f"{'PASS - judge rejected it' if neg else 'FAIL - judge is blind to colour corruption'}")
print(f"==== T4 {'PASS' if (ok and neg) else 'FAIL'} ====")
sys.exit(0 if (ok and neg) else 1)
