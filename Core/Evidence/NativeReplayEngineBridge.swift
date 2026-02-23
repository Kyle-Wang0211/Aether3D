// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// Native bridge for the evidence replay engine.
/// Wraps deterministic EvidenceState canonical JSON encoding and SHA-256
/// verification used for replay stability checks.
enum NativeReplayEngineBridge {

    /// Encode an evidence state snapshot to canonical JSON.
    /// Returns the JSON bytes or nil on failure.
    static func encodeCanonicalJSON(
        patches: [aether_evidence_patch_snapshot_t],
        gateDisplay: Double,
        softDisplay: Double,
        lastTotalDisplay: Double,
        schemaVersion: String,
        exportedAtMs: Int64
    ) -> Data? {
        #if canImport(CAetherNativeBridge)
        var mutablePatches = patches
        return schemaVersion.withCString { schemaCStr in
            mutablePatches.withUnsafeMutableBufferPointer { patchBuf in
                var input = aether_evidence_state_input_t()
                input.patches = UnsafePointer(patchBuf.baseAddress)
                input.patch_count = Int32(patches.count)
                input.gate_display = gateDisplay
                input.soft_display = softDisplay
                input.last_total_display = lastTotalDisplay
                input.schema_version = schemaCStr
                input.exported_at_ms = exportedAtMs

                var capacity: Int32 = BridgeInteropConstants.canonicalJSONScratchCapacity
                var buffer = [CChar](repeating: 0, count: Int(capacity))
                let rc = aether_evidence_state_encode_canonical_json(
                    &input, &buffer, &capacity)
                guard rc == 0 else { return nil }
                return Data(buffer.prefix(Int(capacity)).map { UInt8(bitPattern: $0) })
            }
        }
        #else
        return nil
        #endif
    }

    /// Compute the canonical SHA-256 hex digest for an evidence state snapshot.
    static func canonicalSHA256Hex(
        patches: [aether_evidence_patch_snapshot_t],
        gateDisplay: Double,
        softDisplay: Double,
        lastTotalDisplay: Double,
        schemaVersion: String,
        exportedAtMs: Int64
    ) -> String? {
        #if canImport(CAetherNativeBridge)
        var mutablePatches = patches
        return schemaVersion.withCString { schemaCStr in
            mutablePatches.withUnsafeMutableBufferPointer { patchBuf in
                var input = aether_evidence_state_input_t()
                input.patches = UnsafePointer(patchBuf.baseAddress)
                input.patch_count = Int32(patches.count)
                input.gate_display = gateDisplay
                input.soft_display = softDisplay
                input.last_total_display = lastTotalDisplay
                input.schema_version = schemaCStr
                input.exported_at_ms = exportedAtMs

                var hex = [CChar](repeating: 0, count: 65)
                let rc = aether_evidence_state_canonical_sha256_hex(&input, &hex)
                guard rc == 0 else { return nil }
                return hex.withUnsafeBufferPointer { buf in
                    buf.baseAddress.map { String(cString: $0) }
                }
            }
        }
        #else
        return nil
        #endif
    }
}
