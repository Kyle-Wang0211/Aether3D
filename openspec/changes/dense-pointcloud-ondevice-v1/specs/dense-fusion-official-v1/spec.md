## ADDED Requirements

### Requirement: Fusion semantics are the official filter.py, unchanged
The C++ fusion SHALL implement `check_geometric_consistency` / `reproject_with_depth`
of cvg/diffmvs `filter.py` and the certified `fuse_official.py` loop with no
added, removed, or re-tuned constant. Every constant SHALL cite its source line.

#### Scenario: A constant without a source
- **WHEN** a threshold or scale appears in the C++ that has no line citation
- **THEN** the change is not mergeable

### Requirement: Library calls are copied, not replicated
Where the official Python calls a library (OpenCV `remap`, LAPACK via numpy), the
C++ SHALL call the same library kernel or a verbatim-structure port of the
reference algorithm, and SHALL be built with the same floating-point contraction
setting as the device builds (`-ffp-contract=off`).

#### Scenario: Reference and device disagree on contraction
- **WHEN** the Python reference's OpenCV was built with a different `-ffp-contract`
- **THEN** the reference SHALL be regenerated with a matching build before judging

### Requirement: Bit-exact host gate
Per-frame masks, geo sums, averaged depths, world points and colours produced by
the C++ SHALL be bit-identical to the official Python on the frozen fixture; any
non-zero difference fails the gate.

#### Scenario: One mask pixel differs
- **WHEN** the comparator reports a single differing element
- **THEN** the gate fails and the first differing probe stage is investigated
