//
// CodeSignatureValidator.swift
// PR5Capture
//
// PR5 v1.8.1 - PART M: 测试和反作弊
// 代码签名验证，二进制完整性
//

import Foundation
import Security
import MachO

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
    public func validate() -> ValidationResult {
        var isValid = false
        var reason = "验证失败"
        
        // 获取主执行文件路径
        guard let executablePath = Bundle.main.executablePath else {
            validationHistory.append((timestamp: Date(), isValid: false))
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
            validationHistory.append((timestamp: Date(), isValid: false))
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
                }
            }
        }
        
        reason = isValid ? "签名有效" : "签名验证失败"
        
        // Record validation
        validationHistory.append((timestamp: Date(), isValid: isValid))
        
        // Keep only recent history (last 100)
        if validationHistory.count > 100 {
            validationHistory.removeFirst()
        }
        
        return ValidationResult(
            isValid: isValid,
            timestamp: Date(),
            reason: reason
        )
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
