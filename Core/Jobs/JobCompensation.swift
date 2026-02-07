//
// JobCompensation.swift
// Aether3D
//
// Job Compensation - Compensation actions for Saga pattern
// 符合 PR2-03: Saga Pattern for Distributed Compensation
//

import Foundation

/// Compensation Action
///
/// Represents a compensation action to undo a processing step.
public struct CompensationAction: Sendable {
    /// Action type
    public let actionType: CompensationActionType
    
    /// Action parameters (JSON string)
    public let parameters: String?
    
    /// Timestamp when action was created
    public let createdAt: Date
    
    public init(actionType: CompensationActionType, parameters: String? = nil, createdAt: Date = Date()) {
        self.actionType = actionType
        self.parameters = parameters
        self.createdAt = createdAt
    }
}

/// Compensation Action Type
public enum CompensationActionType: String, Codable, Sendable {
    case deleteUploadedFiles
    case cancelProcessing
    case releaseResources
    case rollbackState
    case cleanupArtifacts
}

/// Compensation Handler Protocol
public protocol JobCompensationHandler: Sendable {
    /// Execute compensation action
    /// 
    /// - Parameter action: Compensation action to execute
    /// - Throws: CompensationError if execution fails
    func executeCompensation(_ action: CompensationAction) async throws
}

/// Default Compensation Handler Implementation
public actor DefaultJobCompensationHandler: JobCompensationHandler {
    
    /// Execute compensation action
    public func executeCompensation(_ action: CompensationAction) async throws {
        switch action.actionType {
        case .deleteUploadedFiles:
            try await deleteUploadedFiles(parameters: action.parameters)
        case .cancelProcessing:
            try await cancelProcessing(parameters: action.parameters)
        case .releaseResources:
            try await releaseResources(parameters: action.parameters)
        case .rollbackState:
            try await rollbackState(parameters: action.parameters)
        case .cleanupArtifacts:
            try await cleanupArtifacts(parameters: action.parameters)
        }
    }
    
    /// Delete uploaded files
    private func deleteUploadedFiles(parameters: String?) async throws {
        // Parse parameters and delete files
        // In production, implement actual file deletion
    }
    
    /// Cancel processing
    private func cancelProcessing(parameters: String?) async throws {
        // Cancel ongoing processing
        // In production, implement actual cancellation
    }
    
    /// Release resources
    private func releaseResources(parameters: String?) async throws {
        // Release allocated resources
        // In production, implement actual resource release
    }
    
    /// Rollback state
    private func rollbackState(parameters: String?) async throws {
        // Rollback to previous state
        // In production, implement actual state rollback
    }
    
    /// Cleanup artifacts
    private func cleanupArtifacts(parameters: String?) async throws {
        // Clean up temporary artifacts
        // In production, implement actual cleanup
    }
}

/// Compensation Errors
public enum CompensationError: Error, Sendable {
    case invalidParameters
    case executionFailed(String)
    
    public var localizedDescription: String {
        switch self {
        case .invalidParameters:
            return "Invalid compensation parameters"
        case .executionFailed(let reason):
            return "Compensation execution failed: \(reason)"
        }
    }
}
