//
// PreFlightChecks.swift
// PR4Fusion
//
// PR4 V10 - Verification before PR4 processing begins
//

import Foundation
import PR4LUT
import PR4Determinism
import PR4Ownership
import PR4Package

/// Pre-flight checks before PR4 processing
public enum PreFlightChecks {
    
    public static func runAll() -> PreFlightResult {
        var errors: [String] = []
        var warnings: [String] = []
        
        if !RangeCompleteSoftmaxLUT.verifyIntegrity() {
            errors.append("LUT integrity check failed")
        }
        
        let platformResult = DeterminismDependencyContract.generateReport()
        if !platformResult.allPassed {
            for violation in platformResult.violations {
                errors.append("Platform dependency: \(violation)")
            }
        }
        
        ThreadingContract.initialize()
        
        let dagResult = PackageDAGProof.verifyAcyclic()
        if !dagResult {
            errors.append("Package DAG has cycles")
        }
        
        #if DETERMINISM_STRICT
        print("PR4: Running in STRICT mode")
        #else
        print("PR4: Running in FAST mode")
        warnings.append("Not running in STRICT mode - some checks disabled")
        #endif
        
        RuntimeInvariantMonitor.shared.registerPR4Invariants()
        
        return PreFlightResult(
            passed: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
    }
    
    public struct PreFlightResult {
        public let passed: Bool
        public let errors: [String]
        public let warnings: [String]
        
        public func printReport() {
            print("=== PR4 Pre-Flight Check Results ===")
            
            if passed {
                print("✅ All checks passed")
            } else {
                print("❌ Pre-flight checks FAILED")
            }
            
            if !errors.isEmpty {
                print("\nErrors:")
                for error in errors {
                    print("  ❌ \(error)")
                }
            }
            
            if !warnings.isEmpty {
                print("\nWarnings:")
                for warning in warnings {
                    print("  ⚠️ \(warning)")
                }
            }
            
            print("=====================================")
        }
    }
}
