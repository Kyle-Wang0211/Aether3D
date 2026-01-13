// PR#3 — API Contract v2.0
// Stage: WHITEBOX | Camera-only
// Endpoints: 12 | HTTP Codes: 10 (3 success + 7 error) | Business Errors: 7

import Foundation

/// API端点定义（闭集：12个端点）
public enum APIEndpoint {
    // MARK: - Health
    
    /// GET /v1/health - 健康检查
    public static let health = "/v1/health"
    
    // MARK: - Uploads
    
    /// POST /v1/uploads - 创建上传会话
    public static let uploads = "/v1/uploads"
    
    /// PATCH /v1/uploads/{id}/chunks - 上传分片
    public static func uploadChunks(_ id: String) -> String {
        "/v1/uploads/\(id)/chunks"
    }
    
    /// GET /v1/uploads/{id}/chunks - 查询已上传分片
    public static func getChunks(_ id: String) -> String {
        "/v1/uploads/\(id)/chunks"
    }
    
    /// POST /v1/uploads/{id}/complete - 完成上传
    public static func uploadComplete(_ id: String) -> String {
        "/v1/uploads/\(id)/complete"
    }
    
    // MARK: - Jobs
    
    /// POST /v1/jobs - 创建任务
    public static let jobs = "/v1/jobs"
    
    /// GET /v1/jobs/{id} - 查询任务状态
    public static func job(_ id: String) -> String {
        "/v1/jobs/\(id)"
    }
    
    /// GET /v1/jobs - 查询任务列表
    public static let jobsList = "/v1/jobs"
    
    /// POST /v1/jobs/{id}/cancel - 取消任务
    public static func jobCancel(_ id: String) -> String {
        "/v1/jobs/\(id)/cancel"
    }
    
    /// GET /v1/jobs/{id}/timeline - 查询任务时间线
    public static func jobTimeline(_ id: String) -> String {
        "/v1/jobs/\(id)/timeline"
    }
    
    // MARK: - Artifacts
    
    /// GET /v1/artifacts/{id} - 获取产物元信息
    public static func artifact(_ id: String) -> String {
        "/v1/artifacts/\(id)"
    }
    
    /// GET /v1/artifacts/{id}/download - 下载产物
    public static func artifactDownload(_ id: String) -> String {
        "/v1/artifacts/\(id)/download"
    }
}

