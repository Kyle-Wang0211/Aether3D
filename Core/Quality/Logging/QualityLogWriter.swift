//
//  QualityLogWriter.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 8
//  QualityLogWriter - JSON Lines format log writer
//

import Foundation

/// QualityLogWriter - writes logs in JSON Lines format
public class QualityLogWriter {
    private let filePath: String
    private var buffer: [String] = []
    private let flushThreshold: Int = 10
    
    public init(filePath: String) {
        self.filePath = filePath
    }
    
    /// Write log entry
    public func write(_ entry: String) {
        buffer.append(entry)
        
        if buffer.count >= flushThreshold {
            flush()
        }
    }
    
    /// Flush buffer to file
    public func flush() {
        // Write buffer to file (JSON Lines format)
        let content = buffer.joined(separator: "\n") + "\n"
        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
        buffer.removeAll()
    }
}

