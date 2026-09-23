# PocketWorld point-cloud LOD core — upstream sources and deviations

Nothing here is invented. Every formula and constant is transliterated from a
permissively-licensed upstream, cited by file and line. Deviations are D1…Dn.

## Upstreams and licences (LICENCE text read, not the GitHub badge)

Full 40-hex revisions are in `upstream_licenses/REVISIONS.txt`, and each
upstream's licence text is copied verbatim into `upstream_licenses/` at that
revision. Every cited file was re-fetched at its pinned revision and compared
byte-for-byte with the copy the port was written from: all five are identical,
so every line number below holds at the pinned revision.

| Part | Upstream | Revision | Licence | Read at |
|---|---|---|---|---|
| Octree format (writer) | `potree/PotreeConverter` `Converter/include/HierarchyBuilder.h` | `8bfad98d2a6b` | BSD-2-Clause | `LICENSE`, repo root |
| Octree format (reader) | `potree/potree` `src/modules/loader/2.0/OctreeLoader.js` | `5636cd471d9e` | BSD-2-Clause | `LICENSE`, repo root |
| Selection | `potree/potree` `src/Potree_update_visibility.js` | `5636cd471d9e` | BSD-2-Clause | same |
| Budget constant | `potree/potree` `src/Potree.js:101` | `5636cd471d9e` | BSD-2-Clause | same |
| `minimumNodePixelSize` | `potree/potree` `src/PointCloudOctree.js:113` | `5636cd471d9e` | BSD-2-Clause | same |
| Frustum | `mrdoob/three.js` `src/math/Frustum.js` | `6101189ee28b` | MIT | repo `LICENSE` |
| Adaptive controller | `CesiumGS/cesium` `packages/engine/Source/Scene/Cesium3DTileset.js:3005-3037` | `113c068e9af3` | Apache-2.0 | `LICENSE.md` |
| JSON | `nlohmann/json` single header | `v3.11.3` | MIT | `LICENSE.MIT`, vendored |

### Deliberately NOT used

- `m-schuetz/Potree-Next` — **AGPL-3.0**, author sells a commercial exception.
- `hobu/untwine` — **GPL-3.0**, README states commercial use requires a licence.
- `hobu/entwine` — **LGPL-2.1**, no linking exception.
- Potree `src/materials/shaders/edl.fs`, `normalize_and_edl.fs`,
  `EyeDomeLightingMaterial.js` — self-declared derivatives of **CloudCompare
  (GPL-2.0+)**. If eye-dome lighting is wanted, use CesiumJS's
  `PointCloudEyeDomeLighting.glsl` (61 lines, Apache-2.0, no GPL lineage).
- PotreeConverter's vendored `Converter/libs/laszip` — **LGPL-2.1** snapshot
  taken before LASzip relicensed. Upstream LASzip is Apache-2.0 today. We do not
  ship it: only the offline converter reads LAS, and production will read our own
  format.

## Cross-platform self-certification

Grepping `include/aether/pointcloud_lod/` and `src/pointcloud_lod/` for `__APPLE__ __ANDROID__ TARGET_OS Metal MTLDevice Vulkan VK_
D3D11 D3D12` **with comment lines stripped first** → **0 hits**. (Grepping
without stripping returns exactly 1 hit: the sentence in `include/aether/pointcloud_lod/octree.h:3`
that makes this claim. A check that its own claim satisfies is not a check.)
No vendor API, no per-OS branch. Desktop and every mobile GPU family run the
identical code path.

## Deviations

**D1 `__debugbreak()` → `__builtin_trap()`** *(PotreeConverter port, offline tool only)*
MSVC intrinsic; does not exist in GCC/Clang. On Windows with no debugger
attached `__debugbreak()` raises `STATUS_BREAKPOINT` and kills the process, which
`__builtin_trap()` reproduces exactly. 3 sites.

**D2 nlohmann `json → std::string` made explicit** *(PotreeConverter port)*
`state->name = js["state"]["name"]` is ambiguous with modern nlohmann; changed to
`.get<std::string>()`. 4 sites. Semantics identical.

**D3 duplicate NIR block deleted** *(PotreeConverter port)*
`Converter/src/chunker_countsort_laszip.cpp:655-675` contains the same 10-line
block twice at upstream HEAD — a copy-paste defect that does not compile under
GCC. The patch asserts the two blocks are byte-identical before removing the
second.

**D4 matrices are row-major** *(three.js port)*
three.js `Matrix4.elements` is column-major. `frustumFromViewProjectionWebGPU`
takes row-major `m[r*4+c]`; the index mapping is written out per plane so it can
be checked against `Frustum.js:104-125` by eye.

**D5 WebGPU clip space, not WebGL** *(three.js port)*
`Frustum.js:118-125` has two near-plane formulas. We take the
**WebGPUCoordinateSystem** branch (`:124`, `planes[5] = (me2, me6, me10, me14)`)
because we render through Dawn, where clip z is `[0,1]`. Taking the WebGL branch
would silently mis-place the near plane.

**D6 no clip boxes** *(Potree port)*
`Potree_update_visibility.js:184-271` handles user clip volumes. We have no such
feature, so that block is omitted. It cannot change which nodes are selected when
no clip box exists.

**D7 no orthographic path** *(Potree port)*
`Potree_update_visibility.js:382-390`'s ortho branch is `// TODO ortho visibility`
upstream and uses the box diagonal, ignoring distance. Omitted rather than
copied; the viewer is perspective.

**D8 (RESOLVED 2026-09-23) GPU-upload throttle and asynchronous loading**
The first version said "the throttle belongs to the loader" and then never put
it anywhere: `NodeLoader::load` read and decoded every missing node of the frame
synchronously, with no limit, inside the frame. Measured on the bench, that is
where the 33 ms misses during camera motion came from. Now ported as-is from
potree @ `5636cd471d9eb464969e758be45c44d7613d3859`:

| Potree | here |
|---|---|
| `Potree_update_visibility.js:122` `loadedToGPUThisFrame = 0` | `selectImpl` local |
| `:299-307` promote a loaded geometry node whose parent is a tree node, `< 2` per frame, else push to `unloadedGeometry` | `selectVisible(..., Residency)`: `Selection::promoted` / `Selection::unloaded` |
| `:309-315` only tree nodes are drawn | `Selection::nodes` holds only drawable nodes |
| `:347-393` children pushed for every visible node | unchanged walk (`parentDrawable` carried per queue item) |
| `:406-408` start at most `maxNodesLoading` loads, in priority order | `AsyncNodeLoader::request` |
| `Potree.js:103-104` `numNodesLoading`, `maxNodesLoading = 4` | `AsyncNodeLoader::Config::maxNodesLoading = 4` |
| `OctreeGeometry.js:72-79`, `OctreeLoader.js:14-21` early returns | same checks in `request` |
| `OctreeLoader.js:35-57` one byte range per node; `:66-114` decode in a worker, flags set on the main thread | worker `std::thread`s read + decode; `poll()` (main thread) marks loaded |
| `OctreeLoader.js:140-148` failed load resets flags and is retried | failed read is dropped, requested again next frame |
| `LRU.js:138-170` evict least-recently-used + all loaded descendants | cache eviction callback + `disposeDescendants` in `poll()` |
| `:310` drawn nodes are LRU-touched | `AsyncNodeLoader::touch` |
| `viewer.js:1628` `pointLoadLimit = pointBudget * 2` | recommended `cacheBytes = 2 x 15 B x pointBudget` |

"Parent instead of a missing child": Potree never draws a hole. A node becomes
drawable only while its parent is drawable (`:299`), and the octree is
additive — a parent's points are a subsample of its whole subtree and are drawn
alongside the children — so while a child is loading its region is already
covered by the parent's coarser points. The streaming selection keeps exactly
that; `test_async` A4 checks it every frame and N4 shows the check can fail.
The synchronous `selectVisible(oct, cam, p)` and `NodeLoader` are unchanged.

**D9 `inf` in metadata.json is reported, not tolerated**
PotreeConverter writes bare `inf` for an attribute that received no data, which
is not valid JSON. That only happens when an attribute is requested twice
(see the `--attributes` note below). `loadOctree` returns a plain error instead
of throwing.

**D10 the controller's error signal is frame time, not memory** ← *the one real design choice*
CesiumJS `Cesium3DTileset.js:3005-3010` drives its multiplicative controller from
`totalMemoryUsageInBytes < cacheBytes`. We drive the same controller shape from
the measured duration of the previous frame, because the requirement is a stable
30 fps. **The step (`*1.02` / `/1.02`, `:3023`, `:3032`) and the clamp (`:3033`)
are Cesium's; only the comparison changed.** No upstream anywhere implements a
"last frame time → LOD" closed loop — this is the single place where nothing
could be copied outright, and it is called out rather than hidden.

**D11 (WITHDRAWN 2026-09-23) the controller adjusts a point budget**
The first version drove `pointBudget` and left `minimumNodePixelSize` fixed at
Potree's 150. **Measurement retired it.** `test_ab_knob` ran both arms at the
same 30 fps target, same cost model, on both a 36M and a 216M cloud:

| cloud | threshold-driven wins | budget-driven wins | ties |
|---|---|---|---|
| 36M | 4 / 6 | 0 | 2 |
| 216M | **6 / 6** | 0 | 0 |

Driving the budget wastes the frame: at 4.00R on the 216M cloud it drew 39,558
points in **0.6 ms of a 33.3 ms frame** — 98% of the budget unused — because the
fixed 150 px stopped the descent long before the budget could bind. Driving the
threshold drew 3,625,993 points at the same 30 fps, a **91x** difference.
Both arms honoured the frame-time target at every viewpoint.

So the shipped controller (`QualityController`) drives
**`minimumNodePixelSize`**, Potree's analogue of Cesium's `screenSpaceError`,
and the point budget is only a hard ceiling — **which is exactly Cesium's own
arrangement** (`Cesium3DTileset.js:3005-3037` adjusts the error threshold and
treats memory as the ceiling). This deviation is withdrawn, not replaced: the
code now matches upstream's shape more closely than it did.

**D12 a node's CPU and GPU copies are two states, not one** *(Potree port)*
In Potree the decoded `geometry` is the GPU buffer, so "loaded" and "tree node"
differ only by `toTreeNode`. Here the library owns decoded points (CPU) and the
renderer owns GPU buffers, so `NodeState` has three values (`Unloaded`,
`Loaded`, `Drawable`) and the renderer reports `Drawable`. The 2-per-frame limit
applies to the Loaded → Drawable step, i.e. to GPU uploads, as in Potree.

**D13 the cache limit is bytes, Potree's is points** *(Potree port)*
`LRU.js:143` compares `numPoints` with `pointLoadLimit`; `NodeCache` (PR #98)
counts bytes. Decoded points are a fixed 15 B, so this is a constant factor;
`2 x 15 B x pointBudget` reproduces `viewer.js:1628`.

**D14 density grid index clamped at 0** *(Potree port)*
`DecoderWorker.js:45-51` clamps only the upper end; a point a rounding error
below the node minimum would index below 0 and be dropped from the count by
JavaScript. Clamped to `[0, 31]` here. Points are inside their node box by
construction (`test_octree` C3), so this changes no density on real data.

**D15 eviction happens when a node arrives, and covers loaded-but-undrawn nodes** *(Potree port)*
Potree runs `lru.freeMemory()` once per frame after the walk
(`Potree_update_visibility.js:30`), and only drawn (touched) nodes are in its
LRU (`LRU.js:38-40`), so a node that finished loading but was never drawn is
not memory-bounded. Here a node enters the byte-bounded cache as soon as
`poll()` receives it, and eviction happens there. Both evict least recently
used first; ours is the stricter memory bound. Evicted nodes and their disposed
descendants are reported by `drainEvicted()` so the renderer frees GPU copies.

**D16 worker count is fixed** *(Potree port)*
Potree's `WorkerPool.js` creates a worker per concurrent request on demand;
concurrency is capped by `maxNodesLoading` anyway. Here `Config::workers`
threads are started once; with `workers >= maxNodesLoading` the behaviour is
the same.

## Operating notes found by testing, not by reading

- `PotreeConverter --attributes` **must not be given `position`**:
  `PotreeConverter.h:266` prepends it unconditionally, so passing it explicitly
  writes the attribute twice (30 B/point) and produces the invalid-JSON metadata
  of D9. Use `--attributes rgb`.
- PotreeConverter 2.0 reads **LAS/LAZ only**; PLY support existed in 1.x and was
  removed.
- `sampler_poisson.h:113` uses a fixed `thread_local vector<Point>
  dbgAccepted(1'000'000)` and writes into it **without a bounds check**. The
  per-node accepted count is bounded by `(boxSize/spacing)^3 = 128^3 ≈ 2.1M` for
  volumetric data, so this can overflow. Surface-like clouds (ours, ≈16K/node)
  stay far below it. Not fixed here — flagged.
