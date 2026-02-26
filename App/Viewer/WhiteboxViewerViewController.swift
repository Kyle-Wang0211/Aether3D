// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  WhiteboxViewerViewController.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import UIKit
import Aether3DCore
#if canImport(SceneKit) && canImport(ModelIO)
import ModelIO
import SceneKit
import SceneKit.ModelIO
#endif

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

        guard let artifact else {
            showFallbackLabel("Whitebox Viewer\nNo artifact loaded.")
            return
        }

        #if canImport(SceneKit) && canImport(ModelIO)
        if let sceneView = buildSceneView(for: artifact.localPath) {
            view.addSubview(sceneView)
            NSLayoutConstraint.activate([
                sceneView.topAnchor.constraint(equalTo: view.topAnchor),
                sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            ])
            return
        }
        #endif

        showFallbackLabel("Whitebox Viewer\nFailed to load 3D preview.")
    }

    private func showFallbackLabel(_ message: String) {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.text = message
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])
    }

    #if canImport(SceneKit) && canImport(ModelIO)
    private func buildSceneView(for artifactURL: URL) -> SCNView? {
        let scnView = SCNView()
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.backgroundColor = .black
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true

        let scene = SCNScene()
        scnView.scene = scene

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 2.5)
        scene.rootNode.addChildNode(cameraNode)

        guard let contentNode = loadSceneNode(from: artifactURL) else {
            return nil
        }
        scene.rootNode.addChildNode(contentNode)
        return scnView
    }

    private func loadSceneNode(from artifactURL: URL) -> SCNNode? {
        if let loadedScene = try? SCNScene(url: artifactURL, options: nil),
           !loadedScene.rootNode.childNodes.isEmpty {
            let root = SCNNode()
            for node in loadedScene.rootNode.childNodes {
                root.addChildNode(node.clone())
            }
            return root
        }

        let asset = MDLAsset(url: artifactURL)
        asset.loadTextures()
        let mdlScene = SCNScene(mdlAsset: asset)
        guard !mdlScene.rootNode.childNodes.isEmpty else {
            return nil
        }
        let root = SCNNode()
        for node in mdlScene.rootNode.childNodes {
            root.addChildNode(node.clone())
        }
        return root.childNodes.isEmpty ? nil : root
    }
    #endif
}
