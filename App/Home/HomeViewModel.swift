//
// HomeViewModel.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Home Page ViewModel
// Apple-platform only (SwiftUI)
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// ViewModel for the Home gallery page
///
/// Manages scan record loading, deletion, and navigation state.
/// Pattern: @MainActor + ObservableObject + @Published + Task
/// (consistent with PipelineDemoViewModel)
@MainActor
final class HomeViewModel: ObservableObject {
    @Published var scanRecords: [ScanRecord] = []
    @Published var navigateToScan: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let store: ScanRecordStore

    init(store: ScanRecordStore = ScanRecordStore()) {
        self.store = store
    }

    /// Load records from persistent storage (background load, main thread publish)
    func loadRecords() {
        isLoading = true
        Task {
            let records = store.loadRecords()
            self.scanRecords = records.sorted { $0.createdAt > $1.createdAt }
            self.isLoading = false
        }
    }

    /// Delete a scan record (updates both store and in-memory array)
    func deleteRecord(_ record: ScanRecord) {
        store.deleteRecord(id: record.id)
        scanRecords.removeAll { $0.id == record.id }
    }

    /// Save a completed scan result
    func saveScanResult(_ record: ScanRecord) {
        store.saveRecord(record)
        loadRecords()  // Refresh list
    }

    /// Relative time display (Chinese locale)
    ///
    /// Examples: "刚刚", "5分钟前", "1小时前", "昨天"
    func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
