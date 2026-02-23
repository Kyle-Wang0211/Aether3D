// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  EphemeralSigningKeyStore.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

final class EphemeralSigningKeyStore: SigningKeyStore {
    private var cached: SigningKeyMaterial?

    init() {}

    func getOrCreateSigningKey() throws -> SigningKeyMaterial {
        if let c = cached { return c }
        let m = SigningKeyMaterial.generate()
        cached = m
        return m
    }

    func currentPublicKeyString() throws -> String {
        try getOrCreateSigningKey().publicKeyBase64
    }
}

