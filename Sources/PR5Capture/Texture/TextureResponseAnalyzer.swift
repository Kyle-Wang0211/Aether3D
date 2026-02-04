//
// TextureResponseAnalyzer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 5 + G: 纹理响应和闭环
// 纹理响应分析，重复模式检测，新颖性评估
//

import Foundation

/// Texture response analyzer
///
/// Analyzes texture response with repetition pattern detection.
/// Evaluates novelty in texture patterns.
public actor TextureResponseAnalyzer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Texture history
    private var textureHistory: [(timestamp: Date, texture: TextureDescriptor)] = []
    
    /// Repetition scores
    private var repetitionScores: [Double] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Texture Analysis
    
    /// Analyze texture response
    ///
    /// Analyzes texture and detects repetition patterns
    public func analyzeTexture(_ texture: TextureDescriptor) -> TextureAnalysisResult {
        textureHistory.append((timestamp: Date(), texture: texture))
        
        // Keep only recent history (last 100)
        if textureHistory.count > 100 {
            textureHistory.removeFirst()
        }
        
        // Detect repetition
        let repetitionScore = detectRepetition(texture)
        repetitionScores.append(repetitionScore)
        
        // Keep only recent scores (last 100)
        if repetitionScores.count > 100 {
            repetitionScores.removeFirst()
        }
        
        // Calculate novelty (inverse of repetition)
        let novelty = 1.0 - repetitionScore
        
        return TextureAnalysisResult(
            repetitionScore: repetitionScore,
            novelty: novelty,
            texture: texture
        )
    }
    
    /// Detect repetition patterns
    private func detectRepetition(_ texture: TextureDescriptor) -> Double {
        guard textureHistory.count >= 2 else { return 0.0 }
        
        // Compare with recent textures
        let recent = Array(textureHistory.suffix(5))
        var similarities: [Double] = []
        
        for (_, otherTexture) in recent {
            if otherTexture.id != texture.id {
                let similarity = computeSimilarity(texture, otherTexture)
                similarities.append(similarity)
            }
        }
        
        // Average similarity indicates repetition
        let avgSimilarity = similarities.isEmpty ? 0.0 : similarities.reduce(0.0, +) / Double(similarities.count)
        
        return min(1.0, avgSimilarity)
    }
    
    /// Compute texture similarity
    private func computeSimilarity(_ a: TextureDescriptor, _ b: TextureDescriptor) -> Double {
        // Simplified similarity based on feature vectors
        let diff = zip(a.features, b.features).map { abs($0 - $1) }.reduce(0.0, +)
        let maxDiff = Double(a.features.count) * 1.0
        return 1.0 - min(1.0, diff / maxDiff)
    }
    
    // MARK: - Data Types
    
    /// Texture descriptor
    public struct TextureDescriptor: Sendable {
        public let id: UUID
        public let features: [Double]
        public let timestamp: Date
        
        public init(id: UUID = UUID(), features: [Double], timestamp: Date = Date()) {
            self.id = id
            self.features = features
            self.timestamp = timestamp
        }
    }
    
    /// Texture analysis result
    public struct TextureAnalysisResult: Sendable {
        public let repetitionScore: Double
        public let novelty: Double
        public let texture: TextureDescriptor
    }
}
