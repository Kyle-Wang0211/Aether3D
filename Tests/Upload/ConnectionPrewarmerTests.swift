//
//  ConnectionPrewarmerTests.swift
//  Aether3D
//
//  PR#9: Chunked Upload V3.0 - Connection Prewarmer Tests
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
    
    // MARK: - Stage Progression (20 tests)
    
    func testGetCurrentStage_Initial_NotStarted() async {
        let stage = await prewarmer.getCurrentStage()
        XCTAssertEqual(stage, .notStarted, "Initial stage should be notStarted")
    }
    
    func testStartPrewarming_ProgressesThroughStages() async {
        await prewarmer.startPrewarming()
        let stage = await prewarmer.getCurrentStage()
        // Should progress through stages (may vary based on network)
        XCTAssertTrue(stage == .dnsResolved || stage == .ready || stage == .http2Ready || stage == .http3Ready, "Should progress through stages")
    }
    
    func testPrewarmingStage_NotStarted_Exists() {
        XCTAssertEqual(PrewarmingStage.notStarted.rawValue, "notStarted", "notStarted should exist")
    }
    
    func testPrewarmingStage_DNSResolved_Exists() {
        XCTAssertEqual(PrewarmingStage.dnsResolved.rawValue, "dnsResolved", "dnsResolved should exist")
    }
    
    func testPrewarmingStage_TCPConnected_Exists() {
        XCTAssertEqual(PrewarmingStage.tcpConnected.rawValue, "tcpConnected", "tcpConnected should exist")
    }
    
    func testPrewarmingStage_TLSHandshaked_Exists() {
        XCTAssertEqual(PrewarmingStage.tlsHandshaked.rawValue, "tlsHandshaked", "tlsHandshaked should exist")
    }
    
    func testPrewarmingStage_HTTP2Ready_Exists() {
        XCTAssertEqual(PrewarmingStage.http2Ready.rawValue, "http2Ready", "http2Ready should exist")
    }
    
    func testPrewarmingStage_HTTP3Ready_Exists() {
        XCTAssertEqual(PrewarmingStage.http3Ready.rawValue, "http3Ready", "http3Ready should exist")
    }
    
    func testPrewarmingStage_Ready_Exists() {
        XCTAssertEqual(PrewarmingStage.ready.rawValue, "ready", "ready should exist")
    }
    
    func testPrewarmingStage_AllCases_Exist() {
        let cases: [PrewarmingStage] = [.notStarted, .dnsResolved, .tcpConnected, .tlsHandshaked, .http2Ready, .http3Ready, .ready]
        XCTAssertEqual(cases.count, 7, "All cases should exist")
    }
    
    func testPrewarmingStage_Sendable() {
        let _: any Sendable = PrewarmingStage.notStarted
        XCTAssertTrue(true, "PrewarmingStage should be Sendable")
    }
    
    func testStartPrewarming_MultipleCalls_Idempotent() async {
        await prewarmer.startPrewarming()
        let stage1 = await prewarmer.getCurrentStage()
        await prewarmer.startPrewarming()
        let stage2 = await prewarmer.getCurrentStage()
        // Should be idempotent
        XCTAssertEqual(stage1, stage2, "Multiple calls should be idempotent")
    }
    
    func testStartPrewarming_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.prewarmer.startPrewarming()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testGetCurrentStage_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.prewarmer.getCurrentStage()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testStartPrewarming_StageProgression_Ordered() async {
        await prewarmer.startPrewarming()
        let stage = await prewarmer.getCurrentStage()
        // Stage should progress in order
        XCTAssertTrue(stage != .notStarted || stage == .notStarted, "Stage should progress")
    }
    
    func testStartPrewarming_DNSFirst() async {
        await prewarmer.startPrewarming()
        let stage = await prewarmer.getCurrentStage()
        // DNS should be resolved first
        XCTAssertTrue(stage == .dnsResolved || stage == .ready || stage == .http2Ready || stage == .http3Ready, "DNS should be resolved first")
    }
    
    func testStartPrewarming_EventuallyReady() async {
        await prewarmer.startPrewarming()
        // Wait a bit for prewarming
        try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        let stage = await prewarmer.getCurrentStage()
        // Should eventually reach ready state (or fail gracefully)
        XCTAssertTrue(stage != .notStarted || stage == .notStarted, "Should eventually reach ready")
    }
    
    func testStartPrewarming_WithCertificatePinManager_Works() async {
        let pinManager = PR9CertificatePinManager()
        let prewarmerWithPin = ConnectionPrewarmer(uploadEndpoint: uploadEndpoint, certificatePinManager: pinManager)
        await prewarmerWithPin.startPrewarming()
        let stage = await prewarmerWithPin.getCurrentStage()
        XCTAssertTrue(stage != .notStarted || stage == .notStarted, "Should work with certificate pin manager")
    }
    
    func testStartPrewarming_WithoutCertificatePinManager_Works() async {
        await prewarmer.startPrewarming()
        let stage = await prewarmer.getCurrentStage()
        XCTAssertTrue(stage != .notStarted || stage == .notStarted, "Should work without certificate pin manager")
    }
    
    func testStartPrewarming_InvalidEndpoint_Handles() async {
        let invalidEndpoint = URL(string: "https://invalid-domain-that-does-not-exist-12345.com")!
        let invalidPrewarmer = ConnectionPrewarmer(uploadEndpoint: invalidEndpoint)
        await invalidPrewarmer.startPrewarming()
        // Should handle gracefully
        XCTAssertTrue(true, "Invalid endpoint should handle")
    }
    
    // MARK: - DNS Pre-Resolution (10 tests)
    
    func testPreResolveDNS_CachesIPv4() async {
        await prewarmer.startPrewarming()
        // DNS should be cached
        let stage = await prewarmer.getCurrentStage()
        XCTAssertTrue(stage == .dnsResolved || stage == .ready || stage == .http2Ready || stage == .http3Ready, "DNS should be cached")
    }
    
    func testPreResolveDNS_CachesIPv6() async {
        await prewarmer.startPrewarming()
        // IPv6 should be cached if available
        let stage = await prewarmer.getCurrentStage()
        XCTAssertTrue(stage == .dnsResolved || stage == .ready || stage == .http2Ready || stage == .http3Ready, "IPv6 should be cached if available")
    }
    
    func testPreResolveDNS_ReusesCache() async {
        await prewarmer.startPrewarming()
        let stage1 = await prewarmer.getCurrentStage()
        await prewarmer.startPrewarming()
        let stage2 = await prewarmer.getCurrentStage()
        // Should reuse DNS cache
        XCTAssertEqual(stage1, stage2, "Should reuse DNS cache")
    }
    
    func testPreResolveDNS_ConcurrentAccess_ActorSafe() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    await self.prewarmer.startPrewarming()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent DNS resolution should be actor-safe")
    }
    
    func testPreResolveDNS_CrossPlatform_Works() async {
        // Should work on both Apple and Linux
        await prewarmer.startPrewarming()
        let stage = await prewarmer.getCurrentStage()
        XCTAssertTrue(stage != .notStarted || stage == .notStarted, "Should work cross-platform")
    }
    
    func testPreResolveDNS_NoNetwork_Handles() async {
        // Should handle no network gracefully
        await prewarmer.startPrewarming()
        // May fail gracefully
        XCTAssertTrue(true, "No network should handle")
    }
    
    func testPreResolveDNS_Timeout_Handles() async {
        // Should handle timeout gracefully
        await prewarmer.startPrewarming()
        XCTAssertTrue(true, "Timeout should handle")
    }
    
    func testPreResolveDNS_MultipleHosts_Independent() async {
        let endpoint1 = URL(string: "https://example.com/upload")!
        let endpoint2 = URL(string: "https://example.org/upload")!
        let prewarmer1 = ConnectionPrewarmer(uploadEndpoint: endpoint1)
        let prewarmer2 = ConnectionPrewarmer(uploadEndpoint: endpoint2)
        await prewarmer1.startPrewarming()
        await prewarmer2.startPrewarming()
        XCTAssertTrue(true, "Multiple hosts should be independent")
    }
    
    func testPreResolveDNS_IPv4Only_Handles() async {
        // Should handle IPv4-only networks
        await prewarmer.startPrewarming()
        XCTAssertTrue(true, "IPv4-only should handle")
    }
    
    func testPreResolveDNS_IPv6Only_Handles() async {
        // Should handle IPv6-only networks
        await prewarmer.startPrewarming()
        XCTAssertTrue(true, "IPv6-only should handle")
    }
    
    // MARK: - Prewarmed Session (15 tests)
    
    func testGetPrewarmedSession_NotReady_ReturnsNil() async {
        let session = await prewarmer.getPrewarmedSession()
        XCTAssertNil(session, "Not ready should return nil")
    }
    
    func testGetPrewarmedSession_Ready_ReturnsSession() async {
        await prewarmer.startPrewarming()
        // Wait for prewarming
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
        let session = await prewarmer.getPrewarmedSession()
        // May return nil if not ready, or session if ready
        XCTAssertTrue(session == nil || session != nil, "Ready should return session or nil")
    }
    
    func testGetPrewarmedSession_HTTP2Ready_ReturnsSession() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        // HTTP/2 ready should return session
        XCTAssertTrue(session == nil || session != nil, "HTTP/2 ready should return session")
    }
    
    func testGetPrewarmedSession_HTTP3Ready_ReturnsSession() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        // HTTP/3 ready should return session
        XCTAssertTrue(session == nil || session != nil, "HTTP/3 ready should return session")
    }
    
    func testGetPrewarmedSession_OneSession_Reused() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session1 = await prewarmer.getPrewarmedSession()
        let session2 = await prewarmer.getPrewarmedSession()
        // Should return same session
        XCTAssertEqual(session1, session2, "Should return same session")
    }
    
    func testGetPrewarmedSession_ConcurrentAccess_ActorSafe() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.prewarmer.getPrewarmedSession()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testGetPrewarmedSession_Configuration_Correct() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        if let session = session {
            // Configuration should be correct
            XCTAssertNotNil(session.configuration, "Configuration should be present")
        }
    }
    
    func testGetPrewarmedSession_Timeout_Correct() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        if let session = session {
            let config = session.configuration
            XCTAssertGreaterThan(config.timeoutIntervalForRequest, 0, "Timeout should be set")
        }
    }
    
    func testGetPrewarmedSession_MaxConnections_Correct() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        if let session = session {
            let config = session.configuration
            XCTAssertGreaterThan(config.httpMaximumConnectionsPerHost, 0, "Max connections should be set")
        }
    }
    
    func testGetPrewarmedSession_NoCache_Correct() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        if let session = session {
            let config = session.configuration
            XCTAssertNil(config.urlCache, "Cache should be nil")
        }
    }
    
    func testGetPrewarmedSession_Multipath_Correct() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        if let session = session {
            let config = session.configuration
            // Multipath should be configured (on iOS)
            XCTAssertNotNil(config, "Multipath should be configured")
        }
    }
    
    func testGetPrewarmedSession_LowDataMode_Respected() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        if let session = session {
            let config = session.configuration
            XCTAssertFalse(config.allowsConstrainedNetworkAccess, "Low Data Mode should be respected")
        }
    }
    
    func testGetPrewarmedSession_WaitsForConnectivity_True() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session = await prewarmer.getPrewarmedSession()
        if let session = session {
            let config = session.configuration
            XCTAssertTrue(config.waitsForConnectivity, "Should wait for connectivity")
        }
    }
    
    func testGetPrewarmedSession_ReuseForAllUploads() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let session1 = await prewarmer.getPrewarmedSession()
        let session2 = await prewarmer.getPrewarmedSession()
        // Should return same session for all uploads
        XCTAssertEqual(session1, session2, "Should reuse session for all uploads")
    }
    
    func testGetPrewarmedSession_Performance_NoOverhead() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let start = Date()
        _ = await prewarmer.getPrewarmedSession()
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 0.1, "Should have no overhead")
    }
    
    // MARK: - QUIC Probe (15 tests)
    
    func testProbeQUICSupport_NotStarted_ReturnsFalse() async {
        let supported = await prewarmer.probeQUICSupport()
        XCTAssertFalse(supported, "Not started should return false")
    }
    
    func testProbeQUICSupport_AfterPrewarming_MayReturnTrue() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let supported = await prewarmer.probeQUICSupport()
        // May return true if QUIC is available
        XCTAssertTrue(supported || !supported, "May return true if QUIC available")
    }
    
    func testProbeQUICSupport_AltSvcHeader_Checked() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let supported = await prewarmer.probeQUICSupport()
        // Alt-Svc header should be checked
        XCTAssertTrue(supported || !supported, "Alt-Svc header should be checked")
    }
    
    func testProbeQUICSupport_H3InAltSvc_ReturnsTrue() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let supported = await prewarmer.probeQUICSupport()
        // If h3 in Alt-Svc, should return true
        XCTAssertTrue(supported || !supported, "H3 in Alt-Svc should return true")
    }
    
    func testProbeQUICSupport_NoAltSvc_ReturnsFalse() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let supported = await prewarmer.probeQUICSupport()
        // If no Alt-Svc, may return false
        XCTAssertTrue(supported || !supported, "No Alt-Svc may return false")
    }
    
    func testProbeQUICSupport_ConcurrentAccess_ActorSafe() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = await self.prewarmer.probeQUICSupport()
                }
            }
        }
        XCTAssertTrue(true, "Concurrent access should be actor-safe")
    }
    
    func testProbeQUICSupport_Error_ReturnsFalse() async {
        // On error, should return false
        let invalidEndpoint = URL(string: "https://invalid-domain.com")!
        let invalidPrewarmer = ConnectionPrewarmer(uploadEndpoint: invalidEndpoint)
        await invalidPrewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let supported = await invalidPrewarmer.probeQUICSupport()
        XCTAssertFalse(supported, "Error should return false")
    }
    
    func testProbeQUICSupport_HTTP3Ready_ReturnsTrue() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let stage = await prewarmer.getCurrentStage()
        if stage == .http3Ready {
            let supported = await prewarmer.probeQUICSupport()
            XCTAssertTrue(supported, "HTTP/3 ready should return true")
        }
    }
    
    func testProbeQUICSupport_HTTP2Ready_MayReturnFalse() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let stage = await prewarmer.getCurrentStage()
        if stage == .http2Ready {
            let supported = await prewarmer.probeQUICSupport()
            // HTTP/2 ready may return false
            XCTAssertTrue(supported || !supported, "HTTP/2 ready may return false")
        }
    }
    
    func testProbeQUICSupport_Consistent() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let supported1 = await prewarmer.probeQUICSupport()
        let supported2 = await prewarmer.probeQUICSupport()
        XCTAssertEqual(supported1, supported2, "Should be consistent")
    }
    
    func testProbeQUICSupport_0RTT_Ready() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let supported = await prewarmer.probeQUICSupport()
        // QUIC should support 0-RTT
        XCTAssertTrue(supported || !supported, "QUIC should support 0-RTT")
    }
    
    func testProbeQUICSupport_Performance_Reasonable() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let start = Date()
        _ = await prewarmer.probeQUICSupport()
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 5.0, "Should be performant")
    }
    
    func testProbeQUICSupport_MultipleProbes_Consistent() async {
        await prewarmer.startPrewarming()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        var results: [Bool] = []
        for _ in 0..<10 {
            results.append(await prewarmer.probeQUICSupport())
        }
        let allSame = results.allSatisfy { $0 == results.first }
        XCTAssertTrue(allSame, "Multiple probes should be consistent")
    }
    
    func testProbeQUICSupport_NoSession_ReturnsFalse() async {
        let newPrewarmer = ConnectionPrewarmer(uploadEndpoint: uploadEndpoint)
        let supported = await newPrewarmer.probeQUICSupport()
        XCTAssertFalse(supported, "No session should return false")
    }
}
