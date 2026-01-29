import XCTest
import Foundation

/// Tests for SSOT constants consistency between code and documentation
/// Verifies that values in Core/Constants/*.swift match docs/constitution/SSOT_CONSTANTS.md
final class SSOTConsistencyTests: XCTestCase {
    
    private var repoRoot: URL!
    private var ssotDoc: URL!
    private var constantsDir: URL!
    
    override func setUp() {
        super.setUp()
        repoRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        ssotDoc = repoRoot.appendingPathComponent("docs/constitution/SSOT_CONSTANTS.md")
        constantsDir = repoRoot.appendingPathComponent("Core/Constants")
    }
    
    // MARK: - System Constants
    
    func testSystemConstantsMaxFrames() throws {
        let docValue = try extractValueFromDoc(section: "SYSTEM_CONSTANTS",
                                                 constant: "SystemConstants.maxFrames")
        let codeValue = try extractValueFromSwift(file: "SystemConstants.swift",
                                                   property: "maxFrames")
        
        XCTAssertEqual(docValue, codeValue,
                       "SystemConstants.maxFrames mismatch: doc=\(docValue ?? "nil"), code=\(codeValue ?? "nil")")
    }
    
    func testSystemConstantsMinFrames() throws {
        let docValue = try extractValueFromDoc(section: "SYSTEM_CONSTANTS",
                                                 constant: "SystemConstants.minFrames")
        let codeValue = try extractValueFromSwift(file: "SystemConstants.swift",
                                                   property: "minFrames")
        
        XCTAssertEqual(docValue, codeValue)
    }
    
    func testSystemConstantsMaxGaussians() throws {
        let docValue = try extractValueFromDoc(section: "SYSTEM_CONSTANTS",
                                                 constant: "SystemConstants.maxGaussians")
        let codeValue = try extractValueFromSwift(file: "SystemConstants.swift",
                                                   property: "maxGaussians")
        
        XCTAssertEqual(docValue, codeValue)
    }
    
    // MARK: - Conversion Constants
    
    func testConversionConstantsBytesPerKB() throws {
        let docValue = try extractValueFromDoc(section: "CONVERSION_CONSTANTS",
                                                 constant: "ConversionConstants.bytesPerKB")
        let codeValue = try extractValueFromSwift(file: "ConversionConstants.swift",
                                                   property: "bytesPerKB")
        
        XCTAssertEqual(docValue, codeValue)
    }
    
    func testConversionConstantsBytesPerMB() throws {
        let docValue = try extractValueFromDoc(section: "CONVERSION_CONSTANTS",
                                                 constant: "ConversionConstants.bytesPerMB")
        let codeValue = try extractValueFromSwift(file: "ConversionConstants.swift",
                                                   property: "bytesPerMB")
        
        XCTAssertEqual(docValue, codeValue)
    }
    
    // MARK: - Quality Thresholds
    
    func testQualityThresholdsSfmRegistrationMinRatio() throws {
        let docValue = try extractValueFromDoc(section: "QUALITY_THRESHOLDS",
                                                 constant: "QualityThresholds.sfmRegistrationMinRatio")
        let codeValue = try extractValueFromSwift(file: "QualityThresholds.swift",
                                                   property: "sfmRegistrationMinRatio")
        
        XCTAssertEqual(docValue, codeValue)
    }
    
    func testQualityThresholdsPsnrMinDb() throws {
        let docValue = try extractValueFromDoc(section: "QUALITY_THRESHOLDS",
                                                 constant: "QualityThresholds.psnrMinDb")
        let codeValue = try extractValueFromSwift(file: "QualityThresholds.swift",
                                                   property: "psnrMinDb")
        
        XCTAssertEqual(docValue, codeValue)
    }
    
    // MARK: - Helpers
    
    private func extractValueFromDoc(section: String, constant: String) throws -> String? {
        let content = try String(contentsOf: ssotDoc, encoding: .utf8)
        
        // Find section
        let sectionPattern = "SSOT:\(section):BEGIN(.+?)SSOT:\(section):END"
        guard let sectionMatch = content.range(of: sectionPattern, options: .regularExpression) else {
            return nil
        }
        
        let sectionContent = String(content[sectionMatch])
        
        // Find constant value in table
        // Format: | ConstantName | value | unit | ...
        let lines = sectionContent.components(separatedBy: "\n")
        for line in lines {
            if line.contains(constant) {
                let parts = line.components(separatedBy: "|")
                if parts.count >= 3 {
                    return parts[2].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        
        return nil
    }
    
    private func extractValueFromSwift(file: String, property: String) throws -> String? {
        let filePath = constantsDir.appendingPathComponent(file)
        
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return nil
        }
        
        let content = try String(contentsOf: filePath, encoding: .utf8)
        
        // Look for: static let property = value or static let property: Type = value
        let pattern = #"static\s+(?:let|var)\s+\#(property)\s*(?::\s*\w+)?\s*=\s*([0-9.]+|\.infinity|Double\.infinity)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(content.startIndex..., in: content)
        
        if let match = regex.firstMatch(in: content, range: range),
           let valueRange = Range(match.range(at: 1), in: content) {
            let value = String(content[valueRange])
            
            // Normalize infinity
            if value.contains("infinity") {
                return "∞"
            }
            
            return value
        }
        
        return nil
    }
}
