// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// SSOTKeys.swift
// Aether3D
//
// Centralized string keys for serialization, notifications, and analytics.
//

import Foundation

/// Centralized keys to prevent hardcoding strings.
public enum SSOTKeys {
    // MARK: - Serialization Keys
    
    public enum Serialization {
        public static let ssotId = "ssotId"
        public static let name = "name"
        public static let unit = "unit"
        public static let value = "value"
        public static let min = "min"
        public static let max = "max"
        public static let defaultValue = "defaultValue"
        public static let category = "category"
        public static let onExceed = "onExceed"
        public static let onUnderflow = "onUnderflow"
        public static let documentation = "documentation"
    }
    
    // MARK: - Notification Keys
    
    public enum Notification {
        public static let thresholdExceeded = "SSOTThresholdExceeded"
        public static let thresholdUnderflowed = "SSOTThresholdUnderflowed"
        public static let valueClamped = "SSOTValueClamped"
    }
    
    // MARK: - Analytics Keys
    
    public enum Analytics {
        public static let constantAccessed = "SSOTConstantAccessed"
        public static let errorOccurred = "SSOTErrorOccurred"
        public static let validationFailed = "SSOTValidationFailed"
    }
}

