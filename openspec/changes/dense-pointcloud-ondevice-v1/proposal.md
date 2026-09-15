# Change: On-device dense point cloud v1 (CasDiffMVS → official fusion → PLY, no cloud)

## Why

The product must produce a dense indoor point cloud from the phone's own photos
and SfM poses, entirely on the device (no CUDA, no cloud). The network path is
already proven: the AB ep2 CasDiffMVS weight runs as a fused ONNX graph on
ORT-WebGPU on an iPhone 14 Pro (A16: 2002.7 ms/frame, 1319 MB, numerically
equal to PyTorch on the 97-frame fixture, 2026-09-14). What is missing between
"depth maps on the phone" and "point cloud in the app" is (1) the per-frame
runner inside the product app and (2) the depth-map fusion. Fusion has so far
existed only as Python (official `filter.py` + the certified `fuse_official.py`).

## What Changes

- **Stage 2 (this batch): fusion in C++.** `aether_cpp/src/dense/dense_fuse.{h,cc}`
  is a line-by-line port of cvg/diffmvs `filter.py` (`reproject_with_depth`
  :8-61, `check_geometric_consistency` :64-105) and of the certified producer
  `fuse_official.py` (photometric AND, geo_sum, depth averaging, world
  back-projection, PLY). Bilinear resampling is **not re-implemented**: the port
  calls `cv::remap`, the same OpenCV function `filter.py:41` calls, from the
  OpenCV 4.0.1 archive the iPhone product already links.
- **Byte gate.** A host harness (`test_fuse.cc`) writes the same per-frame
  artifacts as the Python reference; masks, geo sums, averaged depths, world
  points and colours must be bit-identical (no tolerance).
- **Stage 1 (next batch): product runner.** ORT-WebGPU session fed by the app's
  SfM poses and images through the byte-exact `dense_preproc` path, then Stage 2,
  then the PLY handed to the app. Designed after Stage 2's gate is green.

## Non-goals

- No TSDF / mesh (explicitly deferred by the product owner, 2026-09-15).
- No change to fusion constants. The fixture97 certified run
  (`geo_mask_thres=3`, `geo_pixel_thres=1.0`, `geo_depth_thres=0.01`, photometric
  0.3/0.5/0.5) is reproduced as-is; the three official constant sets are a
  separate, already-recorded decision.
- No LiDAR anywhere in the product pipeline.

## Capabilities

### New Capabilities

- `dense-fusion-official-v1`: official CasDiffMVS fusion semantics in
  cross-platform C++ with a bit-exact host gate against the official Python.
