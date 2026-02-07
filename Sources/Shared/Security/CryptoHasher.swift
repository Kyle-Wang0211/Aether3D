import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// 密码学安全哈希工具
/// 
/// 提供密码学安全的哈希计算功能，替代不安全的 hashValue。
/// 符合 INV-SEC-057: 所有哈希计算必须使用 CryptoKit SHA256。
public enum CryptoHasher {
    
    /// 计算Data的SHA256哈希
    /// - Parameter data: 要哈希的数据
    /// - Returns: SHA256哈希值的十六进制字符串表示
    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        fatalError("CryptoKit or Crypto not available")
        #endif
    }
    
    /// 计算String的SHA256哈希
    /// - Parameter string: 要哈希的字符串
    /// - Returns: SHA256哈希值的十六进制字符串表示，如果字符串无法转换为UTF-8则返回空字符串
    public static func sha256(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
        return sha256(data)
    }
    
    /// 计算Data的SHA512哈希
    /// - Parameter data: 要哈希的数据
    /// - Returns: SHA512哈希值的十六进制字符串表示
    public static func sha512(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = SHA512.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let digest = SHA512.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
        #else
        fatalError("CryptoKit or Crypto not available")
        #endif
    }
    
    /// 计算HMAC-SHA256
    /// - Parameters:
    ///   - data: 要计算HMAC的数据
    ///   - key: 对称密钥
    /// - Returns: HMAC-SHA256的十六进制字符串表示
    public static func hmacSHA256(data: Data, key: SymmetricKey) -> String {
        #if canImport(CryptoKit)
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(hmac).map { String(format: "%02x", $0) }.joined()
        #elseif canImport(Crypto)
        let hmac = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(hmac).map { String(format: "%02x", $0) }.joined()
        #else
        fatalError("CryptoKit or Crypto not available")
        #endif
    }
}
