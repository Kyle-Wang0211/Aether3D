//
// RetryConstants.swift
// Aether3D
//
// Retry and timeout strategy constants.
//

import Foundation

/// Retry and timeout strategy constants.
public enum RetryConstants {
    
    /// 自动重试次数
    /// - 用户可见文案："正在尝试第X次，共10次"
    public static let maxRetryCount: Int = 10
    
    /// 重试间隔（秒）
    public static let retryIntervalSeconds: TimeInterval = 10.0
    
    /// 上传超时（秒）
    /// - .infinity 表示无限制，后台持续上传直到完成或用户取消
    public static let uploadTimeoutSeconds: TimeInterval = .infinity
    
    /// 下载重试次数
    public static let downloadMaxRetryCount: Int = 3
    
    /// 产物 TTL（秒）
    /// - 云端保留时间，ACK 确认后删除
    public static let artifactTTLSeconds: TimeInterval = 1800  // 30分钟
    
    /// 心跳间隔（秒）
    public static let heartbeatIntervalSeconds: TimeInterval = 30.0
    
    /// 轮询间隔（秒）
    public static let pollingIntervalSeconds: TimeInterval = 3.0
    
    /// 卡死判定时间（秒）
    /// - 需要三个指标同时满足：进度无变化 + 日志无更新 + 心跳无响应
    public static let stallDetectionSeconds: TimeInterval = 300  // 5分钟
    
    /// 卡死判定心跳连续失败次数
    public static let stallHeartbeatFailureCount: Int = 10
    
    // MARK: - Specifications
    
    /// Specification for maxRetryCount
    public static let maxRetryCountSpec = SystemConstantSpec(
        ssotId: "RetryConstants.maxRetryCount",
        name: "Maximum Retry Count",
        unit: .count,
        value: maxRetryCount,
        documentation: "用户可接受的最大等待重试次数，配合10秒间隔共100秒"
    )
    
    /// Specification for retryIntervalSeconds
    public static let retryIntervalSecondsSpec = ThresholdSpec(
        ssotId: "RetryConstants.retryIntervalSeconds",
        name: "Retry Interval",
        unit: .seconds,
        category: .performance,
        min: 1.0,
        max: 60.0,
        defaultValue: retryIntervalSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "每次重试间隔，足够让临时网络问题恢复"
    )
    
    /// Specification for uploadTimeoutSeconds
    /// Note: .infinity is represented as a very large value for spec
    public static let uploadTimeoutSecondsSpec = ThresholdSpec(
        ssotId: "RetryConstants.uploadTimeoutSeconds",
        name: "Upload Timeout",
        unit: .seconds,
        category: .performance,
        min: 0.0,
        max: Double.greatestFiniteMagnitude,
        defaultValue: Double.greatestFiniteMagnitude,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "无限制，后台持续上传，1.08GB大文件需要充足时间"
    )
    
    /// Specification for downloadMaxRetryCount
    public static let downloadMaxRetryCountSpec = SystemConstantSpec(
        ssotId: "RetryConstants.downloadMaxRetryCount",
        name: "Download Maximum Retry Count",
        unit: .count,
        value: downloadMaxRetryCount,
        documentation: "下载失败重试次数，指数退避"
    )
    
    /// Specification for artifactTTLSeconds
    public static let artifactTTLSecondsSpec = ThresholdSpec(
        ssotId: "RetryConstants.artifactTTLSeconds",
        name: "Artifact TTL",
        unit: .seconds,
        category: .resource,
        min: 60.0,
        max: 3600.0,
        defaultValue: artifactTTLSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "30分钟云端保留，足够断点续传，ACK后立即删除"
    )
    
    /// Specification for heartbeatIntervalSeconds
    public static let heartbeatIntervalSecondsSpec = ThresholdSpec(
        ssotId: "RetryConstants.heartbeatIntervalSeconds",
        name: "Heartbeat Interval",
        unit: .seconds,
        category: .performance,
        min: 5.0,
        max: 120.0,
        defaultValue: heartbeatIntervalSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "心跳间隔，平衡服务器负载与状态检测及时性"
    )
    
    /// Specification for pollingIntervalSeconds
    public static let pollingIntervalSecondsSpec = ThresholdSpec(
        ssotId: "RetryConstants.pollingIntervalSeconds",
        name: "Polling Interval",
        unit: .seconds,
        category: .performance,
        min: 1.0,
        max: 10.0,
        defaultValue: pollingIntervalSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "进度轮询间隔，白盒阶段使用，后续可升级WebSocket"
    )
    
    /// Specification for stallDetectionSeconds
    public static let stallDetectionSecondsSpec = ThresholdSpec(
        ssotId: "RetryConstants.stallDetectionSeconds",
        name: "Stall Detection Time",
        unit: .seconds,
        category: .safety,
        min: 60.0,
        max: 600.0,
        defaultValue: stallDetectionSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "5分钟无响应判定卡死，需三指标同时满足"
    )
    
    /// Specification for stallHeartbeatFailureCount
    public static let stallHeartbeatFailureCountSpec = SystemConstantSpec(
        ssotId: "RetryConstants.stallHeartbeatFailureCount",
        name: "Stall Heartbeat Failure Count",
        unit: .count,
        value: stallHeartbeatFailureCount,
        documentation: "连续10次心跳失败（配合30秒间隔=5分钟）"
    )
    
    /// All retry constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .systemConstant(maxRetryCountSpec),
        .threshold(retryIntervalSecondsSpec),
        .threshold(uploadTimeoutSecondsSpec),
        .systemConstant(downloadMaxRetryCountSpec),
        .threshold(artifactTTLSecondsSpec),
        .threshold(heartbeatIntervalSecondsSpec),
        .threshold(pollingIntervalSecondsSpec),
        .threshold(stallDetectionSecondsSpec),
        .systemConstant(stallHeartbeatFailureCountSpec)
    ]
}

