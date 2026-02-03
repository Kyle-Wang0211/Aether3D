//
// LogCallSiteContract.swift
// PR4LUT
//
// PR4 V10 - Pillar 22: Log call-site contract for deterministic logging
//

import Foundation

/// Log call-site contract
///
/// V8 RULE: All logging must be deterministic and call-site tracked.
public enum LogCallSiteContract {
    
    /// Log entry with call site information
    public struct LogEntry {
        public let level: LogLevel
        public let message: String
        public let file: String
        public let function: String
        public let line: Int
        public let timestamp: Date
        
        public init(level: LogLevel, message: String, file: String = #file, function: String = #function, line: Int = #line) {
            self.level = level
            self.message = message
            self.file = file
            self.function = function
            self.line = line
            self.timestamp = Date()
        }
    }
    
    public enum LogLevel: String, Codable {
        case debug
        case info
        case warning
        case error
        case fatal
    }
    
    /// Logger instance
    public final class Logger {
        public static let shared = Logger()
        
        private var entries: [LogEntry] = []
        private let lock = NSLock()
        private let maxEntries = 1000
        
        private init() {}
        
        public func log(_ entry: LogEntry) {
            lock.lock()
            defer { lock.unlock() }
            
            entries.append(entry)
            
            if entries.count > maxEntries {
                entries.removeFirst()
            }
            
            // Console output (rate-limited)
            if shouldLogToConsole(entry) {
                print("[\(entry.level.rawValue.uppercased())] \(entry.file):\(entry.line) \(entry.function) - \(entry.message)")
            }
        }
        
        private func shouldLogToConsole(_ entry: LogEntry) -> Bool {
            switch entry.level {
            case .fatal, .error:
                return true  // Always log errors
            case .warning:
                return entries.filter { $0.level == .warning }.count <= 100
            case .info, .debug:
                return false  // Only log in DEBUG builds
            }
        }
        
        public func exportEntries() -> [LogEntry] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }
    
    /// Convenience logging functions
    public static func log(_ level: LogLevel, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        let entry = LogEntry(level: level, message: message, file: file, function: function, line: line)
        Logger.shared.log(entry)
    }
}
