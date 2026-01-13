//
//  AuditFileWriter.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// 审计文件写入器错误
enum AuditFileWriterError: Error {
    case fileCreationFailed
    case writeFailed
    case recoveryFailed
    case skipRecoveryNotSupported
    case invalidInput(String)   // PR9: for appendRawLine validation
}

/// NDJSON 文件写入器，支持 crash recovery
final class AuditFileWriter {
    private let fileHandle: FileHandle
    private let fileURL: URL
    
    /// 创建或打开审计日志文件
    /// - Parameters:
    ///   - url: 文件路径
    ///   - skipRecovery: Phase 1 不支持，传入 true 会抛出异常
    /// - Throws: AuditFileWriterError
    init(url: URL, skipRecovery: Bool = false) throws {
        if skipRecovery {
            throw AuditFileWriterError.skipRecoveryNotSupported
        }
        
        self.fileURL = url
        
        // 确保目录存在
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        // 如果文件不存在，创建空文件
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        
        // 使用 forUpdating 模式，保证 append-only
        guard let handle = FileHandle(forUpdatingAtPath: url.path) else {
            throw AuditFileWriterError.fileCreationFailed
        }
        
        // 移动到文件末尾
        handle.seekToEndOfFile()
        
        self.fileHandle = handle
        
        // 执行 recovery（截断损坏的尾部）
        try recover()
    }
    
    /// 恢复：读取文件，找到最后一个完整 JSON 行，截断其后内容
    /// 使用 String(decoding:as:) 处理非 UTF-8 数据
    private func recover() throws {
        guard let data = try? Data(contentsOf: fileURL) else {
            // 文件为空或无法读取，无需恢复
            return
        }
        
        guard !data.isEmpty else {
            // 空文件，无需恢复
            return
        }
        
        // 使用 String(decoding:as:) 处理非 UTF-8
        guard let content = String(data: data, encoding: .utf8) else {
            // 非 UTF-8 文件，尝试用 String(decoding:as:) 处理
            let decoded = String(decoding: data, as: UTF8.self)
            // 如果解码失败，保留原数据但截断到最后一个有效行
            // Note: Tail-only recovery for non-UTF-8 files is deferred to future implementation
            // 目前对于非 UTF-8 文件，我们保留原数据但尝试找到最后一个完整行
            let lines = decoded.components(separatedBy: .newlines)
            if let lastValidLine = lines.last(where: { !$0.isEmpty && $0.hasSuffix("}") }) {
                if let lastValidData = lastValidLine.data(using: .utf8) {
                    try? lastValidData.write(to: fileURL)
                }
            }
            return
        }
        
        let lines = content.components(separatedBy: .newlines)
        var lastValidIndex = -1
        
        // 从后往前找最后一个完整的 JSON 行（以 } 结尾）
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && line.hasSuffix("}") {
                // 简单验证：尝试解析 JSON
                if let _ = try? JSONSerialization.jsonObject(with: line.data(using: .utf8) ?? Data()) {
                    lastValidIndex = i
                    break
                }
            }
        }
        
        // 如果找到有效行，截断其后内容
        if lastValidIndex >= 0 {
            let validLines = lines[0...lastValidIndex]
            let validContent = validLines.joined(separator: "\n")
            if let validData = validContent.data(using: .utf8) {
                try? validData.write(to: fileURL)
                fileHandle.seekToEndOfFile()
            }
        } else {
            // 没有找到有效行，清空文件
            try? Data().write(to: fileURL)
            fileHandle.seekToEndOfFile()
        }
    }
    
    /// 追加一行 NDJSON
    func append(_ entry: AuditEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw AuditFileWriterError.writeFailed
        }
        
        let line = jsonString + "\n"
        guard let lineData = line.data(using: .utf8) else {
            throw AuditFileWriterError.writeFailed
        }
        
        fileHandle.write(lineData)
        fileHandle.synchronizeFile()
    }

    // MARK: - SignedAuditLog Support (PR9)

    /// Append raw NDJSON line (for SignedAuditLog).
    /// - Parameter line: Raw JSON string (without trailing newline)
    /// - Throws: If write fails or line contains newline
    ///
    /// CRITICAL:
    /// - Runtime check enforces single-line NDJSON safety.
    /// - Caller must ensure `line` is valid single-line JSON.
    /// - This method appends exactly one "\n".
    /// - Patch A: UTF-8 roundtrip check and JSON shape validation.
    func appendRawLine(_ line: String) throws {
        // Defense in depth: NDJSON must be single line.
        guard !line.contains("\n") && !line.contains("\r") else {
            throw AuditFileWriterError.invalidInput("appendRawLine: line contains newline characters")
        }

        // Patch A: UTF-8 roundtrip check
        let bytes = Data(line.utf8)
        guard String(decoding: bytes, as: UTF8.self) == line else {
            throw AuditFileWriterError.invalidInput("appendRawLine: UTF-8 roundtrip failed")
        }

        // Patch A: JSON shape check (cheap sanity check, no parsing)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw AuditFileWriterError.invalidInput("appendRawLine: line is empty after trimming")
        }
        guard trimmed.hasPrefix("{") && trimmed.hasSuffix("}") else {
            throw AuditFileWriterError.invalidInput("appendRawLine: not a single JSON object line")
        }

        let data = Data((line + "\n").utf8)
        fileHandle.write(data)
        fileHandle.synchronizeFile()
    }
    
    deinit {
        fileHandle.closeFile()
    }
}

