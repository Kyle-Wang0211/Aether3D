> ARCHIVED — DO NOT USE AS SOURCE OF TRUTH.
> This document is historical and may be inconsistent with current specifications.
> Refer to docs/WHITEBOX.md and docs/ACCEPTANCE.md for the authoritative version.

# PR#3 Breakage Map

## Purpose

This document describes the expected compilation failures introduced by PR#3 and confirms they are controlled and will be resolved in PR#5.

## Expected Failures (Controlled)

### 1. PipelineRunner.run() Method

**Location:** `Core/Pipeline/PipelineRunner.swift`

**Failure Reason:**
- `run()` method depends on `BuildResult`, `PipelineState`, `PipelineError`, `PhotoSpaceArtifact`
- These types are moved to `deprecated/` in PR#3

**Resolution:**
- PR#5 will delete the `run()` method entirely
- Only `runGenerate()` will remain

**Impact:** Controlled - This is the legacy API that is being removed.

### 2. PipelineOutput / OutputManager Chain

**Location:** `Core/Output/PipelineOutput.swift`, `Core/Output/OutputManager.swift`

**Failure Reason:**
- `PipelineOutput` depends on `BuildPlan` (moved to deprecated)
- `OutputManager` manages `PipelineOutput` instances

**Resolution:**
- PR#5 will remove `OutputManager` usage from `PipelineDemoViewModel`
- `PipelineOutput` will be removed entirely

**Impact:** Controlled - Output management is being simplified.

### 3. ResultPreviewView Navigation Chain

**Location:** `App/Demo/PipelineDemoView.swift`, `App/Demo/PipelineDemoViewModel.swift`

**Failure Reason:**
- `ResultPreviewView` depends on `PipelineOutput` and `BuildPlan` (both moved to deprecated)
- Navigation to `ResultPreviewView` will fail

**Resolution:**
- PR#5 will remove `ResultPreviewView` navigation
- Success state will only show basic information (path/filename)

**Impact:** Controlled - Preview functionality is being removed.

## Forbidden Failures (Must Not Occur)

### Core/Router/DeviceTier.swift and BuildMode.swift

**Must Not Fail:**
- These files are NOT moved to deprecated
- They must remain functional
- Any failure here indicates an error in PR#3

**Verification:**
- `grep -r "DeviceTier\|BuildMode" Core/Router/` should show only these two files
- Build should succeed for files that import only `DeviceTier` or `BuildMode`

## Resolution Timeline

- PR#3: Failures introduced (expected)
- PR#4: Router cleanup (should not affect these failures)
- PR#5: All failures resolved (deprecated code deleted, references removed)

