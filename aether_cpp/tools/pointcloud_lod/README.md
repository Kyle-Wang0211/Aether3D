# Point-cloud LOD — offline tools

Everything needed to turn a dense `.ply` into the octree the runtime streams,
and to prove the conversion kept every point. Requires Python 3 with `numpy`.

## Build an octree

PotreeConverter 2.0 (BSD-2-Clause) does the building. **As shipped it runs on a
desktop or Linux box only** — upstream has no iOS/Android code path, its Android
attempt (PR #686) produces broken nodes, and it hard-codes 2 GB memory watermarks
and reads `/proc/self/status`.

> ⚠️ **Open problem.** This repo's product rule is *no cloud, ever*
> (`~/Developer/Aether3D-cross/CLAUDE.md`), and the dense cloud is fused on the
> device. So the octree must be built **on the phone**, and today nothing here
> does that. These tools are the development-time reference: they produce the
> octrees the runtime is tested against and prove the conversion is lossless.
> Bringing the build on-device is not yet done.

```bash
git clone https://github.com/potree/PotreeConverter && cd PotreeConverter
git checkout 8bfad98d2a6b2111cdcb3840cb508b59408d0721
./path/to/potreeconverter_port.sh .        # upstream does not build on Linux/GCC as-is
mkdir build && cd build
CXX=g++-14 cmake -DCMAKE_BUILD_TYPE=Release .. && make -j
```

GCC 14 or newer is required: upstream is C++23 and uses `<print>`.

PotreeConverter 2.0 reads LAS/LAZ only, so bridge the `.ply` first:

```bash
python3 ply2las.py cloud.ply cloud.las
./PotreeConverter cloud.las -o octree/ --attributes rgb
```

Pass `--attributes rgb`, **not** `--attributes "position rgb"`. PotreeConverter
always prepends `position`, so naming it again writes it twice (30 B/point
instead of 18) and leaves the duplicate's bounds at ±infinity, which is then
written into `metadata.json` as a bare `inf` — invalid JSON.

## Prove nothing was lost

```bash
python3 verify_lossless.py octree/ cloud.ply    # count, positions, 2 negative controls
python3 verify_colour.py   octree/ cloud.ply    # colour histograms, 1 negative control
```

`verify_lossless.py` never trusts the `points` field PotreeConverter writes into
`metadata.json`; it counts bytes in `octree.bin`. Both scripts include negative
controls that must be rejected, so a silent pass on a broken judge is caught.

Measured on real captures:

| cloud | build (32 cores) | `octree.bin` ÷ 18 B | position error | colour |
|---|---|---|---|---|
| 36,232,793 points | 18.0 s | exact, Δ 0 | ≤ 1.39 LSB | histograms identical |
| 216,655,968 points | 1 m 49.6 s | exact, Δ 0 | ≤ 1.30 LSB | histograms identical |

The int32 grid PotreeConverter quantises onto is 40–88× finer than the float32
input's own precision, so quantisation discards nothing the input had.

## Files

| file | what |
|---|---|
| `potreeconverter_port.sh` | 8 compile-only fixes so PotreeConverter builds on Linux/GCC (MSVC intrinsics, nlohmann API drift, one upstream copy-paste duplicate). No algorithmic line changes. |
| `ply2las.py` | PLY (xyz f32 + rgb u8) → LAS 1.2 point format 2, with a size self-check. |
| `verify_lossless.py` | Point count and position fidelity, with count-preserving and 100-LSB negative controls. |
| `verify_colour.py` | Per-channel colour histograms, with a one-value negative control. |
| `make_fixture.py` | Regenerates `tests/pointcloud_lod/fixture/` from a real capture, byte-for-byte. |

The runtime library and its tests are in `src/pointcloud_lod/` and
`tests/pointcloud_lod/`; every upstream formula is cited in
`src/pointcloud_lod/DEVIATIONS.md`.
