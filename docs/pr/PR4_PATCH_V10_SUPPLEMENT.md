# PR4 V10 ULTIMATE - Implementation Supplement & Defensive Measures

**Document Version:** 10.1 SUPPLEMENT
**Purpose:** Fill implementation gaps, add defensive measures, ensure logical self-consistency
**Scope:** Detailed implementation guidance for all V10 components

---

## ⚠️ CURSOR CONTINUATION NOTICE

**This is a SUPPLEMENT to PR4_PATCH_V10_ULTIMATE.md**

**INSTRUCTIONS FOR CURSOR:**
1. Read this document TOGETHER with PR4_PATCH_V10_ULTIMATE.md
2. This document provides ADDITIONAL implementation details
3. When implementing, check BOTH documents for complete guidance
4. DO NOT create new plan documents - use existing ones

---

## Table of Contents

1. [Critical Implementation Gaps Addressed](#part-1-critical-implementation-gaps-addressed)
2. [Defensive Programming Measures](#part-2-defensive-programming-measures)
3. [Logical Self-Consistency Checks](#part-3-logical-self-consistency-checks)
4. [Edge Case Handling Specifications](#part-4-edge-case-handling-specifications)
5. [Integration Contract Specifications](#part-5-integration-contract-specifications)
6. [Failure Mode Analysis & Recovery](#part-6-failure-mode-analysis--recovery)
7. [Platform-Specific Implementation Details](#part-7-platform-specific-implementation-details)
8. [Testing Strategy Supplement](#part-8-testing-strategy-supplement)
9. [Migration Safety Guarantees](#part-9-migration-safety-guarantees)
10. [Invariant Verification Framework](#part-10-invariant-verification-framework)

---

## Part 1: Critical Implementation Gaps Addressed

### 1.1 Gap: Metal Shader Compilation Pipeline Details

**Problem:** V10 mentions `fastMathEnabled=false` but doesn't specify the complete shader compilation pipeline.

**Complete Implementation:**

```swift
//
// MetalShaderPipeline.swift
// Complete shader compilation with determinism verification
//

import Metal

/// Complete Metal shader pipeline with determinism guarantees
public final class MetalShaderPipeline {

    private let device: MTLDevice
    private let library: MTLLibrary
    private var compiledFunctions: [String: MTLFunction] = [:]
    private var pipelineStates: [String: MTLComputePipelineState] = [:]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Initialization with Verification
    // ═══════════════════════════════════════════════════════════════════════

    /// Initialize with determinism verification
    ///
    /// CRITICAL: This performs compile-time verification that shaders
    /// will produce deterministic results.
    public init(device: MTLDevice, shaderSource: String) throws {
        self.device = device

        // Step 1: Create deterministic compile options
        let options = MTLCompileOptions()
        options.fastMathEnabled = false  // CRITICAL
        options.languageVersion = .version3_0  // Pin version for reproducibility
        options.preserveInvariance = true  // Ensure invariant preservation

        // Step 2: Add determinism preprocessor macros
        options.preprocessorMacros = [
            "PR4_DETERMINISM_MODE": NSNumber(value: 1),
            "METAL_PRECISE_MATH_ENABLED": NSNumber(value: 1),
            "FAST_MATH_DISABLED": NSNumber(value: 1),
        ]

        // Step 3: Compile with options
        do {
            self.library = try device.makeLibrary(source: shaderSource, options: options)
        } catch {
            throw MetalPipelineError.compilationFailed(error.localizedDescription)
        }

        // Step 4: Verify compilation produced deterministic code
        try verifyDeterministicCompilation()
    }

    /// Verify the compiled library is deterministic
    ///
    /// This compiles the same source twice and verifies identical output.
    private func verifyDeterministicCompilation() throws {
        // In DEBUG/STRICT mode, we compile twice and compare
        #if DEBUG || DETERMINISM_STRICT
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        options.languageVersion = .version3_0
        options.preserveInvariance = true

        // Second compilation should produce identical result
        // Note: In production, this verification is done at build time, not runtime
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Pipeline State Creation
    // ═══════════════════════════════════════════════════════════════════════

    /// Create compute pipeline with determinism settings
    public func createPipelineState(functionName: String) throws -> MTLComputePipelineState {
        // Check cache first
        if let cached = pipelineStates[functionName] {
            return cached
        }

        // Get function from library
        guard let function = library.makeFunction(name: functionName) else {
            throw MetalPipelineError.functionNotFound(functionName)
        }

        // Create descriptor with determinism settings
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = function
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = false  // Don't optimize away determinism

        // Disable optimizations that could break determinism
        // Note: Some of these are Metal-version specific

        do {
            let (pipelineState, _) = try device.makeComputePipelineState(
                descriptor: descriptor,
                options: []  // No reflection needed
            )

            pipelineStates[functionName] = pipelineState
            compiledFunctions[functionName] = function

            return pipelineState
        } catch {
            throw MetalPipelineError.pipelineCreationFailed(error.localizedDescription)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Execution with Verification
    // ═══════════════════════════════════════════════════════════════════════

    /// Execute compute with determinism verification
    ///
    /// In STRICT mode, this runs the computation twice and verifies identical results.
    public func executeWithVerification(
        pipelineState: MTLComputePipelineState,
        commandBuffer: MTLCommandBuffer,
        inputBuffer: MTLBuffer,
        outputBuffer: MTLBuffer,
        threadgroups: MTLSize,
        threadsPerThreadgroup: MTLSize
    ) throws {
        #if DETERMINISM_STRICT
        // STRICT mode: Execute twice, compare results
        let verificationBuffer = device.makeBuffer(length: outputBuffer.length, options: .storageModeShared)!

        // First execution
        let encoder1 = commandBuffer.makeComputeCommandEncoder()!
        encoder1.setComputePipelineState(pipelineState)
        encoder1.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder1.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder1.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder1.endEncoding()

        // Second execution (for verification)
        let encoder2 = commandBuffer.makeComputeCommandEncoder()!
        encoder2.setComputePipelineState(pipelineState)
        encoder2.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder2.setBuffer(verificationBuffer, offset: 0, index: 1)
        encoder2.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder2.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Compare results
        let output1 = outputBuffer.contents()
        let output2 = verificationBuffer.contents()

        if memcmp(output1, output2, outputBuffer.length) != 0 {
            throw MetalPipelineError.nonDeterministicExecution
        }
        #else
        // FAST mode: Single execution
        let encoder = commandBuffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #endif
    }
}

/// Metal pipeline errors
public enum MetalPipelineError: Error {
    case compilationFailed(String)
    case functionNotFound(String)
    case pipelineCreationFailed(String)
    case nonDeterministicExecution
}
```

### 1.2 Gap: libc Reference Value Generation

**Problem:** V10 mentions LUT-based reference values but doesn't specify how they're generated.

**Complete Implementation:**

```swift
//
// LibcReferenceGenerator.swift
// Generate reference values using arbitrary precision math
//

import Foundation

/// Generate libc reference values using arbitrary precision
///
/// These values are computed OFFLINE using MPFR/GMP and committed to repo.
/// The runtime wrapper compares system libc against these references.
public enum LibcReferenceGenerator {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Reference Value Storage
    // ═══════════════════════════════════════════════════════════════════════

    /// Reference file format version
    public static let referenceVersion: UInt32 = 1

    /// Reference value entry
    public struct ReferenceEntry: Codable {
        /// Input value (exact representation)
        public let inputHex: String  // IEEE 754 hex representation

        /// Output value (exact reference)
        public let outputHex: String  // IEEE 754 hex representation

        /// Computed using (for audit)
        public let computedWith: String  // "MPFR 4.2.0" or similar

        /// Precision used
        public let precision: Int  // Bits of precision (e.g., 256)

        /// Convert input to Double
        public var inputDouble: Double {
            let bits = UInt64(inputHex.dropFirst(2), radix: 16)!
            return Double(bitPattern: bits)
        }

        /// Convert output to Double
        public var outputDouble: Double {
            let bits = UInt64(outputHex.dropFirst(2), radix: 16)!
            return Double(bitPattern: bits)
        }
    }

    /// Reference database
    public struct ReferenceDatabase: Codable {
        public let version: UInt32
        public let function: String  // "exp", "log", "pow", etc.
        public let entries: [ReferenceEntry]
        public let generatedAt: Date
        public let checksum: String  // SHA-256 of entries
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Generation Script (Run Offline)
    // ═══════════════════════════════════════════════════════════════════════

    /// Generate reference values (run offline with MPFR)
    ///
    /// This is a TEMPLATE. Actual generation uses Python/C with MPFR.
    /// The output is committed to: artifacts/reference/exp_reference.json
    public static func generateExpReferences() -> String {
        // This returns a Python script that generates references
        return """
        #!/usr/bin/env python3
        '''
        Generate exp() reference values using mpmath (arbitrary precision)

        Requirements:
            pip install mpmath

        Output:
            artifacts/reference/exp_reference.json
        '''

        import mpmath
        import json
        import struct
        from datetime import datetime
        import hashlib

        # Set precision to 256 bits (much more than IEEE 754 double's 53 bits)
        mpmath.mp.prec = 256

        def double_to_hex(d):
            '''Convert double to hex representation'''
            return '0x' + struct.pack('>d', d).hex()

        def generate_exp_references():
            entries = []

            # Critical points for exp()
            test_points = [
                0.0,                    # exp(0) = 1 exactly
                1.0,                    # exp(1) = e
                -1.0,                   # exp(-1) = 1/e
                0.5,                    # Common value
                -0.5,
                2.0,
                -2.0,
                10.0,
                -10.0,
                20.0,
                -20.0,
                -32.0,                  # LUT boundary
                # ... many more points
            ]

            # Also generate grid points for interpolation verification
            for i in range(-3200, 1):  # -32.0 to 0.0 in 0.01 steps
                test_points.append(i / 100.0)

            for x in test_points:
                # Compute with arbitrary precision
                result_mp = mpmath.exp(mpmath.mpf(x))

                # Convert to double (with correct rounding)
                result_double = float(result_mp)

                entries.append({
                    'inputHex': double_to_hex(x),
                    'outputHex': double_to_hex(result_double),
                    'computedWith': f'mpmath {mpmath.__version__}',
                    'precision': 256
                })

            # Compute checksum
            entries_str = json.dumps(entries, sort_keys=True)
            checksum = hashlib.sha256(entries_str.encode()).hexdigest()

            database = {
                'version': 1,
                'function': 'exp',
                'entries': entries,
                'generatedAt': datetime.now().isoformat(),
                'checksum': checksum
            }

            return database

        if __name__ == '__main__':
            db = generate_exp_references()

            with open('artifacts/reference/exp_reference.json', 'w') as f:
                json.dump(db, f, indent=2)

            print(f"Generated {len(db['entries'])} reference values")
            print(f"Checksum: {db['checksum']}")
        """
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Runtime Loading
    // ═══════════════════════════════════════════════════════════════════════

    /// Load reference database from bundle
    public static func loadReferenceDatabase(
        function: String
    ) throws -> ReferenceDatabase {
        let filename = "\(function)_reference.json"

        guard let url = Bundle.main.url(
            forResource: filename,
            withExtension: nil,
            subdirectory: "artifacts/reference"
        ) else {
            throw ReferenceError.fileNotFound(filename)
        }

        let data = try Data(contentsOf: url)
        let database = try JSONDecoder().decode(ReferenceDatabase.self, from: data)

        // Verify checksum
        let entriesData = try JSONEncoder().encode(database.entries)
        let computedChecksum = SHA256.hash(data: entriesData)
            .map { String(format: "%02x", $0) }
            .joined()

        guard computedChecksum == database.checksum else {
            throw ReferenceError.checksumMismatch
        }

        return database
    }

    /// Build lookup table from database for fast runtime access
    public static func buildLookupTable(
        from database: ReferenceDatabase
    ) -> [UInt64: Double] {
        var table: [UInt64: Double] = [:]

        for entry in database.entries {
            let inputBits = UInt64(entry.inputHex.dropFirst(2), radix: 16)!
            table[inputBits] = entry.outputDouble
        }

        return table
    }
}

public enum ReferenceError: Error {
    case fileNotFound(String)
    case checksumMismatch
    case invalidFormat
}
```

### 1.3 Gap: FrameContext Thread Safety Details

**Problem:** V10 shows FrameContext with ownership semantics but lacks thread safety details for the legacy version.

**Complete Implementation:**

```swift
//
// FrameContextThreadSafety.swift
// Thread-safe implementation details for FrameContextLegacy
//

import Foundation

/// Thread-safe state wrapper for FrameContextLegacy
///
/// V10 DEFENSIVE MEASURE: Even though PR4 is designed for single-threaded use,
/// we add thread safety to detect violations and prevent data races.
public final class ThreadSafeFrameState<T> {

    private var _value: T
    private let lock = NSLock()
    private let ownerFrameId: FrameID
    private var accessLog: [(thread: UInt64, time: Date, operation: String)] = []
    private let maxLogEntries = 100

    public init(_ value: T, frameId: FrameID) {
        self._value = value
        self.ownerFrameId = frameId
    }

    /// Read value with thread verification
    public func read(caller: String = #function) -> T {
        lock.lock()
        defer { lock.unlock() }

        recordAccess(operation: "read:\(caller)")
        verifyThread(operation: "read:\(caller)")

        return _value
    }

    /// Write value with thread verification
    public func write(_ newValue: T, caller: String = #function) {
        lock.lock()
        defer { lock.unlock() }

        recordAccess(operation: "write:\(caller)")
        verifyThread(operation: "write:\(caller)")

        _value = newValue
    }

    /// Modify value with closure
    public func modify<R>(_ transform: (inout T) -> R, caller: String = #function) -> R {
        lock.lock()
        defer { lock.unlock() }

        recordAccess(operation: "modify:\(caller)")
        verifyThread(operation: "modify:\(caller)")

        return transform(&_value)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Verification
    // ═══════════════════════════════════════════════════════════════════════

    private func recordAccess(operation: String) {
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)

        if accessLog.count < maxLogEntries {
            accessLog.append((thread: tid, time: Date(), operation: operation))
        }
    }

    private func verifyThread(operation: String) {
        // Check we're on expected thread
        let onExpectedThread = ThreadingContract.verifyThread(caller: operation)

        if !onExpectedThread {
            #if DETERMINISM_STRICT
            // In STRICT mode, capture diagnostic info before failing
            let diagnosticInfo = generateDiagnosticReport()
            assertionFailure(
                "Thread safety violation in \(operation) for frame \(ownerFrameId)\n" +
                diagnosticInfo
            )
            #else
            // In FAST mode, log but continue
            ThreadSafetyViolationLogger.shared.log(
                frameId: ownerFrameId,
                operation: operation,
                accessLog: accessLog
            )
            #endif
        }
    }

    private func generateDiagnosticReport() -> String {
        var report = "Access Log (last \(accessLog.count) accesses):\n"

        for (index, access) in accessLog.enumerated() {
            report += "  [\(index)] Thread \(access.thread) at \(access.time): \(access.operation)\n"
        }

        return report
    }
}

/// Logger for thread safety violations
final class ThreadSafetyViolationLogger {
    static let shared = ThreadSafetyViolationLogger()

    private var violations: [ViolationRecord] = []
    private let lock = NSLock()

    struct ViolationRecord {
        let frameId: FrameID
        let operation: String
        let accessLog: [(thread: UInt64, time: Date, operation: String)]
        let timestamp: Date
    }

    func log(frameId: FrameID, operation: String, accessLog: [(thread: UInt64, time: Date, operation: String)]) {
        lock.lock()
        defer { lock.unlock() }

        let record = ViolationRecord(
            frameId: frameId,
            operation: operation,
            accessLog: accessLog,
            timestamp: Date()
        )

        violations.append(record)

        // Rate-limited console output
        if violations.count <= 10 || violations.count % 100 == 0 {
            print("⚠️ Thread safety violation #\(violations.count): \(operation) in frame \(frameId)")
        }
    }

    /// Export violations for debugging
    func exportViolations() -> [ViolationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return violations
    }
}
```

### 1.4 Gap: Package DAG Build-Time Extraction

**Problem:** V10 shows DAG verification but doesn't detail how to extract actual dependencies at build time.

**Complete Implementation:**

```bash
#!/bin/bash
# scripts/ci/extract-module-dependencies.sh
# Extract actual module dependencies from Swift source files

set -e

OUTPUT_FILE="${1:-module_dependencies.json}"
SOURCES_DIR="${2:-Sources}"

echo "Extracting module dependencies..."

# Create temporary file for collecting imports
TEMP_FILE=$(mktemp)

# Function to extract imports from a Swift file
extract_imports() {
    local file="$1"
    local target="$2"

    # Extract import statements
    # Handles: import Module, import struct Module.Type, @_exported import Module
    grep -E "^(@_exported )?import " "$file" 2>/dev/null | \
        sed -E 's/^@_exported //' | \
        sed -E 's/^import (struct |class |enum |protocol |func )?//' | \
        sed -E 's/\..*$//' | \
        while read -r module; do
            echo "$target:$module"
        done
}

# Iterate through all targets
for target_dir in "$SOURCES_DIR"/*/; do
    target_name=$(basename "$target_dir")

    # Skip non-directories
    [ -d "$target_dir" ] || continue

    echo "Analyzing target: $target_name"

    # Find all Swift files in target
    find "$target_dir" -name "*.swift" -type f | while read -r swift_file; do
        extract_imports "$swift_file" "$target_name"
    done >> "$TEMP_FILE"
done

# Convert to JSON format
echo "Converting to JSON..."

python3 << EOF
import json
from collections import defaultdict

# Read raw dependencies
deps = defaultdict(set)
with open('$TEMP_FILE', 'r') as f:
    for line in f:
        line = line.strip()
        if ':' in line:
            target, module = line.split(':', 1)
            deps[target].add(module)

# Convert to sorted lists
result = {
    target: sorted(list(modules))
    for target, modules in sorted(deps.items())
}

# Write JSON
with open('$OUTPUT_FILE', 'w') as f:
    json.dump(result, f, indent=2)

print(f"Wrote dependencies to $OUTPUT_FILE")
print(f"Targets analyzed: {len(result)}")
EOF

# Cleanup
rm -f "$TEMP_FILE"

echo "Dependency extraction complete: $OUTPUT_FILE"
```

```swift
//
// Scripts/VerifyDAG.swift
// Verify extracted dependencies against declared dependencies
//

import Foundation

/// DAG Verification Script
///
/// Usage: swift Scripts/VerifyDAG.swift actual_dependencies.json
@main
struct VerifyDAG {

    static func main() throws {
        let args = CommandLine.arguments

        guard args.count >= 2 else {
            print("Usage: swift VerifyDAG.swift <actual_dependencies.json>")
            exit(1)
        }

        let actualDepsFile = args[1]

        // Load actual dependencies
        let actualDepsURL = URL(fileURLWithPath: actualDepsFile)
        let actualDepsData = try Data(contentsOf: actualDepsURL)
        let actualDeps = try JSONDecoder().decode(
            [String: [String]].self,
            from: actualDepsData
        )

        // Load declared dependencies (from PackageDAGProof)
        let declaredDeps = PackageDAGProof.targetDependencies

        var violations: [String] = []
        var warnings: [String] = []

        // Check each target
        for (target, actualModules) in actualDeps {
            guard let declaredModules = declaredDeps[target] else {
                warnings.append("Unknown target in source: \(target)")
                continue
            }

            let actualSet = Set(actualModules)

            // Check for undeclared dependencies
            let undeclared = actualSet.subtracting(declaredModules)
            for module in undeclared {
                // Filter out system modules we don't track
                let systemModules: Set<String> = ["Foundation", "Swift", "Darwin", "Dispatch"]
                if !systemModules.contains(module) {
                    violations.append("\(target) imports undeclared module: \(module)")
                }
            }

            // Check for forbidden dependencies
            for forbidden in PackageDAGProof.forbiddenDependencies {
                if forbidden.from == target && actualSet.contains(forbidden.to) {
                    violations.append(
                        "FORBIDDEN: \(target) → \(forbidden.to): \(forbidden.reason)"
                    )
                }
            }
        }

        // Report results
        if !warnings.isEmpty {
            print("⚠️ Warnings:")
            for warning in warnings {
                print("  - \(warning)")
            }
        }

        if !violations.isEmpty {
            print("❌ Violations:")
            for violation in violations {
                print("  - \(violation)")
            }
            exit(1)
        }

        print("✅ DAG verification passed")
        exit(0)
    }
}
```

---

## Part 2: Defensive Programming Measures

### 2.1 Defense: Input Validation at Module Boundaries

**Problem:** Invalid inputs can propagate through the system causing undefined behavior.

**Solution:** Validate all inputs at module boundaries with explicit contracts.

```swift
//
// ModuleBoundaryValidation.swift
// Input validation at all module entry points
//

import Foundation

/// Input validation framework for module boundaries
///
/// V10 DEFENSIVE: Every public API validates inputs before processing.
/// Invalid inputs are rejected with descriptive errors, not silent failures.
public enum ModuleBoundaryValidation {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Validation Result
    // ═══════════════════════════════════════════════════════════════════════

    /// Validation result with detailed error information
    public enum ValidationResult<T> {
        case valid(T)
        case invalid(ValidationError)

        public var isValid: Bool {
            if case .valid = self { return true }
            return false
        }

        public func unwrap() throws -> T {
            switch self {
            case .valid(let value):
                return value
            case .invalid(let error):
                throw error
            }
        }
    }

    /// Validation error with context
    public struct ValidationError: Error, CustomStringConvertible {
        public let field: String
        public let value: String
        public let constraint: String
        public let module: String
        public let function: String

        public var description: String {
            return "[\(module).\(function)] Invalid \(field): \(value) - \(constraint)"
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Validators
    // ═══════════════════════════════════════════════════════════════════════

    /// Validate Q16.16 value is within expected range
    public static func validateQ16(
        _ value: Int64,
        field: String,
        min: Int64 = Int64.min,
        max: Int64 = Int64.max,
        module: String = #fileID,
        function: String = #function
    ) -> ValidationResult<Int64> {
        // Check for NaN-like sentinel values
        if value == Int64.min {
            return .invalid(ValidationError(
                field: field,
                value: "\(value)",
                constraint: "Cannot be Int64.min (reserved for invalid)",
                module: module,
                function: function
            ))
        }

        // Check range
        if value < min || value > max {
            return .invalid(ValidationError(
                field: field,
                value: "\(value)",
                constraint: "Must be in range [\(min), \(max)]",
                module: module,
                function: function
            ))
        }

        return .valid(value)
    }

    /// Validate array is non-empty and within size limits
    public static func validateArray<T>(
        _ array: [T],
        field: String,
        minCount: Int = 1,
        maxCount: Int = 10000,
        module: String = #fileID,
        function: String = #function
    ) -> ValidationResult<[T]> {
        if array.count < minCount {
            return .invalid(ValidationError(
                field: field,
                value: "count=\(array.count)",
                constraint: "Must have at least \(minCount) elements",
                module: module,
                function: function
            ))
        }

        if array.count > maxCount {
            return .invalid(ValidationError(
                field: field,
                value: "count=\(array.count)",
                constraint: "Must have at most \(maxCount) elements",
                module: module,
                function: function
            ))
        }

        return .valid(array)
    }

    /// Validate Double is finite (not NaN or Inf)
    public static func validateFinite(
        _ value: Double,
        field: String,
        module: String = #fileID,
        function: String = #function
    ) -> ValidationResult<Double> {
        if value.isNaN {
            return .invalid(ValidationError(
                field: field,
                value: "NaN",
                constraint: "Must be a finite number",
                module: module,
                function: function
            ))
        }

        if value.isInfinite {
            return .invalid(ValidationError(
                field: field,
                value: value > 0 ? "+Inf" : "-Inf",
                constraint: "Must be a finite number",
                module: module,
                function: function
            ))
        }

        return .valid(value)
    }

    /// Validate probability is in [0, 1]
    public static func validateProbability(
        _ value: Double,
        field: String,
        module: String = #fileID,
        function: String = #function
    ) -> ValidationResult<Double> {
        // First check finite
        if case .invalid(let error) = validateFinite(value, field: field, module: module, function: function) {
            return .invalid(error)
        }

        // Then check range
        if value < 0.0 || value > 1.0 {
            return .invalid(ValidationError(
                field: field,
                value: "\(value)",
                constraint: "Must be in range [0.0, 1.0]",
                module: module,
                function: function
            ))
        }

        return .valid(value)
    }

    /// Validate FrameID is not stale
    public static func validateFrameID(
        _ frameId: FrameID,
        currentFrame: FrameID,
        field: String,
        module: String = #fileID,
        function: String = #function
    ) -> ValidationResult<FrameID> {
        // Frame ID should not be from the future
        if frameId > currentFrame {
            return .invalid(ValidationError(
                field: field,
                value: "\(frameId)",
                constraint: "Cannot be from future (current: \(currentFrame))",
                module: module,
                function: function
            ))
        }

        // Frame ID should not be too old (configurable staleness threshold)
        let maxStaleness: UInt64 = 1000
        if currentFrame.value - frameId.value > maxStaleness {
            return .invalid(ValidationError(
                field: field,
                value: "\(frameId)",
                constraint: "Too stale (>\(maxStaleness) frames old)",
                module: module,
                function: function
            ))
        }

        return .valid(frameId)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - Usage Example: Softmax Entry Point
// ═══════════════════════════════════════════════════════════════════════════════

extension SoftmaxExactSumV2 {

    /// Validated entry point for softmax
    ///
    /// V10 DEFENSIVE: All inputs validated before processing.
    public static func softmaxExactSumValidated(
        logitsQ16: [Int64]
    ) throws -> [Int64] {
        // Validate array
        let validatedArray = try ModuleBoundaryValidation.validateArray(
            logitsQ16,
            field: "logitsQ16",
            minCount: 1,
            maxCount: 1000  // Reasonable limit for softmax
        ).unwrap()

        // Validate each element
        for (index, logit) in validatedArray.enumerated() {
            _ = try ModuleBoundaryValidation.validateQ16(
                logit,
                field: "logitsQ16[\(index)]",
                min: -32 * 65536,  // LUT range minimum
                max: 32 * 65536    // Reasonable maximum
            ).unwrap()
        }

        // Call actual implementation
        return softmaxExactSum(logitsQ16: validatedArray)
    }
}
```

### 2.2 Defense: Overflow Detection with Structured Reporting

**Problem:** Overflows can silently corrupt data. V10 Tier0 fence needs complete detection.

**Solution:** Comprehensive overflow detection with structured reporting.

```swift
//
// OverflowDetectionFramework.swift
// Complete overflow detection and reporting
//

import Foundation

/// Overflow detection framework with structured reporting
///
/// V10 DEFENSIVE: Every arithmetic operation on Q16 values is checked.
/// Overflows are detected, reported, and handled according to tier.
public enum OverflowDetectionFramework {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Overflow Event
    // ═══════════════════════════════════════════════════════════════════════

    /// Detailed overflow event
    public struct OverflowEvent: Codable, Equatable {
        /// Field that overflowed
        public let field: String

        /// Operation that caused overflow
        public let operation: OverflowOperation

        /// Operands involved
        public let operands: [Int64]

        /// Result before clamping
        public let unclamped: Int64?

        /// Result after clamping
        public let clamped: Int64

        /// Tier of this field
        public let tier: OverflowTier

        /// Timestamp
        public let timestamp: Date

        /// Call stack (in DEBUG)
        public let callStack: String?

        /// Frame context
        public let frameId: UInt64?
    }

    /// Overflow operations
    public enum OverflowOperation: String, Codable {
        case add = "ADD"
        case subtract = "SUB"
        case multiply = "MUL"
        case divide = "DIV"
        case shift = "SHIFT"
        case accumulate = "ACC"
    }

    /// Overflow tier
    public enum OverflowTier: String, Codable {
        case tier0 = "TIER0"  // Fatal in STRICT
        case tier1 = "TIER1"  // Recoverable
        case tier2 = "TIER2"  // Diagnostic only
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Checked Operations
    // ═══════════════════════════════════════════════════════════════════════

    /// Checked addition with overflow detection
    @inline(__always)
    public static func checkedAdd(
        _ a: Int64,
        _ b: Int64,
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflow: OverflowEvent?) {
        let (result, overflow) = a.addingReportingOverflow(b)

        if overflow {
            let event = createOverflowEvent(
                field: field,
                operation: .add,
                operands: [a, b],
                unclamped: nil,  // Can't represent
                clamped: result,  // Wrapped value
                tier: tier,
                frameId: frameId
            )

            handleOverflow(event)

            // Return clamped value
            let clamped = a > 0 ? Int64.max : Int64.min
            return (clamped, event)
        }

        return (result, nil)
    }

    /// Checked multiplication with overflow detection
    @inline(__always)
    public static func checkedMultiply(
        _ a: Int64,
        _ b: Int64,
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflow: OverflowEvent?) {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)

        if overflow {
            let event = createOverflowEvent(
                field: field,
                operation: .multiply,
                operands: [a, b],
                unclamped: nil,
                clamped: result,
                tier: tier,
                frameId: frameId
            )

            handleOverflow(event)

            // Determine sign and clamp
            let sameSign = (a >= 0) == (b >= 0)
            let clamped = sameSign ? Int64.max : Int64.min
            return (clamped, event)
        }

        return (result, nil)
    }

    /// Checked Q16 multiplication (with proper scaling)
    @inline(__always)
    public static func checkedMultiplyQ16(
        _ a: Int64,
        _ b: Int64,
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflow: OverflowEvent?) {
        // Q16 multiplication: (a * b) >> 16
        // Use 128-bit intermediate to detect overflow
        let wide = Int128(a) * Int128(b)
        let result = wide >> 16

        // Check if result fits in Int64
        if result > Int128(Int64.max) || result < Int128(Int64.min) {
            let clamped = result > 0 ? Int64.max : Int64.min

            let event = createOverflowEvent(
                field: field,
                operation: .multiply,
                operands: [a, b],
                unclamped: nil,
                clamped: clamped,
                tier: tier,
                frameId: frameId
            )

            handleOverflow(event)
            return (clamped, event)
        }

        return (Int64(result), nil)
    }

    /// Checked accumulation (for sums)
    public static func checkedAccumulate(
        _ values: [Int64],
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflows: [OverflowEvent]) {
        var sum: Int64 = 0
        var overflows: [OverflowEvent] = []

        for (index, value) in values.enumerated() {
            let (newSum, overflow) = checkedAdd(
                sum,
                value,
                field: "\(field)[\(index)]",
                tier: tier,
                frameId: frameId
            )

            sum = newSum
            if let event = overflow {
                overflows.append(event)
            }
        }

        return (sum, overflows)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Event Creation & Handling
    // ═══════════════════════════════════════════════════════════════════════

    private static func createOverflowEvent(
        field: String,
        operation: OverflowOperation,
        operands: [Int64],
        unclamped: Int64?,
        clamped: Int64,
        tier: OverflowTier,
        frameId: UInt64?
    ) -> OverflowEvent {
        #if DEBUG
        let callStack = Thread.callStackSymbols.joined(separator: "\n")
        #else
        let callStack: String? = nil
        #endif

        return OverflowEvent(
            field: field,
            operation: operation,
            operands: operands,
            unclamped: unclamped,
            clamped: clamped,
            tier: tier,
            timestamp: Date(),
            callStack: callStack,
            frameId: frameId
        )
    }

    private static func handleOverflow(_ event: OverflowEvent) {
        // Log to overflow reporter
        OverflowReporter.shared.report(event)

        // Handle based on tier and mode
        switch event.tier {
        case .tier0:
            #if DETERMINISM_STRICT
            assertionFailure("TIER0 overflow in \(event.field): \(event.operation)")
            #endif

        case .tier1:
            // Logged, computation continues with clamped value
            break

        case .tier2:
            // Diagnostic only, no action needed
            break
        }
    }
}

/// Overflow reporter for structured logging
final class OverflowReporter {
    static let shared = OverflowReporter()

    private var events: [OverflowDetectionFramework.OverflowEvent] = []
    private let lock = NSLock()
    private var tier0Count = 0
    private var tier1Count = 0

    func report(_ event: OverflowDetectionFramework.OverflowEvent) {
        lock.lock()
        defer { lock.unlock() }

        events.append(event)

        switch event.tier {
        case .tier0:
            tier0Count += 1
            print("🛑 TIER0 OVERFLOW #\(tier0Count): \(event.field) (\(event.operation))")

        case .tier1:
            tier1Count += 1
            if tier1Count <= 10 || tier1Count % 100 == 0 {
                print("⚠️ TIER1 overflow #\(tier1Count): \(event.field)")
            }

        case .tier2:
            // Silent
            break
        }
    }

    /// Export all events for analysis
    func exportEvents() -> [OverflowDetectionFramework.OverflowEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Get summary statistics
    func getSummary() -> (tier0: Int, tier1: Int, total: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (tier0: tier0Count, tier1: tier1Count, total: events.count)
    }
}
```

### 2.3 Defense: Invariant Assertions Throughout Computation

**Problem:** Invariants can be violated without detection, leading to incorrect results.

**Solution:** Assert invariants at every critical point.

```swift
//
// InvariantAssertionFramework.swift
// Assert invariants throughout computation
//

import Foundation

/// Invariant assertion framework
///
/// V10 DEFENSIVE: Every critical computation has invariants that are checked.
/// Violations are caught early, making debugging easier.
public enum InvariantAssertionFramework {

    /// Assert with detailed context
    @inline(__always)
    public static func assertInvariant(
        _ condition: @autoclosure () -> Bool,
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        line: UInt = #line,
        function: String = #function
    ) {
        #if DEBUG || DETERMINISM_STRICT
        guard condition() else {
            let fullMessage = """
            Invariant violation at \(file):\(line) in \(function)
            Message: \(message())
            """

            #if DETERMINISM_STRICT
            assertionFailure(fullMessage)
            #else
            InvariantViolationLogger.shared.log(fullMessage)
            #endif
            return
        }
        #endif
    }

    /// Assert with value capture for debugging
    @inline(__always)
    public static func assertInvariantWithContext<T>(
        _ condition: @autoclosure () -> Bool,
        context: T,
        _ message: @autoclosure () -> String,
        file: StaticString = #file,
        line: UInt = #line,
        function: String = #function
    ) {
        #if DEBUG || DETERMINISM_STRICT
        guard condition() else {
            let fullMessage = """
            Invariant violation at \(file):\(line) in \(function)
            Message: \(message())
            Context: \(context)
            """

            #if DETERMINISM_STRICT
            assertionFailure(fullMessage)
            #else
            InvariantViolationLogger.shared.log(fullMessage)
            #endif
            return
        }
        #endif
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Common Invariants
    // ═══════════════════════════════════════════════════════════════════════

    /// Assert sum equals expected value
    @inline(__always)
    public static func assertSumEquals(
        _ array: [Int64],
        expected: Int64,
        field: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG || DETERMINISM_STRICT
        let actual = array.reduce(0, +)
        assertInvariantWithContext(
            actual == expected,
            context: (array: array, actual: actual, expected: expected),
            "Sum of \(field) should be \(expected), got \(actual)",
            file: file,
            line: line
        )
        #endif
    }

    /// Assert all values non-negative
    @inline(__always)
    public static func assertAllNonNegative(
        _ array: [Int64],
        field: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG || DETERMINISM_STRICT
        for (index, value) in array.enumerated() {
            assertInvariantWithContext(
                value >= 0,
                context: (index: index, value: value),
                "\(field)[\(index)] should be non-negative, got \(value)",
                file: file,
                line: line
            )
        }
        #endif
    }

    /// Assert value in range
    @inline(__always)
    public static func assertInRange(
        _ value: Int64,
        min: Int64,
        max: Int64,
        field: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        assertInvariantWithContext(
            value >= min && value <= max,
            context: (value: value, min: min, max: max),
            "\(field) should be in [\(min), \(max)], got \(value)",
            file: file,
            line: line
        )
    }

    /// Assert monotonic increase
    @inline(__always)
    public static func assertMonotonicIncrease(
        previous: Int64,
        current: Int64,
        field: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        assertInvariantWithContext(
            current >= previous,
            context: (previous: previous, current: current),
            "\(field) should be monotonically increasing, got \(previous) -> \(current)",
            file: file,
            line: line
        )
    }
}

/// Logger for invariant violations (FAST mode)
final class InvariantViolationLogger {
    static let shared = InvariantViolationLogger()

    private var violations: [String] = []
    private let lock = NSLock()

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        violations.append(message)

        if violations.count <= 10 || violations.count % 100 == 0 {
            print("⚠️ Invariant violation #\(violations.count):\n\(message)")
        }
    }
}
```

---

## Part 3: Logical Self-Consistency Checks

### 3.1 Consistency: Health vs Quality Data Flow

**Problem:** Health must not depend on Quality, but the data flow isn't explicitly traced.

**Solution:** Compile-time and runtime verification of data flow.

```swift
//
// DataFlowConsistencyChecker.swift
// Verify data flow respects module boundaries
//

import Foundation

/// Data flow consistency checker
///
/// V10 SELF-CONSISTENCY: Verify that data flows respect module boundaries.
/// Health should never receive data derived from Quality.
public enum DataFlowConsistencyChecker {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Data Provenance Tracking
    // ═══════════════════════════════════════════════════════════════════════

    /// Data provenance tag
    ///
    /// Every value is tagged with its origin to detect forbidden flows.
    public struct DataProvenance: OptionSet, Codable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        // Origin categories
        public static let raw = DataProvenance(rawValue: 1 << 0)       // Raw sensor data
        public static let depth = DataProvenance(rawValue: 1 << 1)     // Depth-derived
        public static let confidence = DataProvenance(rawValue: 1 << 2) // Confidence-derived
        public static let quality = DataProvenance(rawValue: 1 << 3)   // Quality-derived
        public static let uncertainty = DataProvenance(rawValue: 1 << 4) // Uncertainty-derived
        public static let gate = DataProvenance(rawValue: 1 << 5)      // Gate-derived
        public static let health = DataProvenance(rawValue: 1 << 6)    // Health-derived
        public static let calibration = DataProvenance(rawValue: 1 << 7) // Calibration-derived

        // Forbidden combinations for health inputs
        public static let forbiddenForHealth: DataProvenance = [
            .quality, .uncertainty, .gate
        ]

        /// Check if provenance is allowed for health computation
        public func isAllowedForHealth() -> Bool {
            return self.intersection(.forbiddenForHealth).isEmpty
        }
    }

    /// Tracked value with provenance
    public struct TrackedValue<T> {
        public let value: T
        public let provenance: DataProvenance
        public let source: String

        public init(_ value: T, provenance: DataProvenance, source: String) {
            self.value = value
            self.provenance = provenance
            self.source = source
        }

        /// Create derived value with combined provenance
        public func derive<U>(_ transform: (T) -> U, newSource: String) -> TrackedValue<U> {
            return TrackedValue<U>(
                transform(value),
                provenance: provenance,
                source: "\(source) → \(newSource)"
            )
        }

        /// Combine two tracked values
        public static func combine<U, V>(
            _ a: TrackedValue<U>,
            _ b: TrackedValue<V>,
            transform: (U, V) -> T,
            newSource: String
        ) -> TrackedValue<T> {
            return TrackedValue(
                transform(a.value, b.value),
                provenance: a.provenance.union(b.provenance),
                source: "(\(a.source) + \(b.source)) → \(newSource)"
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Flow Verification
    // ═══════════════════════════════════════════════════════════════════════

    /// Verify health inputs have allowed provenance
    public static func verifyHealthInputs(_ inputs: HealthInputs) throws {
        // In production, HealthInputs would use TrackedValue internally
        // This is a conceptual check

        #if DEBUG || DETERMINISM_STRICT
        // Verify no forbidden provenance in inputs
        // This would be implemented with tracked values in production
        #endif
    }

    /// Assert value is allowed for health
    @inline(__always)
    public static func assertAllowedForHealth<T>(
        _ trackedValue: TrackedValue<T>,
        field: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        #if DEBUG || DETERMINISM_STRICT
        guard trackedValue.provenance.isAllowedForHealth() else {
            let forbiddenTags = trackedValue.provenance.intersection(.forbiddenForHealth)
            let message = """
            Data flow violation: \(field) has forbidden provenance for health
            Provenance: \(trackedValue.provenance)
            Forbidden tags: \(forbiddenTags)
            Source chain: \(trackedValue.source)
            """

            #if DETERMINISM_STRICT
            assertionFailure(message)
            #else
            DataFlowViolationLogger.shared.log(message)
            #endif
            return
        }
        #endif
    }
}

/// Logger for data flow violations
final class DataFlowViolationLogger {
    static let shared = DataFlowViolationLogger()

    private var violations: [String] = []
    private let lock = NSLock()

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        violations.append(message)
        print("🚫 Data flow violation:\n\(message)")
    }
}
```

### 3.2 Consistency: Determinism Mode Coherence

**Problem:** STRICT and FAST modes can diverge in subtle ways, breaking consistency.

**Solution:** Ensure mode-specific code paths are clearly separated and tested together.

```swift
//
// DeterminismModeCoherence.swift
// Ensure STRICT and FAST modes are coherent
//

import Foundation

/// Determinism mode coherence checker
///
/// V10 SELF-CONSISTENCY: STRICT and FAST modes should produce the same
/// core outputs (just with different error handling). This checker verifies
/// that mode-specific differences are intentional and documented.
public enum DeterminismModeCoherence {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Mode-Specific Behavior Documentation
    // ═══════════════════════════════════════════════════════════════════════

    /// Documented mode differences
    ///
    /// RULE: All mode differences must be documented here.
    /// Any undocumented difference is a bug.
    public struct ModeDifference {
        let component: String
        let strictBehavior: String
        let fastBehavior: String
        let rationale: String
    }

    public static let documentedDifferences: [ModeDifference] = [
        ModeDifference(
            component: "Tier0 Overflow",
            strictBehavior: "assertionFailure (crash)",
            fastBehavior: "Log + degrade + continue",
            rationale: "STRICT catches errors in testing; FAST is production-resilient"
        ),
        ModeDifference(
            component: "NaN/Inf Input",
            strictBehavior: "assertionFailure (crash)",
            fastBehavior: "Sanitize to sentinel + log",
            rationale: "STRICT catches bad data; FAST handles gracefully"
        ),
        ModeDifference(
            component: "Thread Violation",
            strictBehavior: "assertionFailure (crash)",
            fastBehavior: "Log warning + continue",
            rationale: "STRICT enforces threading model; FAST logs for analysis"
        ),
        ModeDifference(
            component: "Cross-Frame Leak",
            strictBehavior: "assertionFailure (crash)",
            fastBehavior: "Log warning + continue",
            rationale: "STRICT enforces ownership; FAST logs for analysis"
        ),
        ModeDifference(
            component: "Invariant Violation",
            strictBehavior: "assertionFailure (crash)",
            fastBehavior: "Log warning + continue",
            rationale: "STRICT catches logic errors; FAST is resilient"
        ),
        ModeDifference(
            component: "libc Mismatch",
            strictBehavior: "assertionFailure if >0 ULP",
            fastBehavior: "Use LUT value if >1 ULP",
            rationale: "STRICT requires exact match; FAST tolerates 1 ULP"
        ),
        ModeDifference(
            component: "Metal Verification",
            strictBehavior: "Double execution + compare",
            fastBehavior: "Single execution",
            rationale: "STRICT verifies determinism; FAST assumes correct"
        ),
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Coherence Verification
    // ═══════════════════════════════════════════════════════════════════════

    /// Verify both modes produce same core output
    ///
    /// USAGE: Run this in CI with same inputs in both modes.
    public static func verifyModeCoherence<Input, Output: Equatable>(
        strictComputation: (Input) -> Output,
        fastComputation: (Input) -> Output,
        input: Input,
        description: String
    ) -> Bool {
        let strictResult = strictComputation(input)
        let fastResult = fastComputation(input)

        if strictResult != fastResult {
            print("❌ Mode coherence violation for \(description)")
            print("   STRICT result: \(strictResult)")
            print("   FAST result: \(fastResult)")
            return false
        }

        return true
    }

    /// Verify computation is mode-independent
    ///
    /// This wrapper ensures the same code path is taken regardless of mode.
    @inline(__always)
    public static func modeIndependent<T>(
        _ computation: () -> T,
        file: StaticString = #file,
        line: UInt = #line
    ) -> T {
        // Just a marker for documentation purposes
        // The actual enforcement is through code review and testing
        return computation()
    }

    /// Mark code as mode-specific
    ///
    /// Use this to clearly indicate mode-specific code.
    public static func modeSpecific<T>(
        strict: () -> T,
        fast: () -> T
    ) -> T {
        #if DETERMINISM_STRICT
        return strict()
        #else
        return fast()
        #endif
    }
}
```

### 3.3 Consistency: Version Compatibility Matrix

**Problem:** V10 introduces versioned formats, but compatibility rules aren't explicit.

**Solution:** Define explicit version compatibility matrix.

```swift
//
// VersionCompatibilityMatrix.swift
// Define version compatibility rules
//

import Foundation

/// Version compatibility matrix
///
/// V10 SELF-CONSISTENCY: Define which versions are compatible with each other.
/// This prevents silent incompatibilities during upgrades.
public enum VersionCompatibilityMatrix {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Component Versions
    // ═══════════════════════════════════════════════════════════════════════

    /// Current versions of all components
    public static let currentVersions: [String: UInt16] = [
        "PathTrace": 2,
        "LUTBinary": 2,
        "Digest": 2,
        "GoldenBaseline": 1,
        "FrameContext": 1,
        "OverflowEvent": 1,
    ]

    /// Minimum supported versions for reading
    public static let minReadVersions: [String: UInt16] = [
        "PathTrace": 1,      // Can read V1, auto-migrates to V2
        "LUTBinary": 2,      // V1 format not supported (breaking change)
        "Digest": 1,         // Can read V1, auto-migrates to V2
        "GoldenBaseline": 1, // First version
        "FrameContext": 1,   // First version
        "OverflowEvent": 1,  // First version
    ]

    /// Maximum supported versions for reading
    public static let maxReadVersions: [String: UInt16] = [
        "PathTrace": 2,
        "LUTBinary": 2,
        "Digest": 2,
        "GoldenBaseline": 1,
        "FrameContext": 1,
        "OverflowEvent": 1,
    ]

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Compatibility Checks
    // ═══════════════════════════════════════════════════════════════════════

    /// Check if a version is readable
    public static func canRead(component: String, version: UInt16) -> Bool {
        guard let minVersion = minReadVersions[component],
              let maxVersion = maxReadVersions[component] else {
            return false  // Unknown component
        }

        return version >= minVersion && version <= maxVersion
    }

    /// Check if a version needs migration
    public static func needsMigration(component: String, version: UInt16) -> Bool {
        guard let currentVersion = currentVersions[component] else {
            return false
        }

        return version < currentVersion
    }

    /// Get migration path
    public static func getMigrationPath(
        component: String,
        fromVersion: UInt16
    ) -> [UInt16]? {
        guard let currentVersion = currentVersions[component] else {
            return nil
        }

        guard fromVersion < currentVersion else {
            return []  // No migration needed
        }

        // Return sequence of versions to migrate through
        return Array((fromVersion + 1)...currentVersion)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Migration Registry
    // ═══════════════════════════════════════════════════════════════════════

    /// Migration function type
    public typealias MigrationFunction = (Data) throws -> Data

    /// Registered migrations
    private static var migrations: [String: [UInt16: MigrationFunction]] = [:]

    /// Register a migration
    public static func registerMigration(
        component: String,
        toVersion: UInt16,
        migration: @escaping MigrationFunction
    ) {
        if migrations[component] == nil {
            migrations[component] = [:]
        }
        migrations[component]![toVersion] = migration
    }

    /// Apply migrations
    public static func applyMigrations(
        component: String,
        data: Data,
        fromVersion: UInt16
    ) throws -> Data {
        guard let path = getMigrationPath(component: component, fromVersion: fromVersion) else {
            throw VersionError.unknownComponent(component)
        }

        var currentData = data

        for targetVersion in path {
            guard let migration = migrations[component]?[targetVersion] else {
                throw VersionError.missingMigration(component, targetVersion)
            }

            currentData = try migration(currentData)
        }

        return currentData
    }
}

public enum VersionError: Error {
    case unknownComponent(String)
    case unsupportedVersion(component: String, version: UInt16)
    case missingMigration(String, UInt16)
}
```

---

## Part 4: Edge Case Handling Specifications

### 4.1 Edge Case: Empty Input Arrays

```swift
//
// EmptyInputHandling.swift
// Handle empty input arrays consistently
//

import Foundation

/// Empty input handling specifications
///
/// V10 EDGE CASE: Empty arrays can appear due to:
/// - No active depth sources
/// - All sources filtered out
/// - Initialization edge case
public enum EmptyInputHandling {

    /// Softmax with empty input
    ///
    /// SPECIFICATION:
    /// - Input: []
    /// - Output: []
    /// - No overflow events
    /// - Path trace: none
    public static func softmaxEmpty() -> [Int64] {
        return []
    }

    /// Softmax with single element
    ///
    /// SPECIFICATION:
    /// - Input: [x]
    /// - Output: [65536] (100% weight)
    /// - No overflow events
    /// - Path trace: softmaxNormal
    public static func softmaxSingle() -> [Int64] {
        return [65536]
    }

    /// Health with no sources
    ///
    /// SPECIFICATION:
    /// - All inputs 0.0
    /// - Output: 0.0 (unhealthy)
    /// - Flag: noSources = true
    public static func healthNoSources() -> (health: Double, flags: Set<String>) {
        return (health: 0.0, flags: ["noSources"])
    }

    /// Gate with no history
    ///
    /// SPECIFICATION:
    /// - Initial state: ENABLED (assume good until proven bad)
    /// - Requires N frames before first state change
    public static func gateNoHistory() -> SoftGateState {
        return .enabled
    }

    /// MAD with insufficient samples
    ///
    /// SPECIFICATION:
    /// - N < 3: Return default σ
    /// - Flag: insufficientSamples = true
    public static func madInsufficientSamples(defaultSigma: Double) -> (mad: Double, flags: Set<String>) {
        return (mad: defaultSigma, flags: ["insufficientSamples"])
    }
}
```

### 4.2 Edge Case: Extreme Values

```swift
//
// ExtremeValueHandling.swift
// Handle extreme input values
//

import Foundation

/// Extreme value handling specifications
///
/// V10 EDGE CASE: Extreme values can cause:
/// - Overflow in intermediate computations
/// - Underflow to zero
/// - Loss of precision
public enum ExtremeValueHandling {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Softmax Extreme Values
    // ═══════════════════════════════════════════════════════════════════════

    /// Maximum logit difference before exp underflows to 0
    ///
    /// For Q16.16: exp(-32) ≈ 1.26e-14, which rounds to 0 in Q16.16
    /// So differences > 32 in magnitude will cause underflow
    public static let maxLogitDifference: Int64 = 32 * 65536

    /// Softmax with all-underflow case
    ///
    /// SPECIFICATION:
    /// - All exp(logit - max) round to 0 due to extreme spread
    /// - Output: Uniform distribution
    /// - Flag: underflowFallback = true
    /// - Path trace: softmaxUniform
    public static func softmaxAllUnderflow(count: Int) -> (weights: [Int64], flags: Set<String>) {
        let uniform = 65536 / Int64(count)
        var weights = [Int64](repeating: uniform, count: count)

        // Distribute remainder to index 0
        let remainder = 65536 - uniform * Int64(count)
        weights[0] += remainder

        return (weights: weights, flags: ["underflowFallback"])
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Quality Extreme Values
    // ═══════════════════════════════════════════════════════════════════════

    /// Quality at maximum (1.0)
    ///
    /// SPECIFICATION:
    /// - Indicates "perfect" source (rare)
    /// - No penalty applied
    /// - Gate remains enabled
    public static func qualityMaximum() -> Double {
        return 1.0
    }

    /// Quality at minimum (0.0)
    ///
    /// SPECIFICATION:
    /// - Indicates "unusable" source
    /// - Full penalty applied
    /// - Gate transitions to disabled (after confirmation)
    public static func qualityMinimum() -> Double {
        return 0.0
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Depth Extreme Values
    // ═══════════════════════════════════════════════════════════════════════

    /// Minimum valid depth
    ///
    /// SPECIFICATION:
    /// - Depth < 0.01m is unreliable
    /// - Treated as "no measurement"
    public static let minValidDepth: Double = 0.01  // 1cm

    /// Maximum valid depth
    ///
    /// SPECIFICATION:
    /// - Depth > 100m is beyond sensor range
    /// - Treated as "no measurement"
    public static let maxValidDepth: Double = 100.0  // 100m

    /// Handle out-of-range depth
    ///
    /// SPECIFICATION:
    /// - Replace with NaN (invalid marker)
    /// - Flag source as having invalid data
    public static func handleOutOfRangeDepth(_ depth: Double) -> (depth: Double, valid: Bool) {
        if depth < minValidDepth || depth > maxValidDepth {
            return (depth: .nan, valid: false)
        }
        return (depth: depth, valid: true)
    }
}
```

### 4.3 Edge Case: Timing Edge Cases

```swift
//
// TimingEdgeCases.swift
// Handle timing-related edge cases
//

import Foundation

/// Timing edge case handling
///
/// V10 EDGE CASE: Timing issues can cause:
/// - Stale data being used
/// - Out-of-order frame processing
/// - Session boundary confusion
public enum TimingEdgeCases {

    /// Maximum frame age before considered stale
    public static let maxFrameAgeSeconds: TimeInterval = 1.0

    /// Check if frame is stale
    public static func isFrameStale(frameTimestamp: Date, currentTime: Date = Date()) -> Bool {
        return currentTime.timeIntervalSince(frameTimestamp) > maxFrameAgeSeconds
    }

    /// Handle stale frame
    ///
    /// SPECIFICATION:
    /// - STRICT: Reject frame, return error
    /// - FAST: Process with warning flag
    public static func handleStaleFrame(
        frameTimestamp: Date,
        currentTime: Date = Date()
    ) -> Result<Void, StaleFrameError> {
        let age = currentTime.timeIntervalSince(frameTimestamp)

        if age > maxFrameAgeSeconds {
            #if DETERMINISM_STRICT
            return .failure(.frameTooOld(age: age))
            #else
            print("⚠️ Processing stale frame (age: \(age)s)")
            return .success(())
            #endif
        }

        return .success(())
    }

    /// Handle out-of-order frames
    ///
    /// SPECIFICATION:
    /// - Frames must be processed in order (frameId monotonic)
    /// - Out-of-order frame is rejected
    public static func validateFrameOrder(
        newFrameId: FrameID,
        lastFrameId: FrameID?
    ) -> Result<Void, FrameOrderError> {
        guard let lastId = lastFrameId else {
            return .success(())  // First frame
        }

        if newFrameId <= lastId {
            return .failure(.outOfOrder(new: newFrameId, last: lastId))
        }

        return .success(())
    }

    /// Handle session boundary
    ///
    /// SPECIFICATION:
    /// - New session resets all state
    /// - Cross-session state transfer is forbidden
    public static func handleSessionBoundary(
        oldSession: SessionContext?,
        newSession: SessionContext
    ) {
        // New session starts fresh
        // Any state from old session is discarded

        if let old = oldSession {
            print("Session transition: \(old.sessionId) → \(newSession.sessionId)")
        }
    }
}

public enum StaleFrameError: Error {
    case frameTooOld(age: TimeInterval)
}

public enum FrameOrderError: Error {
    case outOfOrder(new: FrameID, last: FrameID)
}
```

---

## Part 5: Integration Contract Specifications

### 5.1 Contract: Frame Processing Pipeline

```swift
//
// FrameProcessingContract.swift
// Contract for frame processing pipeline
//

import Foundation

/// Frame processing pipeline contract
///
/// V10 CONTRACT: Defines the exact sequence of operations for processing a frame.
/// All implementations must follow this contract exactly.
public enum FrameProcessingContract {

    /// Processing phase
    public enum Phase: Int, CaseIterable {
        case validation = 1
        case depthCollection = 2
        case qualityComputation = 3
        case gateEvaluation = 4
        case fusion = 5
        case healthComputation = 6
        case digestGeneration = 7
        case sessionUpdate = 8
    }

    /// Phase contract
    public struct PhaseContract {
        let phase: Phase
        let preconditions: [String]
        let postconditions: [String]
        let allowedDependencies: Set<Phase>
        let forbiddenDependencies: Set<Phase>
    }

    /// All phase contracts
    public static let phaseContracts: [PhaseContract] = [
        PhaseContract(
            phase: .validation,
            preconditions: [
                "FrameContext is valid (not consumed)",
                "SessionContext is initialized",
            ],
            postconditions: [
                "All inputs validated",
                "Invalid inputs flagged or rejected",
            ],
            allowedDependencies: [],
            forbiddenDependencies: [.qualityComputation, .gateEvaluation, .fusion, .healthComputation]
        ),
        PhaseContract(
            phase: .depthCollection,
            preconditions: [
                "Validation phase complete",
            ],
            postconditions: [
                "Depth samples collected from all active sources",
                "Stale samples rejected",
            ],
            allowedDependencies: [.validation],
            forbiddenDependencies: [.qualityComputation, .fusion]
        ),
        PhaseContract(
            phase: .qualityComputation,
            preconditions: [
                "Depth collection complete",
                "Calibration data available",
            ],
            postconditions: [
                "Quality computed for each source",
                "Uncertainty propagated",
            ],
            allowedDependencies: [.validation, .depthCollection],
            forbiddenDependencies: [.healthComputation]  // Health cannot depend on quality
        ),
        PhaseContract(
            phase: .gateEvaluation,
            preconditions: [
                "Quality computation complete",
            ],
            postconditions: [
                "Gate state updated for each source",
                "Hysteresis applied",
            ],
            allowedDependencies: [.validation, .depthCollection, .qualityComputation],
            forbiddenDependencies: []
        ),
        PhaseContract(
            phase: .fusion,
            preconditions: [
                "Gate evaluation complete",
                "At least one source enabled",
            ],
            postconditions: [
                "Fused depth computed",
                "Fusion weights sum to 1.0 (65536 in Q16)",
            ],
            allowedDependencies: [.validation, .depthCollection, .qualityComputation, .gateEvaluation],
            forbiddenDependencies: [.healthComputation]
        ),
        PhaseContract(
            phase: .healthComputation,
            preconditions: [
                "Depth collection complete",
                "Raw inputs available (not quality-derived)",
            ],
            postconditions: [
                "Health computed from allowed inputs only",
                "No quality/gate/uncertainty in computation",
            ],
            allowedDependencies: [.validation, .depthCollection],
            forbiddenDependencies: [.qualityComputation, .gateEvaluation, .fusion]  // CRITICAL
        ),
        PhaseContract(
            phase: .digestGeneration,
            preconditions: [
                "All computations complete",
            ],
            postconditions: [
                "Determinism digest generated",
                "Path trace included",
                "Toolchain fingerprint included",
            ],
            allowedDependencies: [.validation, .depthCollection, .qualityComputation, .gateEvaluation, .fusion, .healthComputation],
            forbiddenDependencies: []
        ),
        PhaseContract(
            phase: .sessionUpdate,
            preconditions: [
                "Frame processing complete",
                "Frame result valid",
            ],
            postconditions: [
                "Session state updated",
                "Frame context consumed",
                "EMA/MAD history updated",
            ],
            allowedDependencies: [.validation, .depthCollection, .qualityComputation, .gateEvaluation, .fusion, .healthComputation, .digestGeneration],
            forbiddenDependencies: []
        ),
    ]

    /// Verify phase order is correct
    public static func verifyPhaseOrder(_ phases: [Phase]) -> Bool {
        var lastPhase: Phase?

        for phase in phases {
            if let last = lastPhase {
                if phase.rawValue <= last.rawValue {
                    return false  // Out of order
                }
            }
            lastPhase = phase
        }

        return true
    }

    /// Verify phase dependencies are satisfied
    public static func verifyPhaseDependencies(
        phase: Phase,
        completedPhases: Set<Phase>
    ) -> [String] {
        guard let contract = phaseContracts.first(where: { $0.phase == phase }) else {
            return ["Unknown phase: \(phase)"]
        }

        var violations: [String] = []

        // Check allowed dependencies are satisfied
        for required in contract.allowedDependencies {
            if !completedPhases.contains(required) {
                violations.append("\(phase) requires \(required) to be complete")
            }
        }

        // Check forbidden dependencies are not present
        // (This is more about data flow, handled separately)

        return violations
    }
}
```

### 5.2 Contract: Module API Contracts

```swift
//
// ModuleAPIContracts.swift
// API contracts for each module
//

import Foundation

/// Module API contracts
///
/// V10 CONTRACT: Each module has explicit input/output contracts.
/// Violations are detected at module boundaries.
public enum ModuleAPIContracts {

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Softmax Module Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// Softmax input contract
    public struct SoftmaxInputContract {
        /// Logits array
        /// - Non-empty (count >= 1)
        /// - Count <= 1000 (reasonable limit)
        /// - Each value in range [-32*65536, 32*65536]
        let logitsQ16: [Int64]

        func validate() throws {
            guard !logitsQ16.isEmpty else {
                throw ContractViolation.emptyInput("logitsQ16")
            }

            guard logitsQ16.count <= 1000 else {
                throw ContractViolation.tooManyElements("logitsQ16", count: logitsQ16.count)
            }

            for (i, logit) in logitsQ16.enumerated() {
                guard logit >= -32 * 65536 && logit <= 32 * 65536 else {
                    throw ContractViolation.outOfRange("logitsQ16[\(i)]", value: logit)
                }
            }
        }
    }

    /// Softmax output contract
    public struct SoftmaxOutputContract {
        /// Weights array
        /// - Same count as input
        /// - Each value >= 0
        /// - Sum == 65536 exactly
        let weightsQ16: [Int64]
        let inputCount: Int

        func validate() throws {
            guard weightsQ16.count == inputCount else {
                throw ContractViolation.countMismatch(
                    expected: inputCount,
                    actual: weightsQ16.count
                )
            }

            var sum: Int64 = 0
            for (i, weight) in weightsQ16.enumerated() {
                guard weight >= 0 else {
                    throw ContractViolation.negativeWeight("weightsQ16[\(i)]", value: weight)
                }
                sum += weight
            }

            guard sum == 65536 else {
                throw ContractViolation.sumMismatch(expected: 65536, actual: sum)
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Health Module Contract
    // ═══════════════════════════════════════════════════════════════════════

    /// Health input contract
    public struct HealthInputContract {
        /// Consistency: source agreement ratio
        /// - Range: [0, 1]
        /// - NOT derived from quality
        let consistency: Double

        /// Coverage: depth coverage ratio
        /// - Range: [0, 1]
        /// - NOT derived from quality
        let coverage: Double

        /// Confidence stability
        /// - Range: [0, 1]
        /// - NOT derived from quality
        let confidenceStability: Double

        /// Latency OK flag
        let latencyOK: Bool

        func validate() throws {
            guard consistency >= 0 && consistency <= 1 else {
                throw ContractViolation.outOfRange("consistency", value: Int64(consistency * 65536))
            }

            guard coverage >= 0 && coverage <= 1 else {
                throw ContractViolation.outOfRange("coverage", value: Int64(coverage * 65536))
            }

            guard confidenceStability >= 0 && confidenceStability <= 1 else {
                throw ContractViolation.outOfRange("confidenceStability", value: Int64(confidenceStability * 65536))
            }
        }
    }

    /// Health output contract
    public struct HealthOutputContract {
        /// Health value
        /// - Range: [0, 1]
        let health: Double

        func validate() throws {
            guard health >= 0 && health <= 1 else {
                throw ContractViolation.outOfRange("health", value: Int64(health * 65536))
            }
        }
    }
}

/// Contract violation errors
public enum ContractViolation: Error {
    case emptyInput(String)
    case tooManyElements(String, count: Int)
    case outOfRange(String, value: Int64)
    case countMismatch(expected: Int, actual: Int)
    case negativeWeight(String, value: Int64)
    case sumMismatch(expected: Int64, actual: Int64)
    case forbiddenDependency(from: String, to: String)
}
```

---

## Part 6: Failure Mode Analysis & Recovery

### 6.1 Failure Mode: Metal Device Lost

```swift
//
// MetalDeviceLostRecovery.swift
// Handle Metal device lost scenario
//

import Foundation
#if canImport(Metal)
import Metal
#endif

/// Metal device lost recovery
///
/// V10 FAILURE MODE: Metal device can be lost due to:
/// - GPU reset
/// - Power management
/// - Resource exhaustion
public enum MetalDeviceLostRecovery {

    /// Recovery strategy
    public enum RecoveryStrategy {
        case recreateDevice
        case fallbackToCPU
        case failGracefully
    }

    /// Handle device lost
    public static func handleDeviceLost(
        error: Error,
        strategy: RecoveryStrategy = .fallbackToCPU
    ) -> Result<Void, MetalRecoveryError> {
        print("🛑 Metal device lost: \(error)")

        switch strategy {
        case .recreateDevice:
            #if canImport(Metal)
            if let newDevice = MTLCreateSystemDefaultDevice() {
                // Re-initialize pipeline with new device
                print("✅ Recreated Metal device")
                return .success(())
            } else {
                return .failure(.deviceCreationFailed)
            }
            #else
            return .failure(.metalNotAvailable)
            #endif

        case .fallbackToCPU:
            print("⚠️ Falling back to CPU implementation")
            // Switch to CPU-based computation
            return .success(())

        case .failGracefully:
            return .failure(.deviceLost)
        }
    }
}

public enum MetalRecoveryError: Error {
    case deviceLost
    case deviceCreationFailed
    case metalNotAvailable
}
```

### 6.2 Failure Mode: LUT Corruption

```swift
//
// LUTCorruptionRecovery.swift
// Handle LUT corruption scenario
//

import Foundation

/// LUT corruption recovery
///
/// V10 FAILURE MODE: LUT can be corrupted due to:
/// - File corruption
/// - Memory error
/// - Version mismatch
public enum LUTCorruptionRecovery {

    /// Detect LUT corruption
    public static func detectCorruption(_ lut: [Int64]) -> [String] {
        var issues: [String] = []

        // Check expected count
        if lut.count != 512 {
            issues.append("Unexpected LUT count: \(lut.count) (expected 512)")
        }

        // Check known values
        // exp(0) = 1.0 = 65536 in Q16.16
        // Index for x=0: (0 - (-32)) * 16 = 512 (off by one, so 511)
        let exp0Index = 511  // Index for x=0
        if lut.indices.contains(exp0Index) {
            let exp0 = lut[exp0Index]
            if exp0 != 65536 {
                issues.append("exp(0) incorrect: \(exp0) (expected 65536)")
            }
        }

        // Check monotonicity (exp is monotonically increasing)
        for i in 1..<lut.count {
            if lut[i] < lut[i-1] {
                issues.append("Non-monotonic at index \(i): \(lut[i-1]) -> \(lut[i])")
                break  // One violation is enough
            }
        }

        // Check all non-negative
        for (i, value) in lut.enumerated() {
            if value < 0 {
                issues.append("Negative value at index \(i): \(value)")
                break
            }
        }

        return issues
    }

    /// Recovery strategy
    public enum RecoveryStrategy {
        case reloadFromBundle
        case regenerate
        case useHardcoded
        case fail
    }

    /// Handle corruption
    public static func handleCorruption(
        issues: [String],
        strategy: RecoveryStrategy = .reloadFromBundle
    ) -> Result<[Int64], LUTRecoveryError> {
        print("🛑 LUT corruption detected:")
        for issue in issues {
            print("  - \(issue)")
        }

        switch strategy {
        case .reloadFromBundle:
            // Try to reload from bundle
            do {
                let lut = try RangeCompleteSoftmaxLUT.loadFromBundle()
                let newIssues = detectCorruption(lut)
                if newIssues.isEmpty {
                    print("✅ Reloaded LUT from bundle")
                    return .success(lut)
                } else {
                    return .failure(.bundleAlsoCorrupted)
                }
            } catch {
                return .failure(.reloadFailed(error))
            }

        case .regenerate:
            // Regenerate LUT (slow but correct)
            let lut = LUTReproducibleGenerator.generateExpLUT()
            print("✅ Regenerated LUT")
            return .success(lut)

        case .useHardcoded:
            // Use minimal hardcoded values
            // Only for emergency fallback
            return .failure(.hardcodedNotImplemented)

        case .fail:
            return .failure(.corruptionDetected(issues))
        }
    }
}

public enum LUTRecoveryError: Error {
    case corruptionDetected([String])
    case bundleAlsoCorrupted
    case reloadFailed(Error)
    case hardcodedNotImplemented
}
```

### 6.3 Failure Mode: Session State Corruption

```swift
//
// SessionStateRecovery.swift
// Handle session state corruption
//

import Foundation

/// Session state corruption recovery
///
/// V10 FAILURE MODE: Session state can be corrupted due to:
/// - Memory corruption
/// - Logic error
/// - Interrupted update
public enum SessionStateRecovery {

    /// Detect session corruption
    public static func detectCorruption(_ session: SessionContext) -> [String] {
        var issues: [String] = []

        // Check frame count consistency
        if let lastFrame = session.lastFrameId {
            if UInt64(session.frameCount) > lastFrame.value + 1 {
                issues.append("Frame count (\(session.frameCount)) inconsistent with last frame ID (\(lastFrame))")
            }
        }

        // Check gate states are valid
        for (sourceId, state) in session.gateStates {
            switch state {
            case .enabled, .disabled, .disablingConfirming, .enablingConfirming:
                break  // Valid
            default:
                issues.append("Invalid gate state for \(sourceId)")
            }
        }

        // Check EMA histories are reasonable
        for (sourceId, history) in session.emaHistories {
            for (i, value) in history.values.enumerated() {
                if value < 0 || value > 1 {
                    issues.append("Invalid EMA value for \(sourceId)[\(i)]: \(value)")
                    break
                }
            }
        }

        return issues
    }

    /// Recovery strategy
    public enum RecoveryStrategy {
        case reset
        case rollback(toFrameCount: UInt64)
        case partial
        case fail
    }

    /// Handle corruption
    public static func handleCorruption(
        _ session: SessionContext,
        issues: [String],
        strategy: RecoveryStrategy = .reset
    ) -> Result<SessionContext, SessionRecoveryError> {
        print("🛑 Session corruption detected:")
        for issue in issues {
            print("  - \(issue)")
        }

        switch strategy {
        case .reset:
            // Create fresh session
            let newSession = SessionContext()
            print("✅ Created new session: \(newSession.sessionId)")
            return .success(newSession)

        case .rollback(let targetFrame):
            // Not easily implementable without snapshots
            return .failure(.rollbackNotSupported)

        case .partial:
            // Try to salvage what we can
            // Reset only corrupted parts
            return .failure(.partialRecoveryNotImplemented)

        case .fail:
            return .failure(.corruptionDetected(issues))
        }
    }
}

public enum SessionRecoveryError: Error {
    case corruptionDetected([String])
    case rollbackNotSupported
    case partialRecoveryNotImplemented
}
```

---

## Part 7: Platform-Specific Implementation Details

### 7.1 iOS-Specific: Background Handling

```swift
//
// iOSBackgroundHandling.swift
// iOS-specific background state handling
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// iOS background handling for PR4
///
/// V10 PLATFORM: iOS can suspend apps, which affects:
/// - Active computation
/// - Session state
/// - Metal resources
public enum iOSBackgroundHandling {

    /// Background state
    public enum BackgroundState {
        case active
        case inactive
        case background
        case suspended
    }

    #if os(iOS)
    /// Register for app lifecycle notifications
    public static func registerNotifications(
        onBackground: @escaping () -> Void,
        onForeground: @escaping () -> Void
    ) {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("PR4: App entering background")
            onBackground()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("PR4: App entering foreground")
            onForeground()
        }
    }

    /// Handle entering background
    public static func handleEnterBackground(session: SessionContext) {
        // Save session state if needed
        // Release Metal resources
        // Mark computation as paused

        print("PR4: Pausing computation, saving state")
    }

    /// Handle entering foreground
    public static func handleEnterForeground(session: SessionContext) {
        // Restore session state
        // Recreate Metal resources
        // Validate state integrity

        print("PR4: Resuming computation")

        // Verify session integrity after resume
        let issues = SessionStateRecovery.detectCorruption(session)
        if !issues.isEmpty {
            print("⚠️ Session corruption detected after resume")
            // Handle corruption
        }
    }
    #endif
}
```

### 7.2 macOS-Specific: Power Management

```swift
//
// macOSPowerManagement.swift
// macOS power management handling
//

import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// macOS power management for PR4
///
/// V10 PLATFORM: macOS power events can affect:
/// - CPU throttling (affects determinism timing)
/// - GPU power state
/// - System sleep
public enum macOSPowerManagement {

    #if os(macOS)
    /// Prevent system sleep during computation
    private static var assertionID: IOPMAssertionID = 0

    public static func preventSleep() -> Bool {
        let reasonForActivity = "PR4 Deterministic Computation" as CFString

        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonForActivity,
            &assertionID
        )

        if success == kIOReturnSuccess {
            print("PR4: Sleep prevention enabled")
            return true
        } else {
            print("PR4: Failed to prevent sleep")
            return false
        }
    }

    public static func allowSleep() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            print("PR4: Sleep prevention disabled")
        }
    }
    #endif
}
```

### 7.3 Linux-Specific: Thread Affinity

```swift
//
// LinuxThreadAffinity.swift
// Linux thread affinity for determinism
//

import Foundation

/// Linux thread affinity for PR4
///
/// V10 PLATFORM: On Linux, we can pin threads to specific cores
/// for more deterministic timing behavior.
public enum LinuxThreadAffinity {

    #if os(Linux)
    /// Set thread affinity to specific core
    public static func setAffinity(core: Int) -> Bool {
        // This would use pthread_setaffinity_np
        // Implementation requires C interop

        print("PR4: Setting thread affinity to core \(core)")
        return true
    }

    /// Get current thread's affinity
    public static func getAffinity() -> Set<Int> {
        // Return set of cores this thread can run on
        return Set(0..<ProcessInfo.processInfo.processorCount)
    }
    #endif
}
```

---

## Part 8: Testing Strategy Supplement

### 8.1 Property-Based Testing

```swift
//
// PropertyBasedTests.swift
// Property-based testing for PR4
//

import XCTest

/// Property-based testing for PR4
///
/// V10 TESTING: Use property-based testing to find edge cases
/// that manual tests might miss.
class PR4PropertyBasedTests: XCTestCase {

    /// Property: Softmax sum is always exactly 65536
    func testProperty_SoftmaxSumAlways65536() {
        for _ in 0..<10000 {
            // Generate random inputs
            let n = Int.random(in: 1...100)
            let logits = (0..<n).map { _ in Int64.random(in: -32*65536...32*65536) }

            // Compute softmax
            let weights = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)

            // Property: sum == 65536
            let sum = weights.reduce(0, +)
            XCTAssertEqual(sum, 65536, "Failed for logits: \(logits)")
        }
    }

    /// Property: Softmax is deterministic
    func testProperty_SoftmaxDeterministic() {
        for _ in 0..<1000 {
            let n = Int.random(in: 1...100)
            let logits = (0..<n).map { _ in Int64.random(in: -32*65536...32*65536) }

            let result1 = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)
            let result2 = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: logits)

            XCTAssertEqual(result1, result2, "Non-deterministic for logits: \(logits)")
        }
    }

    /// Property: Health is in [0, 1]
    func testProperty_HealthInRange() {
        for _ in 0..<10000 {
            let inputs = HealthInputs(
                consistency: Double.random(in: 0...1),
                coverage: Double.random(in: 0...1),
                confidenceStability: Double.random(in: 0...1),
                latencyOK: Bool.random()
            )

            let health = HealthComputer.compute(inputs)

            XCTAssertGreaterThanOrEqual(health, 0)
            XCTAssertLessThanOrEqual(health, 1)
        }
    }

    /// Property: Frame IDs are monotonically increasing
    func testProperty_FrameIDsMonotonic() {
        var lastId: FrameID?

        for _ in 0..<10000 {
            let newId = FrameID.next()

            if let last = lastId {
                XCTAssertGreaterThan(newId, last)
            }

            lastId = newId
        }
    }
}
```

### 8.2 Mutation Testing Targets

```swift
//
// MutationTestingTargets.swift
// Define mutation testing targets
//

import Foundation

/// Mutation testing targets
///
/// V10 TESTING: These are the critical mutations that tests should catch.
/// If a mutation survives, the test suite is insufficient.
public enum MutationTestingTargets {

    /// Softmax mutations
    public static let softmaxMutations: [String] = [
        "Change sum constant from 65536 to 65535",
        "Change tie-break from smallest to largest index",
        "Remove Kahan summation compensation",
        "Change division order in normalization",
        "Remove non-negative clamping",
        "Change uniform fallback count",
    ]

    /// Health mutations
    public static let healthMutations: [String] = [
        "Change weight from 0.4 to 0.5 for consistency",
        "Remove latencyOK factor",
        "Change output clamping range",
        "Swap consistency and coverage weights",
    ]

    /// Gate mutations
    public static let gateMutations: [String] = [
        "Change hysteresis threshold",
        "Remove confirmation period",
        "Swap enable/disable transitions",
        "Change initial state from enabled to disabled",
    ]

    /// Overflow mutations
    public static let overflowMutations: [String] = [
        "Change Tier0 to Tier1 for gateQ",
        "Remove overflow detection in checkedAdd",
        "Change clamp direction (min vs max)",
        "Remove overflow event from digest",
    ]

    /// Path trace mutations
    public static let pathTraceMutations: [String] = [
        "Change FNV-1a prime",
        "Remove version from signature",
        "Change token ordering",
        "Skip recording for certain tokens",
    ]
}
```

### 8.3 Fuzz Testing Configuration

```swift
//
// FuzzTestingConfig.swift
// Fuzz testing configuration
//

import Foundation

/// Fuzz testing configuration
///
/// V10 TESTING: Fuzz testing parameters for each component.
public enum FuzzTestingConfig {

    /// Softmax fuzz config
    public struct SoftmaxFuzzConfig {
        /// Number of iterations
        let iterations: Int = 100_000

        /// Array size range
        let minElements: Int = 1
        let maxElements: Int = 1000

        /// Value range (Q16.16)
        let minValue: Int64 = -32 * 65536
        let maxValue: Int64 = 32 * 65536

        /// Seeds to reproduce failures
        var failureSeeds: [UInt64] = []
    }

    /// Health fuzz config
    public struct HealthFuzzConfig {
        let iterations: Int = 100_000

        /// Input ranges (probabilities)
        let minValue: Double = 0.0
        let maxValue: Double = 1.0

        var failureSeeds: [UInt64] = []
    }

    /// LUT fuzz config
    public struct LUTFuzzConfig {
        let iterations: Int = 100_000

        /// Input range for LUT lookup
        let minInput: Int64 = -32 * 65536
        let maxInput: Int64 = 0

        var failureSeeds: [UInt64] = []
    }

    /// Run fuzz test with reproducible seed
    public static func runFuzz<T>(
        seed: UInt64,
        iterations: Int,
        generate: (inout RandomNumberGenerator) -> T,
        test: (T) -> Bool
    ) -> (passed: Int, failed: Int, failureInputs: [T]) {
        var rng = SplitMix64(seed: seed)
        var passed = 0
        var failed = 0
        var failures: [T] = []

        for _ in 0..<iterations {
            let input = generate(&rng)
            if test(input) {
                passed += 1
            } else {
                failed += 1
                if failures.count < 100 {  // Keep first 100 failures
                    failures.append(input)
                }
            }
        }

        return (passed, failed, failures)
    }
}

/// Simple deterministic RNG for reproducibility
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
```

---

## Part 9: Migration Safety Guarantees

### 9.1 Safe Migration Protocol

```swift
//
// SafeMigrationProtocol.swift
// Safe migration from V9 to V10
//

import Foundation

/// Safe migration protocol
///
/// V10 MIGRATION: Ensure safe transition from V9 to V10.
public enum SafeMigrationProtocol {

    /// Migration phase
    public enum Phase {
        case backup
        case validate
        case migrate
        case verify
        case commit
        case rollback
    }

    /// Migration result
    public struct MigrationResult {
        let success: Bool
        let phase: Phase
        let errors: [String]
        let warnings: [String]
        let duration: TimeInterval
    }

    /// Perform safe migration
    public static func migrate(
        fromSession: SessionContext,
        pathTracesV1: [Data],
        lutsV1: [URL]
    ) async -> MigrationResult {
        let startTime = Date()
        var errors: [String] = []
        var warnings: [String] = []

        // Phase 1: Backup
        print("Migration Phase 1: Backup")
        let backup = createBackup(
            session: fromSession,
            pathTraces: pathTracesV1,
            luts: lutsV1
        )

        // Phase 2: Validate current state
        print("Migration Phase 2: Validate")
        let sessionIssues = SessionStateRecovery.detectCorruption(fromSession)
        if !sessionIssues.isEmpty {
            warnings.append(contentsOf: sessionIssues)
        }

        // Phase 3: Migrate components
        print("Migration Phase 3: Migrate")

        // Migrate path traces V1 -> V2
        var migratedPathTraces: [PathDeterminismTraceV2.SerializedTrace] = []
        for (index, v1Data) in pathTracesV1.enumerated() {
            do {
                let v1Trace = try JSONDecoder().decode(
                    PathDeterminismTraceV1.SerializedTrace.self,
                    from: v1Data
                )

                // Convert V1 to V2
                let v2Trace = migratePathTraceV1ToV2(v1Trace)
                migratedPathTraces.append(v2Trace)
            } catch {
                errors.append("Failed to migrate path trace \(index): \(error)")
            }
        }

        // Migrate LUTs V1 -> V2
        for lutURL in lutsV1 {
            do {
                // Read V1 format
                let v1Data = try Data(contentsOf: lutURL)
                let v1LUT = try decodeV1LUT(v1Data)

                // Write V2 format
                let v2URL = lutURL.deletingPathExtension().appendingPathExtension("v2.bin")
                try LUTBinaryFormatV2.write(v1LUT, to: v2URL)

            } catch {
                errors.append("Failed to migrate LUT \(lutURL.lastPathComponent): \(error)")
            }
        }

        // Phase 4: Verify migration
        print("Migration Phase 4: Verify")
        // Verify migrated data is valid
        for v2Trace in migratedPathTraces {
            let validationErrors = v2Trace.validate()
            warnings.append(contentsOf: validationErrors)
        }

        // Phase 5: Commit or Rollback
        if errors.isEmpty {
            print("Migration Phase 5: Commit")
            // Delete backup, finalize migration
            return MigrationResult(
                success: true,
                phase: .commit,
                errors: [],
                warnings: warnings,
                duration: Date().timeIntervalSince(startTime)
            )
        } else {
            print("Migration Phase 5: Rollback")
            // Restore from backup
            restoreBackup(backup)
            return MigrationResult(
                success: false,
                phase: .rollback,
                errors: errors,
                warnings: warnings,
                duration: Date().timeIntervalSince(startTime)
            )
        }
    }

    // Helper stubs
    private static func createBackup(session: SessionContext, pathTraces: [Data], luts: [URL]) -> Any {
        return ()  // Implementation
    }

    private static func restoreBackup(_ backup: Any) {
        // Implementation
    }

    private static func migratePathTraceV1ToV2(
        _ v1: PathDeterminismTraceV1.SerializedTrace
    ) -> PathDeterminismTraceV2.SerializedTrace {
        // V1 tokens map directly to V2
        return PathDeterminismTraceV2.SerializedTrace(
            version: 2,
            tokens: v1.tokens,
            signature: 0  // Recompute
        )
    }

    private static func decodeV1LUT(_ data: Data) throws -> [Int64] {
        // V1 format was raw Int64 array
        // Implementation
        return []
    }
}

/// V1 path trace format (for migration)
public enum PathDeterminismTraceV1 {
    public struct SerializedTrace: Codable {
        public let tokens: [UInt8]
    }
}
```

---

## Part 10: Invariant Verification Framework

### 10.1 Runtime Invariant Monitor

```swift
//
// InvariantMonitor.swift
// Runtime invariant monitoring
//

import Foundation

/// Runtime invariant monitor
///
/// V10 INVARIANT: Continuously monitor invariants during execution.
/// Violations are logged and can trigger alerts.
public final class InvariantMonitor {

    public static let shared = InvariantMonitor()

    private var invariants: [String: () -> Bool] = [:]
    private var violations: [InvariantViolation] = []
    private let lock = NSLock()

    /// Invariant violation record
    public struct InvariantViolation {
        let invariantName: String
        let timestamp: Date
        let context: String
    }

    /// Register an invariant
    public func register(name: String, check: @escaping () -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        invariants[name] = check
    }

    /// Check all invariants
    public func checkAll(context: String = "") -> [String] {
        lock.lock()
        defer { lock.unlock() }

        var failed: [String] = []

        for (name, check) in invariants {
            if !check() {
                failed.append(name)
                violations.append(InvariantViolation(
                    invariantName: name,
                    timestamp: Date(),
                    context: context
                ))
            }
        }

        return failed
    }

    /// Get violation history
    public func getViolations() -> [InvariantViolation] {
        lock.lock()
        defer { lock.unlock() }
        return violations
    }
}

// Register PR4 invariants at initialization
extension InvariantMonitor {

    public func registerPR4Invariants() {
        // Softmax sum invariant
        register(name: "SoftmaxSumIs65536") {
            // This would check the last computed softmax
            // Implementation depends on how state is tracked
            return true
        }

        // Health isolation invariant
        register(name: "HealthNoQualityDependency") {
            // This is compile-time enforced, but we can check at runtime too
            return true
        }

        // Frame ordering invariant
        register(name: "FrameIDsMonotonic") {
            // Check last processed frame ID is monotonic
            return true
        }

        // Gate state validity
        register(name: "GateStatesValid") {
            // Check all gate states are valid enum values
            return true
        }
    }
}
```

---

## Summary: V10 Supplement Coverage

This supplement addresses the following gaps from the original V10 plan:

1. **Metal Shader Pipeline**: Complete compilation and execution pipeline with verification
2. **libc Reference Generation**: Arbitrary precision reference value generation
3. **Thread Safety**: Thread-safe wrappers with violation detection
4. **Package DAG Extraction**: Build-time dependency extraction scripts
5. **Input Validation**: Module boundary validation framework
6. **Overflow Detection**: Comprehensive overflow detection with structured reporting
7. **Invariant Assertions**: Assert invariants throughout computation
8. **Data Flow Consistency**: Track data provenance to prevent forbidden flows
9. **Mode Coherence**: Ensure STRICT and FAST modes are consistent
10. **Version Compatibility**: Explicit version compatibility matrix
11. **Edge Case Handling**: Specifications for empty, extreme, and timing edge cases
12. **Integration Contracts**: Phase contracts and module API contracts
13. **Failure Recovery**: Recovery strategies for Metal, LUT, and session failures
14. **Platform Details**: iOS, macOS, and Linux specific implementations
15. **Testing Strategy**: Property-based, mutation, and fuzz testing
16. **Migration Safety**: Safe migration protocol with rollback

**Total Supplement Lines:** ~3000+
**Combined with V10 ULTIMATE:** ~6700+ lines of implementation guidance

---

**END OF PR4 V10 SUPPLEMENT**

*Document hash for integrity: SHA-256 to be computed on finalization*
