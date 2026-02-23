// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// JobSagaOrchestrator.swift
// Aether3D
//
// Job Saga Orchestrator - Saga pattern for distributed compensation
// 符合 PR2-03: Saga Pattern for Distributed Compensation
//

import Foundation

/// Job Saga Orchestrator
///
/// Implements Saga pattern for distributed compensation in job processing.
/// Each processing step has a corresponding compensation action.
/// 符合 PR2-03: Saga Pattern for Distributed Compensation
public actor JobSagaOrchestrator {
    
    // MARK: - State
    
    /// Active sagas by job ID
    private var activeSagas: [String: JobSaga] = [:]
    
    /// Compensation handler
    private let compensationHandler: JobCompensationHandler
    
    // MARK: - Initialization
    
    /// Initialize Saga Orchestrator
    /// 
    /// - Parameter compensationHandler: Handler for compensation actions
    public init(compensationHandler: JobCompensationHandler) {
        self.compensationHandler = compensationHandler
    }
    
    // MARK: - Saga Management
    
    /// Start a new saga for a job
    /// 
    /// - Parameter jobId: Job ID
    /// - Returns: Saga instance
    public func startSaga(jobId: String) -> JobSaga {
        let saga = JobSaga(jobId: jobId)
        activeSagas[jobId] = saga
        return saga
    }
    
    /// Record a step in the saga
    /// 
    /// - Parameters:
    ///   - jobId: Job ID
    ///   - step: Saga step
    public func recordStep(jobId: String, step: SagaStep) {
        guard var saga = activeSagas[jobId] else {
            return
        }
        
        saga.steps.append(step)
        activeSagas[jobId] = saga
    }
    
    /// Compensate for a failed job
    /// 
    /// Executes compensation actions in reverse order.
    /// - Parameter jobId: Job ID
    /// - Throws: SagaError if compensation fails
    public func compensate(jobId: String) async throws {
        guard let saga = activeSagas[jobId] else {
            throw SagaError.sagaNotFound(jobId)
        }
        
        // Execute compensation in reverse order
        for step in saga.steps.reversed() {
            if let compensation = step.compensation {
                try await compensationHandler.executeCompensation(compensation)
            }
        }
        
        // Remove saga
        activeSagas.removeValue(forKey: jobId)
    }
    
    /// Complete saga successfully
    /// 
    /// - Parameter jobId: Job ID
    public func completeSaga(jobId: String) {
        activeSagas.removeValue(forKey: jobId)
    }
}

/// Job Saga
public struct JobSaga: Sendable {
    public let jobId: String
    public var steps: [SagaStep]
    
    public init(jobId: String, steps: [SagaStep] = []) {
        self.jobId = jobId
        self.steps = steps
    }
}

/// Saga Step
public struct SagaStep: Sendable {
    public let stepId: String
    public let stepType: SagaStepType
    public let compensation: CompensationAction?
    public let timestamp: Date
    
    public init(stepId: String = UUID().uuidString, stepType: SagaStepType, compensation: CompensationAction? = nil, timestamp: Date = Date()) {
        self.stepId = stepId
        self.stepType = stepType
        self.compensation = compensation
        self.timestamp = timestamp
    }
}

/// Saga Step Type
public enum SagaStepType: String, Codable, Sendable {
    case uploadStarted
    case uploadCompleted
    case processingStarted
    case processingCompleted
    case packagingStarted
    case packagingCompleted
}

/// Saga Errors
public enum SagaError: Error, Sendable {
    case sagaNotFound(String)
    case compensationFailed(String)
    
    public var localizedDescription: String {
        switch self {
        case .sagaNotFound(let jobId):
            return "Saga not found for job: \(jobId)"
        case .compensationFailed(let reason):
            return "Compensation failed: \(reason)"
        }
    }
}
