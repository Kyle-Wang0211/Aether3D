//
// ScanRecordCell.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Gallery Cell
// Apple-platform only (SwiftUI)
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI

/// Reusable gallery cell for LazyVGrid display
///
/// Layout:
///   - Thumbnail: 16:9 aspect ratio, 8pt corner radius, black placeholder
///   - Name: system 14pt bold, white, 1-line truncation
///   - Relative time: system 12pt, secondary color
///
/// Accessibility:
///   - VoiceOver label: "{name}, {relative time}"
struct ScanRecordCell: View {
    let record: ScanRecord
    let relativeTime: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                if let thumbnailPath = record.thumbnailPath {
                    // Thumbnail image (if available)
                    let store = ScanRecordStore()
                    let url = store.thumbnailURL(for: thumbnailPath)
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        thumbnailPlaceholder
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    thumbnailPlaceholder
                }
            }

            // Name
            Text(record.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            // Relative time + coverage
            HStack(spacing: 4) {
                Text(relativeTime)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                if record.coveragePercentage > 0 {
                    Text("·")
                        .foregroundColor(.secondary)
                    Text("\(Int(record.coveragePercentage * 100))%")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name), \(relativeTime)")
    }

    /// Placeholder when no thumbnail is available
    private var thumbnailPlaceholder: some View {
        Image(systemName: "viewfinder.circle")
            .font(.system(size: 32))
            .foregroundColor(.gray)
    }
}
#endif
