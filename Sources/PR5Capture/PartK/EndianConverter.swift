//
// EndianConverter.swift
// PR5Capture
//
// PR5 v1.8.1 - PART K: 跨平台确定性
// 字节序转换，大小端统一处理
//

import Foundation

/// Endian converter
///
/// Converts between big-endian and little-endian representations.
/// Ensures consistent byte order across platforms.
public enum EndianConverter {
    
    // MARK: - Endian Detection
    
    /// Check if platform is little-endian
    public static var isLittleEndian: Bool {
        return Int(1).littleEndian == 1
    }
    
    /// Check if platform is big-endian
    public static var isBigEndian: Bool {
        return !isLittleEndian
    }
    
    // MARK: - Conversion
    
    /// Convert to little-endian
    public static func toLittleEndian(_ value: UInt64) -> UInt64 {
        return value.littleEndian
    }
    
    /// Convert to big-endian
    public static func toBigEndian(_ value: UInt64) -> UInt64 {
        return value.bigEndian
    }
    
    /// Convert to network byte order (big-endian)
    public static func toNetworkByteOrder(_ value: UInt64) -> UInt64 {
        return value.bigEndian
    }
    
    /// Convert from network byte order
    public static func fromNetworkByteOrder(_ value: UInt64) -> UInt64 {
        return UInt64(bigEndian: value)
    }
    
    /// Convert data to little-endian
    public static func dataToLittleEndian(_ data: Data) -> Data {
        guard !isLittleEndian else { return data }
        
        var result = Data()
        for i in stride(from: data.count - 1, through: 0, by: -1) {
            result.append(data[i])
        }
        return result
    }
    
    /// Convert data to big-endian
    public static func dataToBigEndian(_ data: Data) -> Data {
        guard isLittleEndian else { return data }
        
        var result = Data()
        for i in stride(from: data.count - 1, through: 0, by: -1) {
            result.append(data[i])
        }
        return result
    }
}
