//
//  PlainAuditLog.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// 审计日志管理器（单例）
/// Lazy 初始化：首次访问 shared 时创建
final class PlainAuditLog {
    static let shared = PlainAuditLog()
    
    private var writer: AuditFileWriter?
    
    private init() {
        // Lazy initialization on first access to shared
        // 路径选择逻辑在首次 append 时执行
    }
    
    /// 获取审计日志文件路径
    private func getAuditLogURL() -> URL? {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        // Apple 平台：~/Library/Application Support/Aether3D/audit.ndjson
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let aetherDir = appSupport.appendingPathComponent("Aether3D", isDirectory: true)
            return aetherDir.appendingPathComponent("audit.ndjson")
        }
        return nil
        #elseif os(Linux)
        // Linux：/tmp/aether3d-audit.ndjson
        return URL(fileURLWithPath: "/tmp/aether3d-audit.ndjson")
        #else
        // 其他平台：fallback
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("aether3d-audit-fallback.ndjson")
        #endif
    }
    
    /// 初始化 writer（lazy）
    private func ensureWriter() {
        guard writer == nil else { return }
        
        // 尝试使用主路径
        if let url = getAuditLogURL() {
            writer = try? AuditFileWriter(url: url)
            if writer != nil {
                return
            }
        }
        
        // Fallback：使用临时目录（不使用 try!，失败则禁用审计）
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fallbackURL = tempDir.appendingPathComponent("aether3d-audit-fallback.ndjson")
        writer = try? AuditFileWriter(url: fallbackURL)
    }
    
    /// 追加审计条目
    /// 错误处理：静默失败，不阻断 Generate
    func append(_ entry: AuditEntry) {
        // 使用 SamplingPolicy.all.shouldSample 决定是否采样
        guard SamplingPolicy.all.shouldSample else {
            return
        }
        
        ensureWriter()
        
        // 静默失败，不阻断 Generate
        try? writer?.append(entry)
    }
}

