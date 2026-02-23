# Core/System Boundary Audit (PR1-PR10)

Date: 2026-02-19
Scope: `/Core` (Swift system/core module) + `/aether_cpp` (C++ native core)

## Boundary Principle

- C++ core owns: algorithms + data structures + deterministic kernels.
- Swift system layer owns: platform SDK integration, UI/UX orchestration, storage adapters, compliance IO.

## Functional Overlap Audit

| Capability | Swift Path | C++ Path | Canonical Owner | Status |
|---|---|---|---|---|
| D-S fusion | `Core/Evidence/Fusion/DSMassFusion.swift` | `aether_cpp/src/evidence/ds_mass_function.cpp` | C++ | Migrated call path (Swift delegates to C API first) |
| Coverage estimator | `Core/Evidence/Fusion/CoverageEstimator.swift` | `aether_cpp/src/evidence/coverage_estimator.cpp` | C++ | Migrated call path (Swift delegates to C API first) |
| TSDF integration | `Core/TSDF/*` | `aether_cpp/src/tsdf_volume.cpp` + `aether_cpp/src/tsdf/*` | C++ | Second-round runtime-state sink completed; per-pixel fusion path still hybrid |
| Admission control | `Core/Evidence/UnifiedAdmissionController.swift`, `Core/Quality/Admission/AdmissionController.swift` | `aether_cpp/src/evidence/admission_controller.cpp`, `aether_cpp/src/evidence/pr1_admission_kernel.cpp` | C++ | Migrated call path (Swift delegates to C API first) |
| Merkle tree + proofs | `Core/MerkleTree/*` | `aether_cpp/src/merkle/*` | C++ | Migrated call path (Swift delegates to C API first) |
| Deterministic JSON | `Core/Evidence/TrueDeterministicJSONEncoder.swift`, `Core/Jobs/DeterministicEncoder.swift` | `aether_cpp/src/evidence/deterministic_json.cpp` | C++ | Canonical evidence path migrated; generic JSON remains Swift serialization shell |
| SHA256 | `Core/Quality/Serialization/SHA256Utility.swift`, `Core/Upload/*` | `aether_cpp/src/crypto/sha256.cpp` | C++ | Migrated hash kernel path (Upload integrity hashing uses C API) |
| F1/F3/F5/F6 | Swift scattered flow modules | `aether_cpp/src/innovation/f1_*.cpp`, `f3_*`, `f5_*`, `f6_*` | C++ | C API present |
| GPU scheduler | Swift schedulers in capture/upload flows | `aether_cpp/src/scheduler/gpu_scheduler.cpp` | C++ | C API present |
| Token bucket/view diversity/spam | `Core/Evidence/TokenBucketLimiter.swift`, `Core/Evidence/ViewDiversityTracker.swift`, `Core/Evidence/SpamProtection.swift` | `aether_cpp/src/evidence/admission_controller.cpp` | C++ | Migrated call path (Swift delegates to C API first) |

## Swift System-Layer-Only Responsibilities

- Frame quality sensors and camera/IMU sampling.
- UI overlays, hints/arrows, animation orchestration.
- ARKit/ARCore/Harmony platform SDK interaction.
- Audit log physical persistence, keychain/keystore, device attestation.
- Compliance/privacy APIs and user consent workflow.

## This Change Set (Implemented)

1. SwiftPM adds native bridge targets:
   - `AetherNativeCore` (builds `aether_cpp` C++ core)
   - `CAetherNativeBridge` (C header bridge for Swift)
2. C API expanded with D-S fusion entrypoints:
   - `aether_ds_mass_sealed`
   - `aether_ds_combine_dempster`
   - `aether_ds_combine_yager`
   - `aether_ds_combine_auto`
   - `aether_ds_discount`
   - `aether_ds_from_delta_multiplier`
3. Swift `DSMassFusion` now routes to C++ first, retains deterministic Swift fallback.
4. Swift `CoverageEstimator` now routes to C++ first.
5. C API expanded with evidence admission primitives:
   - `aether_spam_protection_*`
   - `aether_token_bucket_*`
   - `aether_view_diversity_*`
   - `aether_admission_controller_*`
6. Swift `SpamProtection`, `TokenBucketLimiter`, `ViewDiversityTracker`, and `UnifiedAdmissionController` now route to C++ first.
7. Upload integrity hashing now routes to C++ SHA256 kernel:
   - `Core/Upload/StreamingMerkleTree.swift`
   - `Core/Upload/ChunkCommitmentChain.swift`
   - `Core/Upload/DualDigest.swift`
   - `Core/Upload/HashCalculator.swift`
8. `Core/Jobs/DeterministicEncoder.swift` now routes hash computation to `SHA256Utility` (C++ SHA256 backend).
9. TSDF runtime state second-round migration:
   - C++/C API `TSDFRuntimeState` extended with meshing congestion and motion-control fields.
   - Swift `NativeTSDFRuntimeBridge` + `TSDFVolume` now sync these fields via a unified runtime snapshot.

## Next Cutover Order

1. TSDF per-pixel integration migration (Swift keeps platform buffers + UI, C++ owns voxel/marching/fusion math end-to-end).
2. Upload `StreamingMerkleTree` carry-stack/state migration from Swift to C++ (hash kernel already migrated).
3. Keep PR1 as orchestration-only in Swift; any new policy math must land in `aether_cpp/src/evidence/pr1_admission_kernel.cpp`.
