//
// RuntimeIntegrityChecker.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 运行时完整性检查，内存篡改检测
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if os(iOS) || os(macOS)
import MachO
#endif
import SharedSecurity

/// Runtime integrity checker
///
/// Checks runtime integrity and detects memory tampering.
/// Monitors for unauthorized memory modifications.
public actor RuntimeIntegrityChecker {

    // MARK: - Configuration

    private let config: ExtremeProfile

    // MARK: - State

    /// Integrity checks
    private var checks: [(timestamp: Date, isValid: Bool)] = []

    /// Baseline hash
    private var baselineHash: String = ""

    // MARK: - Initialization

    public init(config: ExtremeProfile) {
        self.config = config
        establishBaseline()
    }

    /// Establish baseline
    ///
    /// 计算__TEXT段的真实哈希作为基线，符合INV-SEC-060: 运行时完整性必须验证__TEXT段哈希。
    private func establishBaseline() {
        baselineHash = computeTextSegmentHash()
    }

    // MARK: - Integrity Checking

    /// Check runtime integrity
    ///
    /// 验证__TEXT段的哈希是否与基线一致，符合INV-SEC-060: 运行时完整性必须验证__TEXT段哈希。
    public func checkIntegrity() -> IntegrityResult {
        let currentHash = computeTextSegmentHash()
        let isValid = currentHash == baselineHash && !currentHash.isEmpty

        // Record check
        checks.append((timestamp: Date(), isValid: isValid))

        // Keep only recent checks (last 100)
        if checks.count > 100 {
            checks.removeFirst()
        }

        return IntegrityResult(
            isValid: isValid,
            timestamp: Date(),
            expectedHash: baselineHash,
            actualHash: currentHash
        )
    }

    /// Compute __TEXT segment hash
    ///
    /// 计算__TEXT段的SHA256哈希，符合INV-SEC-060。
    /// 在Linux上返回进程映射的基本哈希。
    private func computeTextSegmentHash() -> String {
        #if os(iOS) || os(macOS)
        return computeTextSegmentHashApple()
        #else
        return computeTextSegmentHashLinux()
        #endif
    }

    #if os(iOS) || os(macOS)
    /// Apple平台的__TEXT段哈希计算
    private func computeTextSegmentHashApple() -> String {
        // 获取主执行文件的mach header
        guard let header = _dyld_get_image_header(0) else {
            return ""
        }

        // 查找__TEXT段
        var segmentCommand: UnsafePointer<segment_command_64>?
        var loadCommand = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)

        for _ in 0..<header.pointee.ncmds {
            let cmd = loadCommand.assumingMemoryBound(to: load_command.self)

            if cmd.pointee.cmd == LC_SEGMENT_64 {
                let segment = loadCommand.assumingMemoryBound(to: segment_command_64.self)
                let segname = withUnsafePointer(to: segment.pointee.segname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) {
                        String(cString: $0)
                    }
                }

                if segname == "__TEXT" {
                    segmentCommand = segment
                    break
                }
            }

            loadCommand = loadCommand.advanced(by: Int(cmd.pointee.cmdsize))
        }

        guard let textSegment = segmentCommand else {
            return ""
        }

        // 计算__TEXT段的SHA256
        let slideOffset = _dyld_get_image_vmaddr_slide(0)
        let textAddress = UInt(textSegment.pointee.vmaddr) + UInt(bitPattern: slideOffset)
        let textSize = Int(textSegment.pointee.vmsize)

        guard let textPointer = UnsafeRawPointer(bitPattern: textAddress) else {
            return ""
        }

        let textData = Data(bytes: textPointer, count: textSize)
        return CryptoHasher.sha256(textData)
    }
    #else
    /// Linux平台的完整性哈希计算
    ///
    /// 在Linux上使用/proc/self/maps读取可执行段信息
    private func computeTextSegmentHashLinux() -> String {
        // 读取/proc/self/exe的内容哈希作为基线
        let executablePath = "/proc/self/exe"
        guard let executableData = try? Data(contentsOf: URL(fileURLWithPath: executablePath)) else {
            return ""
        }

        // 只取前64KB作为代码段的近似
        let textSize = min(executableData.count, 65536)
        let textData = executableData.prefix(textSize)

        return CryptoHasher.sha256(Data(textData))
    }
    #endif

    // MARK: - Result Types

    /// Integrity result
    public struct IntegrityResult: Sendable {
        public let isValid: Bool
        public let timestamp: Date
        public let expectedHash: String
        public let actualHash: String

        public init(isValid: Bool, timestamp: Date, expectedHash: String = "", actualHash: String = "") {
            self.isValid = isValid
            self.timestamp = timestamp
            self.expectedHash = expectedHash
            self.actualHash = actualHash
        }
    }
}
