// InMemoryAuditLog.swift
// PR#8.5 / v0.0.1

import Foundation
@testable import Aether3DCore

/// In-memory audit log for testing.
///
/// Thread-safety: NOT thread-safe. Use only in single-threaded tests.
///
/// WARNING: This is a TEST HELPER, not production code.
/// Uses [unowned self] for fail-fast semantics.
final class InMemoryAuditLog {
    
    enum TestError: Error, Equatable {
        case simulatedWriteFailure
    }
    
    private(set) var entries: [AuditEntry] = []
    var shouldFailNextWrite: Bool = false
    
    /// Create append closure for emitter injection.
    ///
    /// Uses [unowned self] - caller MUST keep InMemoryAuditLog alive.
    /// Deallocation during use will crash (intentional fail-fast for tests).
    func makeAppendClosure() -> (AuditEntry) throws -> Void {
        return { [unowned self] entry in
            if self.shouldFailNextWrite {
                self.shouldFailNextWrite = false
                throw TestError.simulatedWriteFailure
            }
            self.entries.append(entry)
        }
    }
    
    func clear() {
        entries.removeAll()
        shouldFailNextWrite = false
    }
}

