# File Skeletons for Aether3D v6.1.1

**⚠️ NO IMPLEMENTATION CODE ⚠️**

This document lists all files to be created/modified with public interface signatures (names only). No implementation bodies, no test code, no algorithms.

**Status**: Pre-Implementation  
**Last Updated**: 2026-02-06

---

## Files to Create

### Phase 1: Time Anchoring

#### Core/TimeAnchoring/TSAError.swift
**Public Types**:
- `enum TSAError: Error, Sendable`
  - Cases: `invalidHashLength`, `httpError`, `tsaRejected`, `invalidResponse`, `verificationFailed`, `timeout`, `asn1Error`, `certificateChainInvalid`, `policyOIDMismatch`, `nonceMismatch`, `signatureInvalid`

#### Core/TimeAnchoring/TimeStampToken.swift
**Public Types**:
- `struct TimeStampToken: Codable, Sendable`
  - Properties: `genTime`, `messageImprint`, `serialNumber`, `tsaName`, `policyOID`, `nonce`, `derEncoded`, `certificateChain`, `verificationStatus`
  - Methods: `verify(hash:) -> Bool`
- `struct MessageImprint: Codable, Sendable`
  - Properties: `algorithmOID`, `digest`
  - Methods: `matches(hash:) -> Bool`
- `enum VerificationStatus: Codable, Sendable`
  - Cases: `verified`, `unverified`, `failed`

#### Core/TimeAnchoring/ASN1Builder.swift
**Public Types**:
- `struct ASN1Builder` (internal, no public API)
  - Methods: `beginSequence()`, `endSequence()`, `appendInteger(_:)`, `appendOctetString(_:)`, `appendAlgorithmIdentifier(oid:)`, `appendBoolean(_:)`, `build() -> Data`

#### Core/TimeAnchoring/TSAClient.swift
**Public Types**:
- `actor TSAClient`
  - Properties: `serverURL`, `timeout`
  - Methods: `init(serverURL:timeout:)`, `requestTimestamp(hash:) async throws -> TimeStampToken`, `verifyTimestamp(_:hash:) async throws -> Bool`

#### Core/TimeAnchoring/RoughtimeError.swift
**Public Types**:
- `enum RoughtimeError: Error, Sendable`
  - Cases: `invalidPublicKey`, `signatureVerificationFailed`, `invalidResponse`, `networkError`, `timeout`, `radiusTooLarge`, `unknownKeyId`, `keyExpired`

#### Core/TimeAnchoring/RoughtimeResponse.swift
**Public Types**:
- `struct RoughtimeResponse: Codable, Sendable`
  - Properties: `midpointTimeNs`, `radiusNs`, `nonce`, `signature`, `serverPublicKeyId`, `verificationStatus`
  - Computed: `timeInterval -> (lower:upper:)`

#### Core/TimeAnchoring/PublicKeyInfo.swift
**Public Types**:
- `struct PublicKeyInfo: Codable, Sendable`
  - Properties: `keyId`, `publicKey`, `validFrom`, `validUntil`

#### Core/TimeAnchoring/RoughtimeClient.swift
**Public Types**:
- `actor RoughtimeClient`
  - Properties: `serverHost`, `serverPort`, `serverPublicKeys`, `timeout`
  - Static: `cloudflareHost`, `cloudflarePort`, `cloudflarePublicKeys`
  - Methods: `init(serverHost:serverPort:serverPublicKeys:timeout:)`, `requestTime() async throws -> RoughtimeResponse`

#### Core/TimeAnchoring/BlockchainAnchorError.swift
**Public Types**:
- `enum BlockchainAnchorError: Error, Sendable`
  - Cases: `invalidHashLength`, `submissionFailed`, `upgradeTimeout`, `invalidReceipt`, `networkError`, `idempotencyConflict`

#### Core/TimeAnchoring/BlockchainReceipt.swift
**Public Types**:
- `struct BlockchainReceipt: Codable, Sendable`
  - Properties: `hash`, `otsProof`, `submittedAt`, `status`, `bitcoinBlockHeight`, `bitcoinTxId`, `verificationStatus`
- `enum AnchorStatus: Codable, Sendable`
  - Cases: `pending`, `confirmed`, `failed`

#### Core/TimeAnchoring/OpenTimestampsAnchor.swift
**Public Types**:
- `actor OpenTimestampsAnchor`
  - Properties: `calendarURL`, `timeout`, `maxUpgradeAttempts`, `upgradeBackoffBase`
  - Methods: `init(calendarURL:timeout:maxUpgradeAttempts:upgradeBackoffBase:)`, `submitHash(_:) async throws -> BlockchainReceipt`, `upgradeReceipt(_:) async throws -> BlockchainReceipt`

#### Core/TimeAnchoring/TimeEvidence.swift
**Public Types**:
- `struct TimeEvidence: Codable, Sendable`
  - Properties: `source`, `timeNs`, `uncertaintyNs`, `verificationStatus`, `rawProof`
  - Computed: `timeInterval -> (lower:upper:)`
  - Methods: `agrees(with:) -> Bool`
- `enum Source: Codable, Sendable`
  - Cases: `tsa`, `roughtime`, `opentimestamps`

#### Core/TimeAnchoring/TimeIntervalNs.swift
**Public Types**:
- `struct TimeIntervalNs: Codable, Sendable`
  - Properties: `lowerNs`, `upperNs`
  - Methods: `init(lowerNs:upperNs:)`

#### Core/TimeAnchoring/ExcludedEvidence.swift
**Public Types**:
- `struct ExcludedEvidence: Codable, Sendable`
  - Properties: `evidence`, `reason`
  - Methods: `init(evidence:reason:)`

#### Core/TimeAnchoring/TripleTimeProof.swift
**Public Types**:
- `struct TripleTimeProof: Codable, Sendable`
  - Properties: `dataHash`, `fusedTimeInterval`, `includedEvidences`, `excludedEvidences`, `anchoredAt`
  - Computed: `evidenceCount -> Int`, `isValid -> Bool`

#### Core/TimeAnchoring/TripleTimeAnchorError.swift
**Public Types**:
- `enum TripleTimeAnchorError: Error, Sendable`
  - Cases: `insufficientSources`, `timeDisagreement`, `allSourcesFailed`, `intervalIntersectionEmpty`

#### Core/TimeAnchoring/TripleTimeAnchor.swift
**Public Types**:
- `actor TripleTimeAnchor`
  - Properties: `tsaClient`, `roughtimeClient`, `blockchainAnchor`
  - Methods: `init(tsaClient:roughtimeClient:blockchainAnchor:)`, `anchor(dataHash:) async throws -> TripleTimeProof`

### Phase 1.5: Crash Consistency

#### Core/TimeAnchoring/WriteAheadLog.swift
**Public Types**:
- `actor WriteAheadLog`
  - Properties: `walFileURL`, `durabilityLevel`
  - Methods: `init(walFileURL:durabilityLevel:)`, `appendEntry(hash:signedEntryBytes:merkleState:) async throws`, `commitEntry(_:) async throws`, `recover() async throws -> [WALEntry]`, `getUncommittedEntries() async throws -> [WALEntry]`

#### Core/TimeAnchoring/WALEntry.swift
**Public Types**:
- `struct WALEntry: Codable, Sendable`
  - Properties: `entryId`, `hash`, `signedEntryBytes`, `merkleState`, `committed`, `timestamp`
- `typealias EntryId = UInt64`

#### Core/TimeAnchoring/DurabilityLevel.swift
**Public Types**:
- `enum DurabilityLevel: Codable, Sendable`
  - Cases: `dataProtectionComplete`, `dataProtectionCompleteUnlessOpen`, `dataProtectionCompleteUntilFirstUserAuthentication`, `transactional`

#### Core/TimeAnchoring/WALError.swift
**Public Types**:
- `enum WALError: Error, Sendable`
  - Cases: `ioError`, `corruptedEntry`, `recoveryFailed`, `durabilityLevelNotSupported`, `entryNotFound`

#### Core/TimeAnchoring/WALStorage.swift
**Public Types**:
- `protocol WALStorage`
  - Methods: `writeEntry(_:) async throws`, `readEntries() async throws -> [WALEntry]`, `fsync() async throws`, `close() async throws`

#### Core/TimeAnchoring/FileWALStorage.swift
**Public Types**:
- `struct FileWALStorage: WALStorage`
  - Methods: `init(fileURL:durabilityLevel:)`, `writeEntry(_:) async throws`, `readEntries() async throws -> [WALEntry]`, `fsync() async throws`, `close() async throws`

#### Core/TimeAnchoring/SQLiteWALStorage.swift
**Public Types**:
- `struct SQLiteWALStorage: WALStorage`
  - Methods: `init(databaseURL:)`, `writeEntry(_:) async throws`, `readEntries() async throws -> [WALEntry]`, `fsync() async throws`, `close() async throws`

### Phase 2: Merkle Tree

#### Core/MerkleTree/MerkleTreeError.swift
**Public Types**:
- `enum MerkleTreeError: Error, Sendable`
  - Cases: `invalidLeafIndex`, `invalidTreeSize`, `proofVerificationFailed`, `invalidHashLength`, `tileStoreError`, `signingFailed`

#### Core/MerkleTree/MerkleTreeHash.swift
**Public Types**:
- `enum MerkleTreeHash` (no cases, static methods)
  - Static: `leafPrefix: UInt8`, `nodePrefix: UInt8`
  - Static Methods: `hashLeaf(_:) -> Data`, `hashNodes(_:_:) -> Data`, `hashEmpty() -> Data`

#### Core/MerkleTree/TileAddress.swift
**Public Types**:
- `struct TileAddress: Codable, Sendable, Hashable`
  - Properties: `level`, `index`
  - Methods: `init(level:index:)`

#### Core/MerkleTree/TileStore.swift
**Public Types**:
- `protocol TileStore`
  - Methods: `getTile(_:) async throws -> Data?`, `putTile(_:data:) async throws`

#### Core/MerkleTree/InMemoryTileStore.swift
**Public Types**:
- `actor InMemoryTileStore: TileStore`
  - Methods: `init()`, `getTile(_:) async throws -> Data?`, `putTile(_:data:) async throws`

#### Core/MerkleTree/FileTileStore.swift
**Public Types**:
- `actor FileTileStore: TileStore`
  - Methods: `init(baseDirectory:)`, `getTile(_:) async throws -> Data?`, `putTile(_:data:) async throws`

#### Core/MerkleTree/MerkleTree.swift
**Public Types**:
- `actor MerkleTree`
  - Properties: `size`, `rootHash`
  - Methods: `init(tileStore:)`, `append(_:) async throws`, `appendHash(_:) async throws`, `generateInclusionProof(leafIndex:) async throws -> InclusionProof`, `generateConsistencyProof(firstSize:secondSize:) async throws -> ConsistencyProof`

#### Core/MerkleTree/InclusionProof.swift
**Public Types**:
- `struct InclusionProof: Codable, Sendable`
  - Properties: `treeSize`, `leafIndex`, `path`
  - Methods: `verify(leafHash:rootHash:) -> Bool`

#### Core/MerkleTree/ConsistencyProof.swift
**Public Types**:
- `struct ConsistencyProof: Codable, Sendable`
  - Properties: `firstTreeSize`, `secondTreeSize`, `path`
  - Methods: `verify(firstRoot:secondRoot:) -> Bool`

#### Core/MerkleTree/SignedTreeHead.swift
**Public Types**:
- `struct SignedTreeHead: Codable, Sendable`
  - Properties: `treeSize`, `rootHash`, `timestampNanos`, `signature`, `logId`, `logParamsHash`
  - Static Methods: `sign(treeSize:rootHash:timestampNanos:privateKey:) throws -> SignedTreeHead`
  - Methods: `verify(publicKey:) -> Bool`

#### Core/MerkleTree/MerkleAuditLog.swift
**Public Types**:
- `actor MerkleAuditLog`
  - Properties: `size`, `rootHash`
  - Methods: `init(signedAuditLog:merkleTree:wal:tripleTimeAnchor:)`, `append(_:) async throws -> EntryId`, `generateInclusionProof(entryIndex:) async throws -> InclusionProof`, `getSignedTreeHead(privateKey:) async throws -> SignedTreeHead`

#### Core/MerkleTree/MerkleAuditLogError.swift
**Public Types**:
- `enum MerkleAuditLogError: Error, Sendable`
  - Cases: `walWriteFailed`, `signedLogAppendFailed`, `merkleTreeAppendFailed`, `recoveryFailed`, `invalidEntryIndex`

### Phase 3: Device Attestation

#### Core/DeviceAttestation/AppAttestError.swift
**Public Types**:
- `enum AppAttestError: Error, Sendable`
  - Cases: `notSupported`, `keyGeneration`, `attestation`, `assertion`, `invalidClientDataHash`, `unknownError`

#### Core/DeviceAttestation/DCAppAttestServiceProtocol.swift
**Public Types**:
- `protocol DCAppAttestServiceProtocol`
  - Properties: `isSupported: Bool`
  - Methods: `generateKey(completionHandler:)`, `attestKey(_:clientDataHash:completionHandler:)`, `generateAssertion(_:clientDataHash:completionHandler:)`

#### Core/DeviceAttestation/DCAppAttestServiceWrapper.swift
**Public Types**:
- `struct DCAppAttestServiceWrapper: DCAppAttestServiceProtocol`
  - Methods: `init(service:)`, `isSupported -> Bool`, `generateKey(completionHandler:)`, `attestKey(_:clientDataHash:completionHandler:)`, `generateAssertion(_:clientDataHash:completionHandler:)`

#### Core/DeviceAttestation/AppAttestClient.swift
**Public Types**:
- `actor AppAttestClient`
  - Properties: `isSupported`
  - Methods: `init(service:)`, `generateKey() async throws -> String`, `attestKey(keyId:clientDataHash:) async throws -> Data`, `generateAssertion(keyId:clientDataHash:) async throws -> Data`

#### Core/DeviceAttestation/AttestationResult.swift
**Public Types**:
- `struct AttestationResult: Codable, Sendable`
  - Properties: `attestationObject`, `certificateChain`, `keyId`, `riskMetric`, `counter`, `verificationStatus`

#### Core/DeviceAttestation/AttestationVerifierError.swift
**Public Types**:
- `enum AttestationVerifierError: Error, Sendable`
  - Cases: `invalidCBOR`, `certificateChainInvalid`, `signatureInvalid`, `counterRollback`, `keyNotRegistered`, `invalidChallenge`

#### Core/DeviceAttestation/AttestationVerifier.swift
**Public Types**:
- `struct AttestationVerifier`
  - Methods: `init(counterStore:)`, `verify(attestationObject:clientDataHash:expectedChallenge:) throws -> AttestationResult`

#### Core/DeviceAttestation/CounterStore.swift
**Public Types**:
- `protocol CounterStore`
  - Methods: `getCounter(keyId:) async throws -> UInt32?`, `setCounter(keyId:counter:) async throws`, `registerKey(keyId:deviceBinding:firstSeen:) async throws`

#### Core/DeviceAttestation/InMemoryCounterStore.swift
**Public Types**:
- `actor InMemoryCounterStore: CounterStore`
  - Methods: `init()`, `getCounter(keyId:) async throws -> UInt32?`, `setCounter(keyId:counter:) async throws`, `registerKey(keyId:deviceBinding:firstSeen:) async throws`

#### Core/DeviceAttestation/SQLiteCounterStore.swift
**Public Types**:
- `actor SQLiteCounterStore: CounterStore`
  - Methods: `init(databaseURL:)`, `getCounter(keyId:) async throws -> UInt32?`, `setCounter(keyId:counter:) async throws`, `registerKey(keyId:deviceBinding:firstSeen:) async throws`

### Phase 4: Deterministic Replay

#### Core/Replay/DeterministicSchedulerError.swift
**Public Types**:
- `enum DeterministicSchedulerError: Error, Sendable`
  - Cases: `invalidSeed`, `taskExecutionFailed`

#### Core/Replay/SplitMix64.swift
**Public Types**:
- `struct SplitMix64` (internal, no public API)
  - Properties: `state`
  - Methods: `init(seed:)`, `next() -> UInt64`

#### Core/Replay/TaskHandle.swift
**Public Types**:
- `struct TaskHandle: Sendable`
  - Properties: `id`

#### Core/Replay/DeterministicScheduler.swift
**Public Types**:
- `actor DeterministicScheduler`
  - Properties: `currentTimeNs`, `seed`
  - Methods: `init(seed:)`, `schedule(at:task:) -> TaskHandle`, `advance(by:) async`, `runUntilIdle() async`, `random() -> UInt64`, `random(in:) -> UInt64`

#### Core/Replay/TimeSource.swift
**Public Types**:
- `protocol TimeSource`
  - Methods: `nowMs() async -> Int64`

#### Core/Replay/MockTimeSource.swift
**Public Types**:
- `struct MockTimeSource: TimeSource, Sendable`
  - Methods: `init(scheduler:)`, `nowMs() async -> Int64`

#### Core/Replay/SystemTimeSource.swift
**Public Types**:
- `struct SystemTimeSource: TimeSource, Sendable`
  - Methods: `init()`, `nowMs() async -> Int64`

#### Core/Replay/TimeSourceError.swift
**Public Types**:
- `enum TimeSourceError: Error, Sendable`
  - Cases: `schedulerNotAvailable`, `timeRetrievalFailed`

#### Core/Replay/FaultInjectorError.swift
**Public Types**:
- `enum FaultInjectorError: Error, Sendable`
  - Cases: `invalidProbability`, `invalidDuration`

#### Core/Replay/FaultInjector.swift
**Public Types**:
- `actor FaultInjector`
  - Methods: `init(scheduler:)`, `injectNetworkPartition(between:and:durationNs:)`, `canCommunicate(_:_:) -> Bool`, `setDiskErrorProbability(_:)`, `shouldDiskOperationFail() async -> Bool`, `setClockSkew(ns:)`, `getSkewedTimeNs() async -> UInt64`

### Phase 5: Format Bridge

#### Core/FormatBridge/ProvenanceBundleError.swift
**Public Types**:
- `enum ProvenanceBundleError: Error, Sendable`
  - Cases: `encodingFailed`, `invalidSchema`, `missingRequiredField`

#### Core/FormatBridge/ExportFormat.swift
**Public Types**:
- `enum ExportFormat: Codable, Sendable`
  - Cases: `gltf`, `usd`, `tiles3d`, `e57`, `gltfGaussianSplatting`

#### Core/FormatBridge/ProvenanceManifest.swift
**Public Types**:
- `struct ProvenanceManifest: Codable, Sendable`
  - Properties: `format`, `version`, `exportedAt`, `exporterVersion`

#### Core/FormatBridge/DeviceAttestationStatus.swift
**Public Types**:
- `struct DeviceAttestationStatus: Codable, Sendable`
  - Properties: `keyId`, `riskMetric`, `counter`, `status`

#### Core/FormatBridge/ProvenanceBundle.swift
**Public Types**:
- `struct ProvenanceBundle: Codable, Sendable`
  - Properties: `manifest`, `sth`, `timeProof`, `merkleProof`, `deviceAttestation`
  - Methods: `encode() throws -> Data`, `hash() throws -> Data`

#### Core/FormatBridge/GLTFExportOptions.swift
**Public Types**:
- `struct GLTFExportOptions`
  - Properties: `enableQuantization`, `enableDraco`, `embedTextures`, `quantizationBits`

#### Core/FormatBridge/GLTFExporterError.swift
**Public Types**:
- `enum GLTFExporterError: Error, Sendable`
  - Cases: `invalidMeshData`, `encodingFailed`, `validationFailed`, `provenanceBundleError`

#### Core/FormatBridge/GLTFExporter.swift
**Public Types**:
- `struct GLTFExporter`
  - Methods: `init()`, `export(mesh:evidence:merkleProof:sth:timeProof:options:) throws -> Data`

#### Core/FormatBridge/FormatValidatorError.swift
**Public Types**:
- `enum FormatValidatorError: Error, Sendable`
  - Cases: `validatorNotFound`, `validationFailed`, `executionFailed`

#### Core/FormatBridge/ValidationResult.swift
**Public Types**:
- `struct ValidationResult`
  - Properties: `passed`, `errors`, `warnings`

#### Core/FormatBridge/FormatValidator.swift
**Public Types**:
- `struct FormatValidator`
  - Methods: `init(validatorPath:)`, `validate(fileURL:format:) throws -> ValidationResult`

---

## Files to Modify

### Core/Audit/SignedAuditLog.swift
**Modifications**: Line numbers TBD
- No public API changes (wrapped by MerkleAuditLog, not modified directly)
- May need to expose entry hash computation method if not already public

### Core/Evidence/IsolatedEvidenceEngine.swift
**Modifications**: Line numbers TBD (if file exists)
- Add Merkle proof generation method (if needed)
- No breaking changes to existing API

---

## Test Files to Create

### Tests/TimeAnchoring/
- `TSAClientTests.swift`
- `RoughtimeClientTests.swift`
- `OpenTimestampsAnchorTests.swift`
- `TripleTimeAnchorTests.swift`
- `WriteAheadLogTests.swift`

### Tests/MerkleTree/
- `MerkleTreeHashTests.swift`
- `MerkleTreeTests.swift`
- `InclusionProofTests.swift`
- `ConsistencyProofTests.swift`
- `SignedTreeHeadTests.swift`
- `MerkleAuditLogTests.swift`

### Tests/DeviceAttestation/
- `AppAttestClientTests.swift`
- `AttestationVerifierTests.swift`
- `CounterStoreTests.swift`

### Tests/Replay/
- `DeterministicSchedulerTests.swift`
- `MockTimeSourceTests.swift`
- `FaultInjectorTests.swift`

### Tests/FormatBridge/
- `ProvenanceBundleTests.swift`
- `GLTFExporterTests.swift`
- `FormatValidatorTests.swift`

---

**Implementation Not Started: Verified**

**Checklist**:
- [x] No Swift code implementations included
- [x] No test code included
- [x] Only interface names and signatures provided
- [x] All files listed with exact paths
- [x] Public types/protocols/enums listed (names only)
