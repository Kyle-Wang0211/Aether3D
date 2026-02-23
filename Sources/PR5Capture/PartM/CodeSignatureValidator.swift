// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CodeSignatureValidator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 代码签名验证，二进制完整性
//

import Foundation
#if os(macOS)
import Security
#endif

/// Code signature validator
///
/// Validates code signatures and binary integrity.
/// Ensures code has not been modified.
public actor CodeSignatureValidator {

    // MARK: - Configuration

    private let config: ExtremeProfile

    // MARK: - State

    /// Validation history
    private var validationHistory: [(timestamp: Date, isValid: Bool)] = []

    // MARK: - Initialization

    public init(config: ExtremeProfile) {
        self.config = config
    }

    // MARK: - Validation

    /// Validate code signature
    ///
    /// 使用Security.framework进行真实的代码签名验证，符合INV-SEC-059: 代码签名验证必须使用Security.framework。
    /// iOS上使用降级策略（结构与可执行文件完整性检查）。
    /// 在Linux上返回true（Linux没有代码签名机制）。
    public func validate() -> ValidationResult {
        #if os(macOS)
        return validateMacOSSignature()
        #elseif os(iOS)
        return validateIOSFallback()
        #else
        // Linux: 没有代码签名机制，始终返回true
        // 考虑使用其他验证方式（如二进制哈希验证）
        appendValidationHistory(isValid: true)
        return ValidationResult(
            isValid: true,
            timestamp: Date(),
            reason: "Linux平台不支持代码签名验证"
        )
        #endif
    }

    #if os(macOS)
    /// macOS平台的代码签名验证（Security.framework）。
    private func validateMacOSSignature() -> ValidationResult {
        var isValid = false

        // 获取主执行文件路径
        guard let executablePath = Bundle.main.executablePath else {
            appendValidationHistory(isValid: false)
            return ValidationResult(
                isValid: false,
                timestamp: Date(),
                reason: "无法获取执行文件路径"
            )
        }

        // 创建静态代码引用
        var staticCode: SecStaticCode?
        let createResult = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: executablePath) as CFURL,
            [],
            &staticCode
        )

        guard createResult == errSecSuccess, let code = staticCode else {
            appendValidationHistory(isValid: false)
            return ValidationResult(
                isValid: false,
                timestamp: Date(),
                reason: "无法创建代码引用"
            )
        }

        // 验证签名
        let verifyResult = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
            nil
        )

        isValid = (verifyResult == errSecSuccess)

        // 获取签名信息
        var cfInfo: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &cfInfo) == errSecSuccess {
            if let info = cfInfo as? [String: Any] {
                // 验证 Team ID (如果配置了)
                // TODO: 在生产环境中配置真实的 Team ID
                if let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String {
                    // 可以在这里添加 Team ID 验证逻辑
                    // let expectedTeamID = "YOUR_TEAM_ID"
                    // if teamID != expectedTeamID {
                    //     isValid = false
                    // }
                    _ = teamID // Silence unused warning
                }
            }
        }

        let reason = isValid ? "签名有效" : "签名验证失败"
        appendValidationHistory(isValid: isValid)

        return ValidationResult(
            isValid: isValid,
            timestamp: Date(),
            reason: reason
        )
    }
    #endif

    #if os(iOS)
    /// iOS平台降级校验：不调用macOS专属SecStaticCode API。
    /// 该路径聚焦于可执行文件结构完整性与包内约束，避免跨平台编译失败。
    private func validateIOSFallback() -> ValidationResult {
        guard let executablePath = Bundle.main.executablePath else {
            appendValidationHistory(isValid: false)
            return ValidationResult(
                isValid: false,
                timestamp: Date(),
                reason: "iOS降级校验失败：无法获取执行文件路径"
            )
        }

        let executableURL = URL(fileURLWithPath: executablePath)
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let executablePathNormalized = executableURL.standardizedFileURL.path

        guard executablePathNormalized.hasPrefix(bundlePath + "/") else {
            appendValidationHistory(isValid: false)
            return ValidationResult(
                isValid: false,
                timestamp: Date(),
                reason: "iOS降级校验失败：执行文件不在应用包内"
            )
        }

        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: executablePathNormalized),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.int64Value > 0
        else {
            appendValidationHistory(isValid: false)
            return ValidationResult(
                isValid: false,
                timestamp: Date(),
                reason: "iOS降级校验失败：执行文件不可读或大小异常"
            )
        }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let executableName = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        guard !bundleIdentifier.isEmpty, !executableName.isEmpty else {
            appendValidationHistory(isValid: false)
            return ValidationResult(
                isValid: false,
                timestamp: Date(),
                reason: "iOS降级校验失败：Bundle元信息不完整"
            )
        }

        appendValidationHistory(isValid: true)
        return ValidationResult(
            isValid: true,
            timestamp: Date(),
            reason: "iOS降级校验通过（结构完整性）"
        )
    }
    #endif

    private func appendValidationHistory(isValid: Bool) {
        validationHistory.append((timestamp: Date(), isValid: isValid))
        if validationHistory.count > 100 {
            validationHistory.removeFirst()
        }
    }

    // MARK: - Result Types

    /// Validation result
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let timestamp: Date
        public let reason: String

        public init(isValid: Bool, timestamp: Date, reason: String = "") {
            self.isValid = isValid
            self.timestamp = timestamp
            self.reason = reason
        }
    }
}
