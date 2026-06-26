#!/usr/bin/env python3
# gen_streaming_manifest.py — build the streaming harness manifest from a
# capture's photo_bundle.json.
#
# Reads photo_bundle.json (schema aether_photo_bundle_v1), and for each frame
# emits {file, timestamp, w, h, fx, fy, cx, cy, q:[qw,qx,qy,qz], t:[tx,ty,tz]}
# in TIMESTAMP ORDER. The bundle's cameraTransform is a 4x4 COLUMN-major
# Camera-to-World (ARKit) matrix; the SfM ABI's pose-guided matcher
# (PosePriorAllowsMatch) wants the world->cam (CamFromWorld) rotation/translation,
# so we INVERT here and emit the quaternion (wxyz) + translation of T_cw.
#
# Usage:
#   gen_streaming_manifest.py <photo_bundle.json> <out_manifest.json> [N]
# N (optional) caps the number of frames (still timestamp-ordered).

import json, sys, math

def mat4_from_colmajor(v):
    # v is 16 floats, column-major: column c, row r at index c*4 + r.
    M = [[0.0]*4 for _ in range(4)]
    for c in range(4):
        for r in range(4):
            M[r][c] = v[c*4 + r]
    return M

def mat4_inverse_rigid(M):
    # M = [[R t],[0 1]] world<-cam (camera-to-world). Inverse = [[R^T -R^T t],[0 1]].
    R = [[M[r][c] for c in range(3)] for r in range(3)]
    t = [M[0][3], M[1][3], M[2][3]]
    Rt = [[R[c][r] for c in range(3)] for r in range(3)]  # transpose
    nt = [-(Rt[0][0]*t[0] + Rt[0][1]*t[1] + Rt[0][2]*t[2]),
          -(Rt[1][0]*t[0] + Rt[1][1]*t[1] + Rt[1][2]*t[2]),
          -(Rt[2][0]*t[0] + Rt[2][1]*t[1] + Rt[2][2]*t[2])]
    return Rt, nt

def quat_wxyz_from_R(R):
    # Standard rotation-matrix -> quaternion (w,x,y,z).
    tr = R[0][0] + R[1][1] + R[2][2]
    if tr > 0:
        s = math.sqrt(tr + 1.0) * 2.0
        w = 0.25 * s
        x = (R[2][1] - R[1][2]) / s
        y = (R[0][2] - R[2][0]) / s
        z = (R[1][0] - R[0][1]) / s
    elif R[0][0] > R[1][1] and R[0][0] > R[2][2]:
        s = math.sqrt(1.0 + R[0][0] - R[1][1] - R[2][2]) * 2.0
        w = (R[2][1] - R[1][2]) / s
        x = 0.25 * s
        y = (R[0][1] + R[1][0]) / s
        z = (R[0][2] + R[2][0]) / s
    elif R[1][1] > R[2][2]:
        s = math.sqrt(1.0 + R[1][1] - R[0][0] - R[2][2]) * 2.0
        w = (R[0][2] - R[2][0]) / s
        x = (R[0][1] + R[1][0]) / s
        y = 0.25 * s
        z = (R[1][2] + R[2][1]) / s
    else:
        s = math.sqrt(1.0 + R[2][2] - R[0][0] - R[1][1]) * 2.0
        w = (R[1][0] - R[0][1]) / s
        x = (R[0][2] + R[2][0]) / s
        y = (R[1][2] + R[2][1]) / s
        z = 0.25 * s
    n = math.sqrt(w*w + x*x + y*y + z*z) or 1.0
    return [w/n, x/n, y/n, z/n]

def main():
    if len(sys.argv) < 3:
        print("usage: gen_streaming_manifest.py <photo_bundle.json> <out.json> [N]")
        sys.exit(2)
    bundle = json.load(open(sys.argv[1]))
    frames = sorted(bundle["frames"], key=lambda f: f.get("timestamp", 0.0))
    if len(sys.argv) > 3:
        frames = frames[:int(sys.argv[3])]
    out = []
    no_pose = 0
    for f in frames:
        e = {
            "file": f["highresFilename"],
            "timestamp": f.get("timestamp", 0.0),
            "w": int(f.get("imageWidth", 0)),
            "h": int(f.get("imageHeight", 0)),
        }
        intr = f.get("intrinsics")
        if intr and len(intr) >= 4:
            e["fx"], e["fy"], e["cx"], e["cy"] = (float(intr[0]), float(intr[1]),
                                                  float(intr[2]), float(intr[3]))
        ct = f.get("cameraTransform")
        if ct and len(ct) == 16:
            M = mat4_from_colmajor(ct)              # camera-to-world (world<-cam)
            Rcw, tcw = mat4_inverse_rigid(M)        # world->cam (CamFromWorld)
            e["q"] = quat_wxyz_from_R(Rcw)          # wxyz
            e["t"] = tcw
        else:
            no_pose += 1
        out.append(e)
    json.dump(out, open(sys.argv[2], "w"))
    print("wrote %d frames (%d without pose) to %s" % (len(out), no_pose, sys.argv[2]))

if __name__ == "__main__":
    main()
