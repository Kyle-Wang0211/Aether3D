# PR1 — ObservationModel CONSTITUTION

(E-Class: Computable, Auditable Evidence Laws)

PR Type
Foundational / Constitutional / Single Source of Truth (SSOT)

Absolute Scope Rule
This PR defines what constitutes an observation and when it is considered valid evidence.
It does not define aggregation strategies, scheduling, optimization, UI behavior, or heuristics.

Any future PR that contradicts this document is invalid by definition, regardless of functionality.

⸻

0. First Principles (Non-Negotiable)
	1.	Observations must be computable facts, not judgments
	2.	All evidence must be reproducible from raw measurements
	3.	No inference without direct observation
	4.	No downgrade, no hallucination, no implicit upgrade

⸻

1. Observation — Canonical Definition

An Observation is a single, immutable, time-indexed record that captures direct, measurable interaction between the sensor system and a Patch.

An Observation must not:
	•	depend on neighboring patches
	•	depend on prior statistics
	•	depend on machine-learned predictions
	•	depend on UI interpretation

⸻

2. Evidence Levels — Observational Preconditions

ObservationModel defines necessary and sufficient observational conditions for each EvidenceLevel.
It does not assign or modify EvidenceLevel directly.

⸻

3. L1 Observational Validity (Patch Hit)

3.1 Definition

An Observation satisfies L1 preconditions if and only if:
	1.	A camera ray geometrically intersects the Patch's physical proxy
	2.	The projected overlap area on the Patch exceeds a minimum ε
	3.	The Patch is not fully occluded at the intersection point

3.2 Explicit Exclusions

The following do not qualify as L1 evidence:
	•	Feature-only matches
	•	Texture similarity
	•	Optical flow correspondence
	•	Inferred visibility
	•	Historical presence

L1 strictly answers the question:

"Was this Patch physically seen by the sensor at this moment?"

⸻

4. L2 Observational Validity (Geometric Consistency)

4.1 Required Conditions (ALL MUST HOLD)

An Observation contributes to L2 eligibility only if:
	1.	Multi-view support
	•	At least two valid L1 observations from distinct camera poses
	2.	Parallax threshold
	•	baseline / depth ≥ r_min(depth-adaptive)
	3.	Reprojection error constraint
	•	reprojection error ≤ ε_reproj
	4.	Geometric agreement
	•	Triangulated position variance ≤ ε_geo

4.2 Hard Rule

Failure of any condition disqualifies the observation from L2 consideration.

No soft scoring, no averaging, no override.

⸻

5. L3 Observational Validity (Appearance Stability)

5.1 Required Conditions (ALL MUST HOLD)

An Observation contributes to L3 eligibility only if:
	1.	Distinct viewpoints
	•	≥ 3 observations satisfying the distinct-viewpoint definition (§6)
	2.	Triangulation stability
	•	Depth variance ≤ ε_depth
	3.	Photometric consistency
	•	Statistical stability of appearance across views

5.2 Photometric Stability Definition
	•	L3_core: luminance variance ≤ ε_L
	•	L3_strict: full Lab variance ≤ ε_Lab

Any single unstable channel invalidates L3 eligibility.

⸻

6. Distinct Viewpoint — Authoritative Definition

Two viewpoints are considered distinct if and only if:
	1.	baseline / depth ≥ r_min
AND
	2.	angular separation ≥ θ_min

Angle-only or baseline-only definitions are insufficient.

This definition is scale-invariant and depth-aware.

⸻

7. Quality Signals — Constitutional Role

Quality metrics (sharpness, exposure, blur, rolling shutter, etc.):
	•	May be recorded
	•	May influence confidence weighting
	•	Must not:
	•	establish evidence validity
	•	override geometric requirements
	•	upgrade EvidenceLevel directly

Quality affects how reliable an observation is, not whether it is true.

⸻

8. Occlusion Semantics

8.1 Occluded Observation

If a Patch is occluded:
	•	The Observation is invalid for geometric evidence
	•	It may be recorded as a low-confidence observation
	•	It must not contribute to L2 or L3 eligibility

8.2 No Speculative Visibility

The system must never assume visibility through inference, interpolation, or memory.

⸻

9. Confidence Semantics (Constitutional Boundaries)

9.1 Definition

Each Observation may carry a confidence value ∈ [0,1].

9.2 Hard Constraints
	•	Confidence is not evidence
	•	Confidence is not truth
	•	Confidence must not:
	•	bypass EvidenceLevel rules
	•	simulate geometric sufficiency
	•	substitute missing observations

⸻

10. Closed-World Declaration

The following are explicitly forbidden as sources of evidence:
	•	Neighbor patch inference
	•	Grid / voxel propagation
	•	Temporal smoothing as evidence
	•	Machine-learned estimators
	•	Category priors
	•	UI-driven assumptions

Only direct, measurable observations are admissible.

⸻

11. Auditability Requirement

For every Observation used in evidence reasoning, the system must be able to reconstruct:
	•	sensor pose
	•	ray / projection geometry
	•	raw measurements
	•	validation outcomes for L1/L2/L3 preconditions

Failure to audit implies invalid evidence.

⸻

12. Cross-PR Enforcement Rule

All future PRs must:
	•	Import ObservationModel definitions from PR1
	•	Treat this document as authoritative
	•	Refrain from redefining observational validity locally

Violation constitutes a constitutional breach, not an implementation detail.

⸻

Final Constitutional Statement

ObservationModel defines what the system is allowed to believe.
Everything else merely decides what to do with belief.

⸻

EEB Invariants (Authoritative)

INV-EEB-1: Closed-World Escalation
Only triggers defined in EEBTrigger may cause EvidenceLevel escalation.
Any escalation without a trigger is INVALID.

INV-EEB-2: Single-Step Escalation Only
Direct escalation across multiple levels (e.g., L0 → L2, L1 → L3) is FORBIDDEN.

INV-EEB-3: Session Monotonicity
Within a session or epoch:

EvidenceLevel[t+1] ≥ EvidenceLevel[t]

INV-EEB-4: Cross-Epoch Inheritance Ceiling
	•	L3 evidence MUST NOT survive epoch migration
	•	Only L1 and L2 evidence may be inherited

INV-EEB-5: EEB Supremacy
All implementations (including PR#6 and beyond) must call EEBGuard.allows.
Bypassing EEBGuard constitutes a constitutional violation, not a bug.
