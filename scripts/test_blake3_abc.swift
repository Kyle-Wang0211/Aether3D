#!/usr/bin/env swift
// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
// Test script to compute BLAKE3-256("abc") using our implementation

import Foundation

// Simple test to print the hash
let testInput = Data("abc".utf8)
print("Input bytes: \(testInput.map { String(format: "%02x", $0) }.joined())")

// Note: This script requires the Aether3DCore module to be built
// Run via: swift test --filter Blake3GoldenVectorTests.testBlake3_256_Abc_GoldenVector
