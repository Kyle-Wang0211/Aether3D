//
// DualTrackProcessor.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 7 + I: 隐私加固和双轨
// 双轨处理器，隐私轨道和公开轨道分离
//

import Foundation

/// Dual track processor
///
/// Processes data in two tracks: private and public.
/// Separates privacy-sensitive data from public data.
public actor DualTrackProcessor {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - Track Types
    
    public enum TrackType: String, Sendable {
        case `private`
        case `public`
    }
    
    // MARK: - State
    
    /// Track data
    private var privateTrack: [TrackData] = []
    private var publicTrack: [TrackData] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Track Processing
    
    /// Process data in appropriate track
    ///
    /// Routes data to private or public track based on sensitivity
    public func processData(_ data: TrackData, isPrivate: Bool) -> ProcessingResult {
        if isPrivate {
            privateTrack.append(data)
            
            // Keep only recent (last 100)
            if privateTrack.count > 100 {
                privateTrack.removeFirst()
            }
        } else {
            publicTrack.append(data)
            
            // Keep only recent (last 100)
            if publicTrack.count > 100 {
                publicTrack.removeFirst()
            }
        }
        
        return ProcessingResult(
            track: isPrivate ? .private : .public,
            dataId: data.id,
            timestamp: Date()
        )
    }
    
    // MARK: - Data Types
    
    /// Track data
    public struct TrackData: Sendable {
        public let id: UUID
        public let content: Data
        public let timestamp: Date
        
        public init(id: UUID = UUID(), content: Data, timestamp: Date = Date()) {
            self.id = id
            self.content = content
            self.timestamp = timestamp
        }
    }
    
    /// Processing result
    public struct ProcessingResult: Sendable {
        public let track: TrackType
        public let dataId: UUID
        public let timestamp: Date
    }
}
