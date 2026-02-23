// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BundleError.swift
//  Aether3D
//
//  PR#8: Immutable Bundle Format - Error Types
//

import Foundation

/// Bundle operation errors.
///
/// **Equatable**: Auto-synthesized by compiler because all associated values
/// are themselves Equatable (String, Int, Int64). This enables equality testing
/// in unit tests without custom == implementation.
///
/// **FailClosedError Codes**: 0x2409-0x240F allocated for PR#8 bundle integrity violations.
public enum BundleError: Error, Sendable, Equatable {
    case emptyAssets
    case tooManyAssets(count: Int, max: Int)
    case bundleTooLarge(totalBytes: Int64, maxBytes: Int64)
    case assetNotFound(path: String)
    case assetSizeMismatch(path: String, expected: Int64, actual: Int64)
    case assetHashMismatch(path: String)          // 0x240B: CRITICAL - tampered file content
    case merkleRootMismatch(expected: String, actual: String)  // 0x240A: CRITICAL - tampered asset tree
    case bundleHashMismatch(expected: String, actual: String)  // 0x2409: CRITICAL - tampered manifest
    case invalidDigestFormat(String)              // 0x240D: MEDIUM - malformed OCI digest
    case invalidManifest(String)                   // 0x240E: MEDIUM - schema/field violation
    case sealViolation(String)                     // 0x240C: HIGH - post-seal modification attempt
    case symlinkEscape(path: String)               // 0x240F: CRITICAL - path traversal via symlink
    case unknownRequiredCapability(String)         // fail-closed on unknown capability
    case duplicatePath(path: String)               // duplicate asset paths
    
    /// FailClosedError code for this error.
    public var failClosedCode: UInt16 {
        switch self {
        case .bundleHashMismatch: return 0x2409
        case .merkleRootMismatch: return 0x240A
        case .assetHashMismatch: return 0x240B
        case .sealViolation: return 0x240C
        case .invalidDigestFormat: return 0x240D
        case .invalidManifest: return 0x240E
        case .symlinkEscape: return 0x240F
        default: return 0x2400  // generic bundle error
        }
    }
}
