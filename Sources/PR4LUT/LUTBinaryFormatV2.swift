//
// LUTBinaryFormatV2.swift
// PR4LUT
//
// PR4 V10 - Pillars 6 & 27: LUT binary format with versioning and checksum
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import PR4Math

/// LUT binary format V2
///
/// FORMAT:
/// - Header: 16 bytes (magic, version, count, entry size, reserved)
/// - Body: count * 8 bytes (int64 big-endian)
/// - Footer: 32 bytes (SHA-256)
public enum LUTBinaryFormatV2 {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Constants
    // ═══════════════════════════════════════════════════════════════════════
    
    public static let magic: [UInt8] = [0x50, 0x49, 0x5A, 0x31]  // "PIZ1"
    public static let currentVersion: UInt16 = 2
    public static let headerSize: Int = 16
    public static let footerSize: Int = 32
    public static let entrySize: Int = 8
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Header
    // ═══════════════════════════════════════════════════════════════════════
    
    public struct Header {
        public let magic: [UInt8]
        public let version: UInt16
        public let entryCount: UInt16
        public let entrySizeBits: UInt32
        public let reserved: UInt32
        
        public init(entryCount: UInt16) {
            self.magic = LUTBinaryFormatV2.magic
            self.version = LUTBinaryFormatV2.currentVersion
            self.entryCount = entryCount
            self.entrySizeBits = 64
            self.reserved = 0
        }
        
        public func serialize() -> Data {
            var data = Data(capacity: headerSize)
            data.append(contentsOf: magic)
            withUnsafeBytes(of: version.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: entryCount.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: entrySizeBits.bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: reserved.bigEndian) { data.append(contentsOf: $0) }
            return data
        }
        
        public static func deserialize(_ data: Data) throws -> Header {
            guard data.count >= headerSize else {
                throw LUTError.headerTooSmall
            }
            
            let magic = Array(data[0..<4])
            guard magic == LUTBinaryFormatV2.magic else {
                throw LUTError.invalidMagic
            }
            
            let version = data[4..<6].withUnsafeBytes {
                UInt16(bigEndian: $0.load(as: UInt16.self))
            }
            
            guard version <= currentVersion else {
                throw LUTError.unsupportedVersion(version)
            }
            
            let entryCount = data[6..<8].withUnsafeBytes {
                UInt16(bigEndian: $0.load(as: UInt16.self))
            }
            
            let entrySizeBits = data[8..<12].withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            
            guard entrySizeBits == 64 else {
                throw LUTError.invalidEntrySize(entrySizeBits)
            }
            
            return Header(
                magic: magic,
                version: version,
                entryCount: entryCount,
                entrySizeBits: entrySizeBits,
                reserved: 0
            )
        }
        
        private init(magic: [UInt8], version: UInt16, entryCount: UInt16, entrySizeBits: UInt32, reserved: UInt32) {
            self.magic = magic
            self.version = version
            self.entryCount = entryCount
            self.entrySizeBits = entrySizeBits
            self.reserved = reserved
        }
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Write
    // ═══════════════════════════════════════════════════════════════════════
    
    public static func write(_ lut: [Int64], to url: URL) throws {
        guard lut.count <= Int(UInt16.max) else {
            throw LUTError.tooManyEntries
        }
        
        var data = Data()
        
        // Header
        let header = Header(entryCount: UInt16(lut.count))
        data.append(header.serialize())
        
        // Body
        for value in lut {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        
        // Footer (SHA-256)
        #if canImport(CryptoKit)
        let hash = SHA256.hash(data: data)
        #else
        let hash = SHA256.hash(data: data)
        #endif
        data.append(contentsOf: hash)
        
        try data.write(to: url)
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Read
    // ═══════════════════════════════════════════════════════════════════════
    
    public static func read(from url: URL) throws -> [Int64] {
        let data = try Data(contentsOf: url)
        
        guard data.count >= headerSize + footerSize else {
            throw LUTError.fileTooSmall
        }
        
        // Parse header
        let header = try Header.deserialize(data)
        
        // Verify size
        let expectedSize = headerSize + Int(header.entryCount) * entrySize + footerSize
        guard data.count == expectedSize else {
            throw LUTError.sizeMismatch(expected: expectedSize, actual: data.count)
        }
        
        // Verify checksum
        let contentData = data[0..<(data.count - footerSize)]
        let storedHash = data[(data.count - footerSize)...]
        #if canImport(CryptoKit)
        let computedHash = SHA256.hash(data: contentData)
        #else
        let computedHash = SHA256.hash(data: contentData)
        #endif
        
        guard Array(storedHash) == Array(computedHash) else {
            throw LUTError.checksumMismatch
        }
        
        // Read entries
        var lut = [Int64]()
        lut.reserveCapacity(Int(header.entryCount))
        
        for i in 0..<Int(header.entryCount) {
            let offset = headerSize + i * entrySize
            let value = data[offset..<(offset + entrySize)].withUnsafeBytes {
                Int64(bigEndian: $0.load(as: Int64.self))
            }
            lut.append(value)
        }
        
        return lut
    }
}

public enum LUTError: Error {
    case headerTooSmall
    case fileTooSmall
    case invalidMagic
    case unsupportedVersion(UInt16)
    case invalidEntrySize(UInt32)
    case tooManyEntries
    case sizeMismatch(expected: Int, actual: Int)
    case checksumMismatch
}
