// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  Aether3DApp.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import SwiftUI

@main
struct Aether3DApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomePage()
            }
            .preferredColorScheme(.dark)
        }
    }
}
