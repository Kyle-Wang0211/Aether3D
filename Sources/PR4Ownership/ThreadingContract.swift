//
// ThreadingContract.swift
// PR4Ownership
//
// PR4 V10 - Pillar 16: Single-threaded execution model with reentrancy prevention
//

import Foundation

/// Threading contract for PR4
///
/// V9 RULE: PR4 is SINGLE-THREADED ONLY.
public enum ThreadingContract {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Thread Verification
    // ═══════════════════════════════════════════════════════════════════════
    
    private static var expectedThreadID: UInt64?
    
    public static func initialize() {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        expectedThreadID = tid
    }
    
    @inline(__always)
    public static func verifyThread(caller: String = #function) -> Bool {
        guard let expected = expectedThreadID else {
            return true
        }
        
        var current: UInt64 = 0
        pthread_threadid_np(nil, &current)
        
        if current != expected {
            #if DETERMINISM_STRICT
            assertionFailure("Thread violation in \(caller): expected \(expected), got \(current)")
            #else
            print("⚠️ Thread violation in \(caller): expected \(expected), got \(current)")
            #endif
            return false
        }
        
        return true
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Reentrancy Guard
    // ═══════════════════════════════════════════════════════════════════════
    
    public final class ReentrancyGuard {
        private var isExecuting = false
        private let name: String
        private let lock = NSLock()
        
        public init(name: String) {
            self.name = name
        }
        
        public func execute<T>(_ block: () throws -> T) rethrows -> T {
            lock.lock()
            
            guard !isExecuting else {
                lock.unlock()
                #if DETERMINISM_STRICT
                preconditionFailure("Reentrant call to \(name)")
                #else
                preconditionFailure("Reentrant call to \(name)")
                #endif
            }
            
            isExecuting = true
            lock.unlock()
            
            defer {
                lock.lock()
                isExecuting = false
                lock.unlock()
            }
            
            return try block()
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Serial Queue Contract
    // ═══════════════════════════════════════════════════════════════════════
    
    public static func createSerialQueue(label: String) -> DispatchQueue {
        return DispatchQueue(
            label: label,
            qos: .userInitiated,
            attributes: [],
            autoreleaseFrequency: .workItem,
            target: nil
        )
    }
}
