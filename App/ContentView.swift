// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ContentView.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import SwiftUI

struct DemoContentView: View {
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Aether3D")
                    .font(.title)
                
                NavigationLink(destination: PipelineDemoView()) {
                    Label("Open Pipeline Demo", systemImage: "play.circle.fill")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Home")
        }
    }
}

#Preview {
    DemoContentView()
}
