# On-device octree builder — upstream and deviations

This library is a **port**, not a reimplementation, of the octree builder in
**PotreeConverter 2.0** (`potree/PotreeConverter` @
`8bfad98d2a6b2111cdcb3840cb508b59408d0721`, BSD-2-Clause, licence text in
`../pointcloud_lod/upstream_licenses/potreeconverter.LICENSE`). The three
algorithmic parts are transliterated line by line and keep upstream's names,
constants and control flow:

| Part | Upstream | Here |
|---|---|---|
| Counting-sort chunking | `Converter/src/chunker_countsort_laszip.cpp` | `chunker_countsort.cpp` |
| Per-chunk local octree (32³ counting sort) | `Converter/src/indexer.cpp:707-1132` | `indexer.cpp` |
| Bottom-up Poisson-disk sampling | `Converter/include/sampler_poisson.h` | `sampler_poisson.h` |
| Chunk-root merge + root sampling | `Converter/src/indexer.cpp:222-301, 1667-1789` | `indexer.cpp` |
| octree.bin writer | `Converter/src/Writer.cpp`, `include/Writer.h` | `writer.{h,cpp}` |
| Hierarchy records → hierarchy.bin | `indexer.h:89-218`, `include/HierarchyBuilder.h` | `indexer.cpp`, `hierarchy_builder.h` |
| metadata.json | `Converter/src/indexer.cpp:376-550` | `indexer.cpp` |
| Driver, scale/offset | `Converter/src/main.cpp`, `include/PotreeConverter.h:29-76` | `build.cpp` |
| Task pool, chunk writer | `modules/unsuck/TaskPool.hpp`, `include/ConcurrentWriter.h` | `task_pool.h`, `concurrent_writer.h` |

The only code that is not a port is the PLY reader (`ply_source.cpp`, see
"Input glue"). Line numbers below are at the pinned revision.

**Not used:** PotreeConverter's vendored `Converter/libs/laszip` (an LGPL-2.1
snapshot) and `libs/brotli`. Nothing from either is compiled or linked.

## Result first

Same input, same revision, node by node (details in "Verification"):

| cloud | desktop run 1 vs run 2 (noise floor) | this port vs desktop |
|---|---|---|
| 25,000-point fixture | — | 82/82 nodes, 0 records differ, metadata.json identical except `name` |
| 36,232,793 points | 16,227 nodes, **0** records differ | 16,227 nodes, **0** records differ, metadata identical except `name` |
| 216,655,968 points | 104,751 nodes, **0** records differ | 104,751 nodes, **0** records differ, metadata identical except `name` |

"0 records differ" = for every node, the multiset of its 18-byte records
(int32 position + uint16 rgb) is identical. Upstream is deterministic at this
level on these clouds (noise floor 0), so the port is held to exact equality.

## Deviations

Every change is a portability, safety or memory change. None alters which point
lands in which node — that is what the verification above measures.

**D1 — types, casts, alignment (mechanical).** Loop counters and indices that
upstream declares `int` against `size_t` containers are given matching types;
narrowing brace-inits get explicit casts (`sampler_poisson.h:104` builds
`Point{..., i, childIndex}` from `int64_t`, which clang rejects); reads of int32
positions through `reinterpret_cast<int32_t*>` (`chunker_countsort_laszip.cpp:990`,
`indexer.cpp:841`, `sampler_poisson.h:98`) become `memcpy` (same value, no
unaligned access). The sampler's per-node lambda returns `void` instead of the
`bool` a `std::function<void(Node*)>` discards (`sampler_poisson.h:57,323`).
Required by the repo's `-Wall -Wextra -Werror`; no value can change.

**D2 — `exit()` / `__debugbreak()` → returned error.** A library inside an app
may not kill the process. Every upstream `exit(n)` on a reachable path
(`chunker_countsort_laszip.cpp:263,1044`, `HierarchyBuilder.h:180,221,229`,
`Writer.cpp:431`, `unsuck.hpp:157`, `TaskPool.hpp:107`, `main.cpp:302`) and the
`__debugbreak()` in `indexer.cpp:966` sets a shared `ErrorState`; workers poll it
and return, `build()` returns `{ok=false, error}`. Upstream ignores most I/O
results; here every open/write/close is checked (disk full is a real case on a
phone). Two null dereferences upstream would hit are turned into errors:
`HierarchyBuilder.h:317/325` (`nodeMap[...]` on a batch with no root entry) and
`indexer.cpp:1014` when the duplicate-removal retry (`:1119-1120`, `nodeIndex--`)
revisits a node its own recursion left without points. The retry itself is kept
as upstream wrote it. std::filesystem calls use the `std::error_code` overloads
(`-fno-exceptions`).

**D3 — LASzip reader → `PointSource`.** Upstream reads points one at a time via
`laszip_read_point` + `laszip_get_coordinates` (`chunker_countsort_laszip.cpp:
227-228, 943-944`). Here each task reads its range through
`PointSource::read(first, count, xyz, rgb)` in sub-batches of 65,536 points and
runs the same per-point code. The output attribute list is fixed to
`[position, rgb]`, so of `createAttributeHandlers` (`:518-820`) only the reset of
the per-thread min/max (`:524-527`) and the rgb handler (`:531-548`) apply; the
LAS-only handlers — including the verbatim-duplicated NIR block at `:655-675`,
which does not compile under GCC — are not ported. Task batching (1,000,000 points,
`:367`, `:1127`) is unchanged.

**D4 — memory knobs (upstream hard-codes desktop sizes).**
- `chunkBacklogMB` replaces `waitUntilMemoryBelow(2'000)` (`:906`), the MB of
  chunk data queued for the flush threads before producers wait. Default 2000.
- `writerRingBytes` replaces `capacity = 1 GiB` (`Writer.h:26`). Upstream
  `exit(4320)`s when one node is larger than the ring (`Writer.cpp:429-432`);
  here that node waits until the ring has drained and is written straight
  through at the offset the ring would have given it. Byte offsets are still
  assigned in `write()` call order, as upstream. Tested with a 4 KiB ring
  (test_build E2): identical tree.
- `maxPointsPerChunkCap` caps upstream's `min(N/20, 10'000'000)` (`:1390-1391`),
  which drives indexing memory (216M points → 10M-point chunks). **Floor: never
  below 10,000** (`indexer.h:49`). Why the cap is output-neutral above the floor:
  a chunk root is a non-empty child of a cell holding more than the cap ≥ 10,000
  points, and `createNodes` (`indexer.cpp:797`) splits every node above 10,000
  points into all its non-empty children anyway, so every chunk root is a node
  of upstream's tree; inside a chunk the local octree and the sampling depend
  only on the points, not on where the chunk boundary was. Below the floor the
  claim is false — the first version of test_build E2 used 100 points/chunk and
  got 1,009 nodes instead of 82. Measured neutral: 36M at 250K (595 chunks vs
  65) and 1M, 216M at 1M (832 chunks vs 100): tree and metadata identical.
  Caveat: metadata `hierarchy.depth` is upstream's `octreeDepth`, which only
  counts levels reached inside `buildHierarchy`'s pyramid path
  (`indexer.cpp:1001`); a chunk under 10,000 points never enters it. A cap can
  in principle turn the deepest leaf into such a chunk and lower that field. It
  did not on any cloud measured. Potree's loader does not use the field for
  traversal.

**D5 — `VBuffer` / `VBufferPool` → heap blocks.** Upstream reserves 1–2 GB of
address space per buffer (`VBufferPool.h:17`, `indexer.cpp:955`) with
`VirtualAlloc`/`mmap(PROT_NONE)` and has only `_WIN32` and `__linux__` branches
(`VBuffer.cpp:5-10, 32-37`); on any other OS `create()` fails and exits, and
thousands of live nodes × 1 GB of reservation does not fit a phone's address
space. Here `commit(n)` is `realloc` (content preserved, `size = n`, same
contract); no call site keeps a pointer across a growing `commit()` (checked:
`indexer.cpp:904-906, 988-993, 1104-1105`, `sampler_poisson.h:249-250, 262-263`,
`Writer.cpp:392-393`; the BROTLI path that would, `Writer.cpp:21-183`, is not
ported, D17). The pool keeps nothing: upstream's pool never gives committed
pages back, so resident memory never falls below its high-water mark.

**D6 — `thread_local` scratch → per call.** `chunker_countsort_laszip.cpp:885-904`
(batch buffer), `indexer.cpp:918` (a leaked `Pyramid*` per thread), `:955` (2 GB
reservation), `:958` (`i64 offsets[32768]`). Same contents, freed when the call
returns. `sampler_poisson.h:113` is D11.

**D7 — globals and function statics → per-build objects.**
`chunker_countsort_laszip.cpp:50-86` (`maxPointsPerChunk`, `gridSize`, `nodes`,
`writer`, `mtx_attributes`) live in a `Chunker`; `indexer.cpp:205`
(`static int64_t offset` in `flushChunkRoot`) is an `Indexer` member. Upstream
runs once per process; `nodes` is never cleared, so a second build in the same
process would reuse the first build's chunk list. `threshold`
(`indexer.cpp:261`) becomes `constexpr`. Progress counters (`:280`, `:1628`) are
D9.

**D8 — stage checkpoints handed over in memory.** Upstream's chunking writes
`chunks/metadata.json` (`chunker_countsort_laszip.cpp:1177-1240`) which
indexing re-reads (`indexer.cpp:60-199`), and indexing writes
`stage_chunkroots/state.json` (`:1134-1261`) which merging re-reads
(`:1263-1411`), so the stages can run as separate processes. Here one call runs
all three and passes the same values in memory. The round trip is lossless
upstream (nlohmann writes doubles round-trip exact), and the reload rebuilds the
same tree the indexer already holds (`addDescendant` of the same chunk roots,
same `sampled`/`numPoints`), so nothing observable changes; the chunk files are
still listed from the directory as upstream does. The resumable-stage feature
(`--stage`) is not offered.

**D9 — console, monitor and progress bookkeeping dropped.** `logger`, `Monitor`
(`main.cpp:596`), `launchMemoryChecker(2 * 1024, 0.1)` (`main.cpp:563`: a
detached thread that reads `/proc/self/status` every 100 ms and never acts on it),
the ConcurrentWriter status thread (`ConcurrentWriter.h:59-83`),
`Indexer::waitUntilMemoryBelow` (`indexer.cpp:361-374`, also `/proc`-based, never
called), `State` progress fields and `createReport`. `State` keeps
`pointsTotal`, the only field the algorithm reads.

**D10 — data race removed.** `chunker_countsort_laszip.cpp:911` copies the shared
`outputAttributes` while other tasks merge into it under `mtx_attributes`
(`:1090`). The copy is now taken under the same mutex. Its min/max are reset
immediately afterwards (`:524-527`), so values cannot change.

**D11 — `dbgAccepted` bounds (`sampler_poisson.h:113`).** Upstream:
`thread_local vector<Point> dbgAccepted(1'000'000)`, written at
`dbgAccepted[dbgNumAccepted]` (`:215`) with no bounds check. Volumetric data can
accept more than 1M points in one node (the bound is roughly
`(nodeSize/spacing)^3 = 128^3`), which overflows the heap. Here it is a per-call
vector filled with `push_back`. Only indices `< dbgNumAccepted` are ever read
(`:145-147`), and upstream never reads stale entries from a previous node, so the
result is identical whenever upstream stays in bounds and well-defined where it
would not. Stress run in "Verification".

**D12 — `std::sort(std::execution::par_unseq, …)` → `std::sort(…)`**
(`sampler_poisson.h:183-204`). Parallel algorithms need TBB with libstdc++ and are
absent from libc++ without `-fexperimental-library`; neither is available on the
phones. Same comparator (squared distance to the node centre). Points at exactly
equal distance may come out in a different order; upstream's own order among
them is unspecified. Measured effect on 36M and 216M: none (0 records differ).
The same applies to the other two `std::execution::par` uses
(`main.cpp:207-225` header reads, `chunker_countsort_laszip.cpp:296-323` LAZ
chunk-table sanity check), which have no counterpart for a single PLY.

**D13 — unused seed dropped.** `sampler_poisson.h:111` computes
`seed = system_clock::now()` and never uses it.

**D14 — thread counts.** `getCpuData().numProcessors`
(`chunker_countsort_laszip.cpp:50-51`, `indexer.h:51-53`) becomes
`BuildOptions::numThreads` (0 = `std::thread::hardware_concurrency()`). Upstream's
formulas are kept: chunker and flush threads = n, indexing threads =
`n / 3 + 2` (`indexer.cpp:1476`), here additionally clamped to n so that
`numThreads = 1` really runs one worker. One writer thread for octree.bin, as
upstream.

**D15 — metadata.json number formatting.** Upstream formats doubles with
`std::format("{}")` (`indexer.cpp:381-389`), i.e. `std::to_chars`' shortest
round-trip form. Floating-point `to_chars` is not available on every mobile
standard library we target, so the digits come from the vendored
nlohmann/json 3.11.3 Grisu2 (round-trip exact, locale-independent) and are laid
out with `to_chars`' rule (fixed or scientific, whichever is shorter; fixed on a
tie). On the fixture, 36M and 216M the file is byte-identical to upstream's
except the `name` line. Non-finite values are written as `null` (upstream would
write `inf`, invalid JSON), and strings are JSON-escaped (upstream writes them
raw; identical for the names we write).

**D16 — node-name length guard.** `HierarchyFlusher` stores names in a 31-byte
field (`indexer.h:171-194`) and `memcpy`s the full name into it (`:191`); a node
deeper than level 30 would overwrite its own `numPoints`. Here that returns an
error. Not reachable on real captures (depth 8 at 36M, int32 grid limits depth to
about 30).

**D17 — not ported:** `--encoding BROTLI` (`Writer.cpp:21-368`),
`--compress-chunks` (`chunker_countsort_laszip.cpp:444-511`, `indexer.cpp:1503-1564`),
the `random` sampler, `--generate-page`, `--stage`, `--projection`, multiple input
files. The output is `encoding: DEFAULT`, which is what the reader supports.

**D18 — attribute list fixed to `[position, rgb]`.** Upstream builds it from the
LAS point format and `--attributes` (`PotreeConverter.h:200-281`) and always
prepends `position` (`:266`); passing `position` explicitly writes it twice and
leaves the duplicate's bounds at ±∞, printed as bare `inf` (invalid JSON). Here
the list is exactly what `--attributes rgb` produces, so that cannot happen.

## Input glue (the only new code)

`ply_source.cpp` reads our dense-cloud PLY: `binary_little_endian 1.0`, one
`vertex` element, exactly `float x, float y, float z, uchar red, uchar green,
uchar blue` (15 B/point). It rejects anything else, a header without
`end_header`, 0 points, a count that does not fit, a file shorter than the header
promises, and NaN/Inf coordinates (upstream's `int32_t((x - offset) / scale)`
would be undefined behaviour on them). What upstream takes from the LAS header,
the glue supplies the way `tools/pointcloud_lod/ply2las.py` — the bridge the
desktop reference octrees were built through — writes it:
- bounds: min/max of the float32 coordinates, as doubles (`ply2las.py:30-31`);
- `targetScale` for `computeScaleOffset`: `max(extent / 2e9, 1e-9)` on every axis
  (`ply2las.py:34`); on real captures upstream's own floor `size/2^30` wins on
  every axis, so scale and offset are exactly the desktop reference's;
- colour: `v * 257` (0→0, 255→65535), `ply2las.py:72-74`.

## Memory knobs and recommended defaults

Upstream's desktop constants cost 1.85 GB on the 36M cloud (12 threads) and
4.45 GB on the 216M cloud (32 threads). The 1 GiB octree ring is touched up to
the size of octree.bin (652 MB at 36M; one thread drops from 1,056 to 376 MB when
ring and backlog shrink to 64 MiB / 64 MB), and indexing memory scales with points
per chunk (10M at 216M). Recommended for a phone
(`optionsForBudget`): `numThreads = min(4, cores)`, `writerRingBytes = 64 MiB`,
`chunkBacklogMB = 128`, `maxPointsPerChunkCap = 1,000,000` — measured 519 MB /
24.3 s on 36M (M3 Pro, 4 threads) and 385 MB on 216M (4 threads, Linux); one
thread brings it to ~340 MB at about 2.4× the time. The budget function keeps
dropping threads while `350 MB + 85 MB × (threads − 1)` (a conservative fit of
the measured numbers) exceeds the budget. Every setting measured produced
upstream's tree. Not measured: a phone itself (no device install in this
change), budgets below ~340 MB.

## Cross-platform self-certification

`include/aether/pointcloud_lod_build/` + `src/pointcloud_lod_build/` with comment
lines stripped, grepped for
`__APPLE__|__ANDROID__|TARGET_OS|Metal|MTL|Vulkan|VK_|D3D` → **0 hits**. No OS
header, no `/proc`, no `mmap`/`VirtualAlloc`; threads, files and memory through
the C++20 standard library only.

## Verification

All comparisons (`tests/pointcloud_lod_build/compare_octrees.py`; in C++ inside
test_build) read `hierarchy.bin` exactly as potree's `OctreeLoader.js:151-232`
does and never trust `metadata.json`'s self-reported `points`. The comparer
reports node-name sets, per-node counts, per-node multisets of 18-byte records,
position-only multisets and the global multiset; its self-test (overwrite one
record of the largest node with one from another node, count unchanged) must
report exactly 2 differing records — it does.

### Noise floor (desktop PotreeConverter @8bfad98, 32 cores, run twice on the same LAS)

| cloud | nodes | records differing | time | peak RSS |
|---|---|---|---|---|
| 36,232,793 | 16,227 / 16,227 | 0 | 7.1 s, 7.1 s | 3.56 GB |
| 216,655,968 | 104,751 / 104,751 | 0 | 61.3 s, 66.3 s | 10.7 GB |

### Port vs desktop (same LAS, read by the test-only `LasSource`)

| cloud | port settings | nodes only in one | records differing | metadata.json | time | peak RSS |
|---|---|---|---|---|---|---|
| fixture 25,000 | defaults (ctest E1) | 0 | 0 | identical except `name` | 0.24 s | — |
| fixture 25,000 | 1 thread, 4 KiB ring (ctest E2) | 0 | 0 | — | — | — |
| 36,232,793 | 32 threads, upstream knobs | 0 | 0 | identical except `name` | 6.3 s | 1.98 GB |
| 216,655,968 | 32 threads, upstream knobs | 0 | 0 | identical except `name` | 58.3 s | 4.45 GB |
| 216,655,968 | 4 threads, 64 MiB ring, 256 MB backlog, 1M-point chunks | 0 | 0 | identical except `name` | 197.5 s | 385 MB |
| 216,655,968 | 1 thread, 64 MiB ring, 128 MB backlog, 1M-point chunks | 0 | 0 | identical except `name` | 488.3 s | 333 MB |

(Linux x86-64, 32 cores, GCC 14, `-O2` + repo strict flags.)

### Product path (PLY) — lossless, and every setting gives the same tree

36,232,793-point PLY on an Apple M3 Pro (12 cores), macOS, clang 17. "Same tree"
= compared node by node with the 12-thread upstream-knob build; all 0 differences
and byte-identical metadata.json.

| threads | ring | backlog | chunk cap | time | peak RSS |
|---|---|---|---|---|---|
| 12 | 1 GiB | 2000 MB | — (1,811,639) | 16.0 s | 1,853 MB |
| 1 | 1 GiB | 2000 MB | — | 54.7 s | 1,056 MB |
| 1 | 64 MiB | 64 MB | — | 55.8 s | 376 MB |
| 1 | 64 MiB | 128 MB | 250,000 | 90.5 s | 337 MB |
| 1 | 64 MiB | 128 MB | 1,000,000 | 57.3 s | 345 MB |
| 2 | 64 MiB | 128 MB | 250,000 | 49.5 s | 405 MB |
| 2 | 64 MiB | 128 MB | 1,000,000 | 34.2 s | 427 MB |
| 4 | 64 MiB | 128 MB | — | 24.8 s | 647 MB |
| 4 | 64 MiB | 128 MB | 250,000 | 34.6 s | 496 MB |
| **4** | **64 MiB** | **128 MB** | **1,000,000** | **24.3 s** | **519 MB** |

Times include the PLY bounds scan (≈1.3 s). Smaller chunks cost time because
more of the tree is sampled in the single-threaded merge stage
(`indexer.cpp:1699-1724`); 1M is the better trade-off than 250K at every thread
count.

Lossless on the 12-thread output (`tools/pointcloud_lod/verify_lossless.py`,
`verify_colour.py`): T1 `octree.bin` 652,190,274 B / 18 = 36,232,793 = input
(Δ 0); T2 per-axis sorted positions ≤ 1.000 LSB (tolerance 2; the int32 grid is
39.7–59.7× finer than float32's ULP at the cloud's extent); T4 all three colour
histograms identical. Negative controls — drop one + duplicate one (count kept),
one point moved 100 LSB, one red value changed — all rejected.

### Reader (PR #98) on the port's output

`test_pointcloud_lod_octree` and `test_pointcloud_lod_select`, unmodified:
- fixture (ctest, `test_pointcloud_lod_build_then_*`): all pass, octree C2 70
  ranges tile `[0, 450000)`.
- 36M: C1 36,232,793 = octree.bin / 18; C2 15,081 ranges tile octree.bin exactly;
  S2 12,480 / 12,480 leaves reachable; all four negative controls rejected.
- 216M: C1 216,655,968 = octree.bin / 18; C2 95,514 ranges tile octree.bin
  exactly; S2 80,372 / 80,372 leaves reachable; all negative controls rejected.

### D11 stress: a node that accepts more than 1,000,000 points

16,000,000 points uniform in a 10 m cube (`tests/pointcloud_lod_build/vol_gen.py`, seed 20260923). Premise
check: the root accepts **2,247,135** points (> 1,000,000, the size of upstream's
`dbgAccepted`). Desktop PotreeConverter on the same cloud: **killed by SIGSEGV**
in the merge stage; gdb backtrace: `SamplerPoisson::sample(...)::{lambda(Node*)#1}`
← `indexer::doMerging`. The port: completes (136 s, 32 threads, 1.37 GB), T1
Δ 0, positions ≤ 1.000 LSB, colour histograms identical, all negative controls
rejected.

### Bad input (ctest B1)

16 malformed PLYs (empty, not PLY, no `end_header`, ascii, big-endian, double
coordinates, wrong property order, a non-vertex element first, 0 points,
non-numeric count, a count that overflows, truncated by one byte, header claiming
1M points for 2, NaN, Inf, all points identical), a missing file and an output
directory under a regular file: every one returns an error, none aborts. Positive
control: a valid 2-point PLY builds.

### Compilers

Library, CLI and tests compile with 0 diagnostics under the repo's
`AETHER_STRICT_COMPILE_OPTIONS` with Apple clang 17 (macOS arm64) and GCC 14.2
(Ubuntu x86-64); the ctest suite passes on both.
