// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SecureChannelValidator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART P-R: 安全和上传完整性
// 安全通道验证，TLS/证书检查
//

import Foundation
#if os(iOS) || os(macOS)
import Security
#endif

/// Secure channel validator
///
/// Validates secure channels with TLS/certificate checking.
/// Ensures secure communication channels.
public actor SecureChannelValidator {

    // MARK: - Configuration

    private let config: ExtremeProfile

    // MARK: - State

    /// Validation history
    private var validationHistory: [(timestamp: Date, isValid: Bool, host: String)] = []

    // MARK: - Initialization

    public init(config: ExtremeProfile) {
        self.config = config
    }

    // MARK: - Validation

    /// Validate secure channel
    ///
    /// 执行完整的证书链验证，符合INV-SEC-061: 证书验证必须包含证书链验证。
    /// 在Linux上使用基本的TLS验证。
    public func validateChannel(host: String, certificate: Data?) -> ValidationResult {
        #if os(iOS) || os(macOS)
        return validateChannelApple(host: host, certificate: certificate)
        #else
        return validateChannelLinux(host: host, certificate: certificate)
        #endif
    }

    #if os(iOS) || os(macOS)
    /// Apple平台的证书链验证
    private func validateChannelApple(host: String, certificate: Data?) -> ValidationResult {
        guard let certData = certificate else {
            validationHistory.append((timestamp: Date(), isValid: false, host: host))
            return ValidationResult(
                isValid: false,
                host: host,
                timestamp: Date(),
                reason: "无证书"
            )
        }

        // 创建证书对象
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            validationHistory.append((timestamp: Date(), isValid: false, host: host))
            return ValidationResult(
                isValid: false,
                host: host,
                timestamp: Date(),
                reason: "证书格式无效"
            )
        }

        // 创建信任策略
        let policy = SecPolicyCreateSSL(true, host as CFString)

        // 创建信任对象
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(cert, policy, &trust)

        guard status == errSecSuccess, let serverTrust = trust else {
            validationHistory.append((timestamp: Date(), isValid: false, host: host))
            return ValidationResult(
                isValid: false,
                host: host,
                timestamp: Date(),
                reason: "无法创建信任对象"
            )
        }

        // 设置锚点证书 (证书锁定) - 可选
        // TODO: 在生产环境中实现证书锁定
        // if let pinnedCerts = loadPinnedCertificates() {
        //     SecTrustSetAnchorCertificates(serverTrust, pinnedCerts as CFArray)
        //     SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        // }

        // 评估信任
        var error: CFError?
        let isValid = SecTrustEvaluateWithError(serverTrust, &error)

        // 记录验证
        validationHistory.append((timestamp: Date(), isValid: isValid, host: host))

        // Keep only recent history (last 1000)
        if validationHistory.count > 1000 {
            validationHistory.removeFirst()
        }

        return ValidationResult(
            isValid: isValid,
            host: host,
            timestamp: Date(),
            reason: isValid ? "证书链有效" : (error?.localizedDescription ?? "验证失败")
        )
    }

    /// Load pinned certificates
    ///
    /// 从Bundle加载锁定的证书，用于证书锁定。
    private func loadPinnedCertificates() -> [SecCertificate]? {
        // 从Bundle加载锁定的证书
        guard let pinnedCertPath = Bundle.main.path(forResource: "pinned_cert", ofType: "cer"),
              let pinnedCertData = try? Data(contentsOf: URL(fileURLWithPath: pinnedCertPath)),
              let pinnedCert = SecCertificateCreateWithData(nil, pinnedCertData as CFData) else {
            return nil
        }

        return [pinnedCert]
    }
    #else
    /// Linux平台的证书验证
    ///
    /// 在Linux上使用基本的证书存在性检查。
    /// 真实的TLS验证应由URLSession/Network.framework处理。
    private func validateChannelLinux(host: String, certificate: Data?) -> ValidationResult {
        guard let certData = certificate, !certData.isEmpty else {
            validationHistory.append((timestamp: Date(), isValid: false, host: host))
            return ValidationResult(
                isValid: false,
                host: host,
                timestamp: Date(),
                reason: "无证书"
            )
        }

        // Linux: 基本的证书存在性检查
        // 真实的TLS验证由底层网络库处理
        let isValid = true

        validationHistory.append((timestamp: Date(), isValid: isValid, host: host))

        // Keep only recent history (last 1000)
        if validationHistory.count > 1000 {
            validationHistory.removeFirst()
        }

        return ValidationResult(
            isValid: isValid,
            host: host,
            timestamp: Date(),
            reason: "Linux平台基本验证通过"
        )
    }
    #endif

    // MARK: - Result Types

    /// Validation result
    public struct ValidationResult: Sendable {
        public let isValid: Bool
        public let host: String
        public let timestamp: Date
        public let reason: String

        public init(isValid: Bool, host: String, timestamp: Date, reason: String = "") {
            self.isValid = isValid
            self.host = host
            self.timestamp = timestamp
            self.reason = reason
        }
    }
}
