#!/usr/bin/env python3
"""Cut the committed test fixture out of a real capture.

    make_fixture.py <source.ply> <out.ply> <n_points>

Keeps a centred box 20% of the scene on each axis (0.8% of the volume) so the
point density -- and therefore the octree depth per point -- stays close to the
real cloud, then draws <n_points> from it with a fixed seed. Deterministic:
tests/pointcloud_lod/fixture/source.ply is this script run on the 36,232,793
point pc_t3 cloud (sha256 ff512c502f7647ba...) with n_points=25000, and
regenerates byte-for-byte (sha256 847df6d220b3734d...).
"""
import numpy as np, sys
src, dst, n_target = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(src,"rb") as f:
    h=b""
    while b"end_header\n" not in h: h+=f.read(1)
    off=f.tell()
n=int([l for l in h.decode().splitlines() if l.startswith("element vertex")][0].split()[-1])
dt=np.dtype([("x","<f4"),("y","<f4"),("z","<f4"),("r","u1"),("g","u1"),("b","u1")])
a=np.memmap(src,dtype=dt,mode="r",offset=off,shape=(n,))
# spatial crop: keep density high so the octree stays deep with few points
lo=np.array([a["x"].min(),a["y"].min(),a["z"].min()]); hi=np.array([a["x"].max(),a["y"].max(),a["z"].max()])
c=(lo+hi)/2; half=(hi-lo)*0.10          # half-width 10% => 20% of each axis => 0.8% of the volume
m=((a["x"]>c[0]-half[0])&(a["x"]<c[0]+half[0])&
   (a["y"]>c[1]-half[1])&(a["y"]<c[1]+half[1])&
   (a["z"]>c[2]-half[2])&(a["z"]<c[2]+half[2]))
idx=np.flatnonzero(m)
print(f"crop holds {idx.size:,} points")
if idx.size>n_target:
    rng=np.random.default_rng(20260923); idx=np.sort(rng.choice(idx,n_target,replace=False))
sub=a[idx]
with open(dst,"wb") as o:
    o.write(f"ply\nformat binary_little_endian 1.0\nelement vertex {idx.size}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n".encode())
    o.write(sub.tobytes())
print(f"wrote {idx.size:,} points")
