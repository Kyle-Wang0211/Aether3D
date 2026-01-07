//
//  AuditFileWriterRecoveryTests.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import XCTest
@testable import Aether3DCore
import Foundation

#if canImport(ObjectiveC)
import ObjectiveC
#endif

/// Cross-platform autoreleasepool helper
func withAutoreleasepool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

final class AuditFileWriterRecoveryTests: XCTestCase {
    private var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func test_emptyFileRecovery() throws {
        try withAutoreleasepool {
            let fileURL = self.tempDir.appendingPathComponent("empty.ndjson")
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            
            let writer = try? AuditFileWriter(url: fileURL)
            XCTAssertNotNil(writer)
            
            let entry = AuditEntry(
                timestamp: Date(),
                eventType: "test"
            )
            try? writer?.append(entry)
            
            // 验证文件内容
            let content = try? String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertNotNil(content)
            XCTAssertTrue(content?.contains("\"eventType\":\"test\"") ?? false)
        }
    }
    
    func test_validLinesRecovery() throws {
        try withAutoreleasepool {
            let fileURL = self.tempDir.appendingPathComponent("valid.ndjson")
            
            // 创建包含有效 JSON 行的文件
            let validEntry1 = AuditEntry(timestamp: Date(), eventType: "event1")
            let validEntry2 = AuditEntry(timestamp: Date(), eventType: "event2")
            
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data1 = try! encoder.encode(validEntry1)
            let data2 = try! encoder.encode(validEntry2)
            
            let json1 = String(data: data1, encoding: .utf8)!
            let json2 = String(data: data2, encoding: .utf8)!
            
            let content = json1 + "\n" + json2 + "\n"
            try! content.write(to: fileURL, atomically: true, encoding: .utf8)
            
            let writer = try? AuditFileWriter(url: fileURL)
            XCTAssertNotNil(writer)
            
            // 验证文件仍然包含两行
            let recoveredContent = try? String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertNotNil(recoveredContent)
            let lines = recoveredContent?.components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
            XCTAssertGreaterThanOrEqual(lines.count, 2)
        }
    }
    
    func test_truncateCorruptedTail() throws {
        try withAutoreleasepool {
            let fileURL = self.tempDir.appendingPathComponent("corrupted.ndjson")
            
            // 创建包含有效行和损坏尾部的文件
            let validEntry = AuditEntry(timestamp: Date(), eventType: "valid")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try! encoder.encode(validEntry)
            let json = String(data: data, encoding: .utf8)!
            
            // 添加损坏的尾部
            let corruptedContent = json + "\n" + "{\"incomplete" + "\n" + "garbage"
            try! corruptedContent.write(to: fileURL, atomically: true, encoding: .utf8)
            
            let writer = try? AuditFileWriter(url: fileURL)
            XCTAssertNotNil(writer)
            
            // 验证损坏的尾部被截断
            let recoveredContent = try? String(contentsOf: fileURL, encoding: .utf8)
            XCTAssertNotNil(recoveredContent)
            let lines = recoveredContent?.components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
            
            // 应该只保留完整的 JSON 行
            for line in lines {
                if !line.isEmpty {
                    // 每行应该是有效的 JSON
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    XCTAssertTrue(trimmed.hasSuffix("}"), "Line should end with }: \(trimmed)")
                }
            }
        }
    }
    
    func test_nonUTF8FileHandling() throws {
        try withAutoreleasepool {
            let fileURL = self.tempDir.appendingPathComponent("nonutf8.ndjson")
            
            // 创建包含非 UTF-8 数据的文件
            let invalidUTF8: [UInt8] = [0xFF, 0xFE, 0xFD, 0xFC]
            let data = Data(invalidUTF8)
            try! data.write(to: fileURL)
            
            // 验证文件大小
            let fileSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
            XCTAssertEqual(fileSize, 4)
            
            // 尝试创建 writer（应该能处理非 UTF-8）
            _ = try? AuditFileWriter(url: fileURL)
            // writer 可能为 nil（如果 recovery 失败），或者成功创建
            // 关键是不要崩溃
            
            // 验证文件仍然存在
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }
    
    func test_skipRecoveryThrowsError() {
        do {
            try withAutoreleasepool {
                let fileURL = self.tempDir.appendingPathComponent("skip.ndjson")
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                
                _ = try AuditFileWriter(url: fileURL, skipRecovery: true)
                XCTFail("Expected skipRecoveryNotSupported error")
            }
        } catch AuditFileWriterError.skipRecoveryNotSupported {
            // 预期错误
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

