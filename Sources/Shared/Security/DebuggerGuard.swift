// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
#if canImport(Darwin)
import Darwin

// ptrace constants and declaration for anti-debugging
// These are not exposed by Darwin module, so we declare them manually
private let PT_DENY_ATTACH: CInt = 31

@_silgen_name("ptrace")
private func ptrace(_ request: CInt, _ pid: pid_t, _ addr: UnsafeMutableRawPointer?, _ data: CInt) -> CInt

#elseif os(Linux)
import Glibc
#endif

/// 调试器防护工具
/// 
/// 提供多层调试器检测功能，符合 INV-SEC-058: 调试器检测必须使用3+独立技术。
/// 使用多种检测方法确保可靠性：sysctl、ptrace、父进程检查、DYLD注入检测。
public enum DebuggerGuard {
    
    /// 全面检测调试器
    /// - Returns: 如果检测到调试器则返回true，否则返回false
    public static func isDebuggerPresent() -> Bool {
        return checkSysctl() ||
               checkPtrace() ||
               checkParentProcess() ||
               checkDYLD()
    }
    
    /// sysctl检测 - 检查进程是否被跟踪
    /// - Returns: 如果进程被跟踪则返回true
    private static func checkSysctl() -> Bool {
        #if os(iOS) || os(macOS)
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else {
            return false
        }
        
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #elseif os(Linux)
        // Linux: Check /proc/self/status for TracerPid
        if let status = try? String(contentsOfFile: "/proc/self/status"),
           let tracerPidLine = status.components(separatedBy: "\n").first(where: { $0.hasPrefix("TracerPid:") }),
           let tracerPid = Int(tracerPidLine.components(separatedBy: ":")[1].trimmingCharacters(in: .whitespaces)),
           tracerPid != 0 {
            return true
        }
        return false
        #else
        return false
        #endif
    }
    
    /// ptrace检测 - 尝试拒绝调试器附加
    /// - Returns: 如果检测到调试器则返回true
    private static func checkPtrace() -> Bool {
        #if os(iOS) || os(macOS)
        #if !DEBUG
        // 在Release模式下，尝试拒绝调试器附加
        // 如果已经被调试，这会失败
        let ptraceResult = ptrace(PT_DENY_ATTACH, 0, nil, 0)
        if ptraceResult == -1 {
            // Failed to deny attach - may already be traced
            // Note: ENOTSUP check removed as errno may not be reliable here
            return true
        }
        #endif
        return false
        #elseif os(Linux)
        // Linux: ptrace is available but PT_DENY_ATTACH is macOS-specific
        // Check if process is being traced via /proc/self/status
        return checkSysctl() // Use sysctl check which handles Linux
        #else
        return false
        #endif
    }
    
    /// 父进程检测 - 检查父进程是否为调试器
    /// - Returns: 如果父进程是调试器则返回true
    private static func checkParentProcess() -> Bool {
        #if os(iOS) || os(macOS)
        let parentPid = getppid()
        var parentInfo = kinfo_proc()
        var parentMib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, parentPid]
        var parentSize = MemoryLayout<kinfo_proc>.stride
        
        guard sysctl(&parentMib, UInt32(parentMib.count), &parentInfo, &parentSize, nil, 0) == 0 else {
            return false
        }
        
        let parentName = withUnsafePointer(to: &parentInfo.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        
        let debuggers = ["debugserver", "lldb", "gdb", "frida", "cycript", "substrate"]
        return debuggers.contains { parentName.lowercased().contains($0) }
        #elseif os(Linux)
        // Linux: Read parent process name from /proc
        let parentPid = getppid()
        if let cmdline = try? String(contentsOfFile: "/proc/\(parentPid)/comm") {
            let parentName = cmdline.trimmingCharacters(in: .whitespacesAndNewlines)
            let debuggers = ["gdb", "lldb", "strace", "ltrace", "frida"]
            return debuggers.contains { parentName.lowercased().contains($0) }
        }
        return false
        #else
        return false
        #endif
    }
    
    /// DYLD注入检测 - 检查动态库注入
    /// - Returns: 如果检测到DYLD注入则返回true
    private static func checkDYLD() -> Bool {
        #if os(iOS) || os(macOS)
        let env = ProcessInfo.processInfo.environment
        
        // 检查DYLD_INSERT_LIBRARIES
        if let insertLibs = env["DYLD_INSERT_LIBRARIES"], !insertLibs.isEmpty {
            return true
        }
        
        // 检查Frida相关
        if let _ = dlopen("FridaGadget.dylib", RTLD_NOLOAD) {
            return true
        }
        
        return false
        #elseif os(Linux)
        // Linux: Check LD_PRELOAD for injection
        let env = ProcessInfo.processInfo.environment
        if let preload = env["LD_PRELOAD"], !preload.isEmpty {
            return true
        }
        return false
        #else
        return false
        #endif
    }
}
