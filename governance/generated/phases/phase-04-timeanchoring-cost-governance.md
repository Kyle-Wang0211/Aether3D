# Phase 04 Runbook - TimeAnchoring + Cost Governance

## Objective
Complete pure-computation time anchoring and deterministic cost governance (quota, pricing, rate policy) without network IO in Core.

## Entry Criteria
- Prerequisite phases passed: 3
- Track: P

## Required Contracts
- `C-TRACK-P-LEGAL-BASELINE` [active] - Track P parity is legal baseline
- `C-CORE-NO-CONCURRENCY-PRIMITIVES` [active] - Core forbids mutex/thread/atomic primitives
- `C-AETHERBILLING-RESOURCE-WALLET` [active] - Resource Wallet metering and quota charging algorithm is delivered in Phase 4 infrastructure
- `C-COSTSHIELD-POLICYKERNEL-DETERMINISM` [active] - CostShield quota, rate-limit, and shadow-pricing policy kernel is deterministic Core logic in Phase 4
- `C-AUDIT-ANCHOR-CLIENT-FIRST` [active] - RFC3161 audit anchoring is client-first with start/end mandatory and 60s periodic anchors

## Required Gates
- `G-CONTRACT-VALIDATOR` (error) - Governance registry and contract validation
- `G-SWIFT-BUILD` (error) - Swift build and target tests
- `G-AUDIT-ANCHOR-CLIENT-FIRST` (error) - RFC3161 client-first anchor policy (start/end mandatory + 60s periodic)

## Cursor Steps
1. Implement parser/fusion/error-classification/proof assembly.
2. Integrate AetherBilling resource wallet metering and quota checks.
3. Implement CostShield policy kernel primitives (shadow pricing, GCRA, idempotency key generation).
4. Enforce client-first RFC3161 anchor policy (session start/end mandatory + 60s periodic) with mobile direct TSA path.
5. Validate deterministic outputs across platforms.
6. Store phase evidence and cost-policy fixtures in governance generated report.
7. Tag integration checkpoint phase-4-pass.

## Gate Commands
### G-CONTRACT-VALIDATOR
Governance registry and contract validation

```bash
python3 governance/scripts/validate_governance.py --strict --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

### G-SWIFT-BUILD
Swift build and target tests

```bash
swift build
```

Expected artifacts:
- `.build/`

### G-AUDIT-ANCHOR-CLIENT-FIRST
RFC3161 client-first anchor policy (start/end mandatory + 60s periodic)

```bash
python3 governance/scripts/validate_governance.py --strict --only audit-anchor --report governance/generated/governance_diagnostics.json
```

Expected artifacts:
- `governance/generated/governance_diagnostics.json`

## Deliverables
- `aether/time/*`
- `aether/billing/*`
- `aether/cost_policy/*`
- `Marzullo fusion verification outputs`

## Exit Criteria
- All required gates pass.
- Governance strict validation returns zero errors.
- Tag checkpoint `phase-4-pass` on `codex/protocol-governance-integration`.
