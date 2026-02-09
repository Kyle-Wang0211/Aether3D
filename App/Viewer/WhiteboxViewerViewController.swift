// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  WhiteboxViewerViewController.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import UIKit

enum ViewerError: Error {
    case unsupportedFormat
    case fileNotFound
}

final class WhiteboxViewerViewController: UIViewController {
    private var artifact: ArtifactRef?
    
    func configure(artifact: ArtifactRef) throws {
        guard artifact.format == .splat || artifact.format == .splatPly else {
            throw ViewerError.unsupportedFormat
        }
        guard FileManager.default.fileExists(atPath: artifact.localPath.path) else {
            throw ViewerError.fileNotFound
        }
        self.artifact = artifact
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        
        // Day 2: no rendering
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.text = "Whitebox Viewer (Day 2)\nRendering not implemented.\n"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])
    }
}

