#!/usr/bin/env python3
# Volumetric stress cloud: N points uniform in a 10 m cube, float32 xyz + uint8 rgb, fixed seed.
import sys, numpy as np
out, n = sys.argv[1], int(sys.argv[2])
rng = np.random.default_rng(20260923)
dt = np.dtype([('x','<f4'),('y','<f4'),('z','<f4'),('r','u1'),('g','u1'),('b','u1')])
with open(out, 'wb') as f:
    f.write(f"ply\nformat binary_little_endian 1.0\nelement vertex {n}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n".encode())
    CH = 4_000_000
    for s in range(0, n, CH):
        m = min(CH, n - s)
        a = np.zeros(m, dtype=dt)
        for k in 'xyz': a[k] = rng.uniform(0.0, 10.0, m).astype(np.float32)
        for k in 'rgb': a[k] = rng.integers(0, 256, m, dtype=np.uint8)
        f.write(a.tobytes())
print('wrote', n)
