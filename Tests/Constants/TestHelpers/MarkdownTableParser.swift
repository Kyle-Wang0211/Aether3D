// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MarkdownTableParser.swift
// Aether3D
//
// Parser for Markdown tables in documentation.
//

import Foundation

/// Parser for Markdown tables
public enum MarkdownTableParser {
    /// Extract table rows from a Markdown block
    public static func parseTable(from content: String, blockName: String) -> [[String]]? {
        // Find the block (e.g., "## SYSTEM_CONSTANTS")
        let blockPattern = "##\\s+\(blockName)"
        guard let blockRange = content.range(of: blockPattern, options: .regularExpression) else {
            return nil
        }
        
        // Extract content after the block header
        let afterBlock = String(content[blockRange.upperBound...])
        
        // Find the first table (starts with |)
        let lines = afterBlock.components(separatedBy: .newlines)
        var tableStart: Int?
        var tableEnd: Int?
        
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") {
                if tableStart == nil {
                    tableStart = index
                }
                tableEnd = index
            } else if tableStart != nil && !trimmed.isEmpty {
                // End of table
                break
            }
        }
        
        guard let start = tableStart, let end = tableEnd else {
            return nil
        }
        
        // Parse table rows
        var rows: [[String]] = []
        for i in start...end {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") && line.hasSuffix("|") {
                let cells = line
                    .dropFirst()
                    .dropLast()
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                
                // Skip separator row (---)
                if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == " " } }) {
                    continue
                }
                
                rows.append(cells)
            }
        }
        
        return rows.isEmpty ? nil : rows
    }
    
    /// Find a specific block in Markdown content
    public static func findBlock(_ blockName: String, in content: String) -> String? {
        let pattern = "##\\s+\(blockName)\\s*\\n([\\s\\S]*?)(?=\\n##|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range) else {
            return nil
        }
        
        guard let blockRange = Range(match.range(at: 1), in: content) else {
            return nil
        }
        
        return String(content[blockRange])
    }
}

