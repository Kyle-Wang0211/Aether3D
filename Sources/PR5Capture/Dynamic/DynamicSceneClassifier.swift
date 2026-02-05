//
// DynamicSceneClassifier.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 4 + F: 动态场景和细化
// 动态场景分类，运动检测，场景类型识别
//

import Foundation

/// Dynamic scene classifier
///
/// Classifies dynamic scenes based on motion and complexity.
/// Identifies scene types for adaptive processing.
public actor DynamicSceneClassifier {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Scene Types
    
    public enum SceneType: String, Codable, Sendable, CaseIterable {
        case staticScene      // Static scene
        case slowMotion       // Slow motion
        case moderateMotion   // Moderate motion
        case fastMotion       // Fast motion
        case complex          // Complex dynamic scene
    }
    
    // MARK: - State
    
    /// Motion history
    private var motionHistory: [Double] = []
    
    /// Scene classification history
    private var classificationHistory: [(timestamp: Date, type: SceneType, confidence: Double)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Scene Classification
    
    /// Classify dynamic scene
    ///
    /// Classifies scene based on motion characteristics
    public func classifyScene(motionMagnitude: Double, complexity: Double) -> SceneClassificationResult {
        motionHistory.append(motionMagnitude)
        
        // Keep only recent history (last 50)
        if motionHistory.count > 50 {
            motionHistory.removeFirst()
        }
        
        // Classify based on motion and complexity
        let sceneType: SceneType
        let confidence: Double
        
        if motionMagnitude < 0.1 && complexity < 0.3 {
            sceneType = .staticScene
            confidence = 0.9
        } else if motionMagnitude < 0.3 && complexity < 0.5 {
            sceneType = .slowMotion
            confidence = 0.8
        } else if motionMagnitude < 0.6 && complexity < 0.7 {
            sceneType = .moderateMotion
            confidence = 0.75
        } else if motionMagnitude < 0.9 {
            sceneType = .fastMotion
            confidence = 0.7
        } else {
            sceneType = .complex
            confidence = 0.65
        }
        
        // Record classification
        classificationHistory.append((timestamp: Date(), type: sceneType, confidence: confidence))
        
        // Keep only recent history (last 100)
        if classificationHistory.count > 100 {
            classificationHistory.removeFirst()
        }
        
        return SceneClassificationResult(
            sceneType: sceneType,
            confidence: confidence,
            motionMagnitude: motionMagnitude,
            complexity: complexity
        )
    }
    
    // MARK: - Queries
    
    /// Get most common scene type
    public func getMostCommonSceneType() -> SceneType? {
        guard !classificationHistory.isEmpty else { return nil }
        
        var counts: [SceneType: Int] = [:]
        for (_, type, _) in classificationHistory {
            counts[type, default: 0] += 1
        }
        
        return counts.max(by: { $0.value < $1.value })?.key
    }
    
    // MARK: - Result Types
    
    /// Scene classification result
    public struct SceneClassificationResult: Sendable {
        public let sceneType: SceneType
        public let confidence: Double
        public let motionMagnitude: Double
        public let complexity: Double
    }
}
