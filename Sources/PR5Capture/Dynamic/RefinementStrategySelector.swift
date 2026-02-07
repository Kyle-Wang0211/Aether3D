//
// RefinementStrategySelector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 4 + F: 动态场景和细化
// 细化策略选择，自适应处理，策略优化
//

import Foundation

/// Refinement strategy selector
///
/// Selects refinement strategies based on scene characteristics.
/// Provides adaptive processing strategies.
public actor RefinementStrategySelector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Strategy Types
    
    public enum RefinementStrategy: String, Codable, Sendable, CaseIterable {
        case none           // No refinement
        case light          // Light refinement
        case moderate       // Moderate refinement
        case aggressive     // Aggressive refinement
        case adaptive       // Adaptive refinement
    }
    
    // MARK: - State
    
    /// Strategy history
    private var strategyHistory: [(timestamp: Date, strategy: RefinementStrategy, context: [String: Double])] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Strategy Selection
    
    /// Select refinement strategy
    ///
    /// Chooses strategy based on scene characteristics
    public func selectStrategy(
        sceneType: DynamicSceneClassifier.SceneType,
        complexity: Double,
        quality: Double
    ) -> StrategySelectionResult {
        let strategy: RefinementStrategy
        
        switch sceneType {
        case .staticScene:
            strategy = quality < 0.7 ? .moderate : .light
            
        case .slowMotion:
            strategy = quality < 0.6 ? .moderate : .light
            
        case .moderateMotion:
            strategy = quality < 0.5 ? .aggressive : .moderate
            
        case .fastMotion:
            strategy = .aggressive
            
        case .complex:
            strategy = .adaptive
        }
        
        // Encode scene type as numeric value for context
        let sceneTypeValue: Double
        switch sceneType {
        case .staticScene: sceneTypeValue = 0.0
        case .slowMotion: sceneTypeValue = 0.25
        case .moderateMotion: sceneTypeValue = 0.50
        case .fastMotion: sceneTypeValue = 0.75
        case .complex: sceneTypeValue = 1.0
        }

        let context = [
            "sceneType": sceneTypeValue,
            "complexity": complexity,
            "quality": quality
        ]
        
        // Record selection
        strategyHistory.append((timestamp: Date(), strategy: strategy, context: context))
        
        // Keep only recent history (last 100)
        if strategyHistory.count > 100 {
            strategyHistory.removeFirst()
        }
        
        return StrategySelectionResult(
            strategy: strategy,
            sceneType: sceneType,
            complexity: complexity,
            quality: quality
        )
    }
    
    // MARK: - Queries
    
    /// Get most used strategy
    public func getMostUsedStrategy() -> RefinementStrategy? {
        guard !strategyHistory.isEmpty else { return nil }
        
        var counts: [RefinementStrategy: Int] = [:]
        for (_, strategy, _) in strategyHistory {
            counts[strategy, default: 0] += 1
        }
        
        return counts.max(by: { $0.value < $1.value })?.key
    }
    
    // MARK: - Result Types
    
    /// Strategy selection result
    public struct StrategySelectionResult: Sendable {
        public let strategy: RefinementStrategy
        public let sceneType: DynamicSceneClassifier.SceneType
        public let complexity: Double
        public let quality: Double
    }
}
