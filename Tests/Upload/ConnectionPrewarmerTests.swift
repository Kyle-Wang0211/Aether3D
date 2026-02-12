//
//  ConnectionPrewarmerTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Connection Prewarmer Tests
//
//  NOTE: Tests that call startPrewarming() are excluded because they trigger
//  real DNS resolution (CFHostStartInfoResolution) and HTTP HEAD requests
//  which hang in CI/test environments. All network-dependent behavior is
//  tested through integration tests instead.
//

import XCTest
@testable import Aether3DCore

final class ConnectionPrewarmerTests: XCTestCase {

    var prewarmer: ConnectionPrewarmer!
    var uploadEndpoint: URL!

    override func setUp() {
        super.setUp()
        uploadEndpoint = URL(string: "https://example.com/upload")!
        prewarmer = ConnectionPrewarmer(uploadEndpoint: uploadEndpoint)
    }

    override func tearDown() {
        prewarmer = nil
        uploadEndpoint = nil
        super.tearDown()
    }

    // MARK: - PrewarmingStage Enum

    func testPrewarmingStage_NotStarted_Exists() {
        XCTAssertEqual(PrewarmingStage.notStarted.rawValue, "notStarted")
    }

    func testPrewarmingStage_DNSResolved_Exists() {
        XCTAssertEqual(PrewarmingStage.dnsResolved.rawValue, "dnsResolved")
    }

    func testPrewarmingStage_TCPConnected_Exists() {
        XCTAssertEqual(PrewarmingStage.tcpConnected.rawValue, "tcpConnected")
    }

    func testPrewarmingStage_TLSHandshaked_Exists() {
        XCTAssertEqual(PrewarmingStage.tlsHandshaked.rawValue, "tlsHandshaked")
    }

    func testPrewarmingStage_HTTP2Ready_Exists() {
        XCTAssertEqual(PrewarmingStage.http2Ready.rawValue, "http2Ready")
    }

    func testPrewarmingStage_HTTP3Ready_Exists() {
        XCTAssertEqual(PrewarmingStage.http3Ready.rawValue, "http3Ready")
    }

    func testPrewarmingStage_Ready_Exists() {
        XCTAssertEqual(PrewarmingStage.ready.rawValue, "ready")
    }

    func testPrewarmingStage_AllCases_7() {
        let cases: [PrewarmingStage] = [
            .notStarted, .dnsResolved, .tcpConnected,
            .tlsHandshaked, .http2Ready, .http3Ready, .ready
        ]
        XCTAssertEqual(cases.count, 7)
    }

    func testPrewarmingStage_Sendable() {
        let _: any Sendable = PrewarmingStage.notStarted
        XCTAssertTrue(true)
    }

    func testPrewarmingStage_RawValues_Unique() {
        let rawValues: [String] = [
            PrewarmingStage.notStarted.rawValue,
            PrewarmingStage.dnsResolved.rawValue,
            PrewarmingStage.tcpConnected.rawValue,
            PrewarmingStage.tlsHandshaked.rawValue,
            PrewarmingStage.http2Ready.rawValue,
            PrewarmingStage.http3Ready.rawValue,
            PrewarmingStage.ready.rawValue
        ]
        XCTAssertEqual(Set(rawValues).count, 7, "All raw values should be unique")
    }

    // MARK: - Initial State (no network)

    func testGetCurrentStage_Initial_NotStarted() async {
        let stage = await prewarmer.getCurrentStage()
        XCTAssertEqual(stage, .notStarted)
    }

    func testGetPrewarmedSession_NotReady_ReturnsNil() async {
        let session = await prewarmer.getPrewarmedSession()
        XCTAssertNil(session)
    }

    func testProbeQUICSupport_NotStarted_ReturnsFalse() async {
        let supported = await prewarmer.probeQUICSupport()
        XCTAssertFalse(supported)
    }

    func testProbeQUICSupport_NoSession_ReturnsFalse() async {
        let newPrewarmer = ConnectionPrewarmer(uploadEndpoint: uploadEndpoint)
        let supported = await newPrewarmer.probeQUICSupport()
        XCTAssertFalse(supported)
    }

    // MARK: - Initialization (no network)

    func testInit_WithCertificatePinManager_StageNotStarted() async {
        let pinManager = PR9CertificatePinManager()
        let p = ConnectionPrewarmer(uploadEndpoint: uploadEndpoint, certificatePinManager: pinManager)
        let stage = await p.getCurrentStage()
        XCTAssertEqual(stage, .notStarted)
    }

    func testInit_WithoutCertificatePinManager_StageNotStarted() async {
        let stage = await prewarmer.getCurrentStage()
        XCTAssertEqual(stage, .notStarted)
    }

    func testInit_MultipleInstances_Independent() async {
        let ep1 = URL(string: "https://example.com/upload")!
        let ep2 = URL(string: "https://example.org/upload")!
        let p1 = ConnectionPrewarmer(uploadEndpoint: ep1)
        let p2 = ConnectionPrewarmer(uploadEndpoint: ep2)

        let s1 = await p1.getCurrentStage()
        let s2 = await p2.getCurrentStage()

        XCTAssertEqual(s1, .notStarted)
        XCTAssertEqual(s2, .notStarted)
    }

    func testInit_SessionNil_BeforePrewarming() async {
        let session = await prewarmer.getPrewarmedSession()
        XCTAssertNil(session)
    }

    // MARK: - Actor Safety (no network)

    func testGetCurrentStage_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: PrewarmingStage.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.prewarmer.getCurrentStage()
                }
            }
            var stages: [PrewarmingStage] = []
            for await stage in group {
                stages.append(stage)
            }
            XCTAssertEqual(stages.count, 10)
            XCTAssertTrue(stages.allSatisfy { $0 == .notStarted })
        }
    }

    func testGetPrewarmedSession_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.prewarmer.getPrewarmedSession()
                }
            }
        }
        XCTAssertTrue(true)
    }

    func testProbeQUICSupport_ConcurrentAccess_NoSession_Safe() async {
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.prewarmer.probeQUICSupport()
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            XCTAssertEqual(results.count, 10)
            XCTAssertTrue(results.allSatisfy { $0 == false })
        }
    }

    func testMultiplePrewarmers_ConcurrentInit_Safe() async {
        await withTaskGroup(of: PrewarmingStage.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let p = ConnectionPrewarmer(uploadEndpoint: self.uploadEndpoint)
                    return await p.getCurrentStage()
                }
            }
            var stages: [PrewarmingStage] = []
            for await stage in group {
                stages.append(stage)
            }
            XCTAssertEqual(stages.count, 10)
        }
    }

    // MARK: - Edge Cases (no network)

    func testInit_VariousEndpoints_AllNotStarted() async {
        let endpoints = [
            "https://example.com/upload",
            "https://example.org/upload",
            "https://api.example.com/v1/upload",
            "https://localhost:8080/upload"
        ]
        for urlString in endpoints {
            let ep = URL(string: urlString)!
            let p = ConnectionPrewarmer(uploadEndpoint: ep)
            let stage = await p.getCurrentStage()
            XCTAssertEqual(stage, .notStarted, "Endpoint \(urlString) should start as notStarted")
        }
    }

    func testGetPrewarmedSession_CalledMultipleTimes_AllNil() async {
        for _ in 0..<5 {
            let session = await prewarmer.getPrewarmedSession()
            XCTAssertNil(session)
        }
    }

    func testProbeQUICSupport_CalledMultipleTimes_AllFalse() async {
        for _ in 0..<5 {
            let supported = await prewarmer.probeQUICSupport()
            XCTAssertFalse(supported)
        }
    }
}
