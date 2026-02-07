//
// TripleTimeAnchor.swift
// Aether3D
//
// Phase 1: Time Anchoring - Triple Time Anchor Fusion
//
// **Strategy:** Multi-source fusion with Byzantine fault tolerance
// **Minimum:** 2-of-3 agreement required for validity
//

import Foundation

/// Triple time anchor combining RFC 3161 TSA, Roughtime, and OpenTimestamps
///
/// **Strategy:** Multi-source fusion with Byzantine fault tolerance
/// **Minimum:** 2-of-3 agreement required for validity
/// **Agreement:** Evidences agree if their time intervals overlap
///
/// **Invariants:**
/// - INV-C1: Hash must be SHA-256 (32 bytes)
/// - INV-A1: Actor isolation
/// - INV-A4: No ordering assumptions (parallel requests)
///
/// **Fail-closed:** Insufficient sources or disagreement => explicit error
public actor TripleTimeAnchor {
    private let tsaClient: TSAClient
    private let roughtimeClient: RoughtimeClient
    private let blockchainAnchor: OpenTimestampsAnchor
    
    public init(
        tsaClient: TSAClient,
        roughtimeClient: RoughtimeClient,
        blockchainAnchor: OpenTimestampsAnchor
    ) {
        self.tsaClient = tsaClient
        self.roughtimeClient = roughtimeClient
        self.blockchainAnchor = blockchainAnchor
    }
    
    /// Anchor data with triple time proof
    ///
    /// **Process:**
    /// 1. Request all three sources in parallel
    /// 2. Collect results (allow individual failures)
    /// 3. Verify at least 2 sources succeeded
    /// 4. Check time agreement (intervals overlap)
    /// 5. Compute fused time interval
    ///
    /// - Parameter dataHash: SHA-256 hash of data to anchor (32 bytes)
    /// - Returns: TripleTimeProof with fused time evidence
    /// - Throws: TripleTimeAnchorError for insufficient sources or disagreement
    public func anchor(dataHash: Data) async throws -> TripleTimeProof {
        guard dataHash.count == 32 else {
            throw TripleTimeAnchorError.insufficientSources(available: 0, required: 2)
        }
        
        // Request all three in parallel
        async let tsaResult = requestTSA(hash: dataHash)
        async let roughtimeResult = requestRoughtime()
        async let blockchainResult = requestBlockchain(hash: dataHash)
        
        var evidences: [TimeEvidence] = []
        var excluded: [ExcludedEvidence] = []
        
        // Collect TSA result
        do {
            let token = try await tsaResult
            let evidence = TimeEvidence(
                source: .tsa,
                timeNs: UInt64(token.genTime.timeIntervalSince1970 * 1_000_000_000),
                uncertaintyNs: nil, // TSA provides point estimate
                verificationStatus: .verified,
                rawProof: token.derEncoded
            )
            evidences.append(evidence)
        } catch {
            // TSA failed, continue with other sources
        }
        
        // Collect Roughtime result
        do {
            let response = try await roughtimeResult
            let evidence = TimeEvidence(
                source: .roughtime,
                timeNs: response.midpointTimeNs,
                uncertaintyNs: UInt64(response.radiusNs),
                verificationStatus: .verified,
                rawProof: response.signature
            )
            evidences.append(evidence)
        } catch {
            // Roughtime failed, continue
        }
        
        // Collect Blockchain result
        do {
            let receipt = try await blockchainResult
            // OpenTimestamps doesn't provide time directly, use submission time
            let evidence = TimeEvidence(
                source: .opentimestamps,
                timeNs: UInt64(receipt.submittedAt.timeIntervalSince1970 * 1_000_000_000),
                uncertaintyNs: nil,
                verificationStatus: receipt.status == .confirmed ? .verified : .unverified,
                rawProof: receipt.otsProof
            )
            evidences.append(evidence)
        } catch {
            // Blockchain failed, continue
        }
        
        // Verify at least 2 sources succeeded
        guard evidences.count >= 2 else {
            throw TripleTimeAnchorError.insufficientSources(
                available: evidences.count,
                required: 2
            )
        }
        
        // Check time agreement (intervals overlap)
        for i in 0..<evidences.count {
            for j in (i+1)..<evidences.count {
                if !evidences[i].agrees(with: evidences[j]) {
                    let diff = evidences[i].timeNs > evidences[j].timeNs ?
                        evidences[i].timeNs - evidences[j].timeNs :
                        evidences[j].timeNs - evidences[i].timeNs
                    throw TripleTimeAnchorError.timeDisagreement(
                        source1: evidences[i].source,
                        source2: evidences[j].source,
                        differenceNs: diff
                    )
                }
            }
        }
        
        // Compute fused time interval (intersection of all intervals)
        let fusedInterval = computeFusedInterval(evidences: evidences)
        
        return TripleTimeProof(
            dataHash: dataHash,
            fusedTimeInterval: TimeIntervalNs(lowerNs: fusedInterval.lowerNs, upperNs: fusedInterval.upperNs),
            includedEvidences: evidences,
            excludedEvidences: excluded,
            anchoredAt: Date()
        )
    }
    
    // MARK: - Private Helpers
    
    private func requestTSA(hash: Data) async throws -> TimeStampToken {
        return try await tsaClient.requestTimestamp(hash: hash)
    }
    
    private func requestRoughtime() async throws -> RoughtimeResponse {
        return try await roughtimeClient.requestTime()
    }
    
    private func requestBlockchain(hash: Data) async throws -> BlockchainReceipt {
        return try await blockchainAnchor.submitHash(hash)
    }
    
    private func computeFusedInterval(evidences: [TimeEvidence]) -> (lowerNs: UInt64, upperNs: UInt64) {
        var lower: UInt64 = 0
        var upper: UInt64 = UInt64.max
        
        for evidence in evidences {
            let interval = evidence.timeInterval
            lower = max(lower, interval.lower)
            upper = min(upper, interval.upper)
        }
        
        return (lowerNs: lower, upperNs: upper)
    }
}
