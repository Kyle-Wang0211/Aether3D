# Deprecated Code Zone

This directory contains code that has been intentionally removed from the active architecture.

## Rules

- Code here MUST NOT be referenced by any active module.
- Code here MUST NOT be reintroduced without an approved RFC.
- This directory WILL BE DELETED in a future phase (PR#5).

Any reintroduction without RFC is considered a violation.

## Contents

- `Pipeline/` - Deprecated pipeline components (FrameExtractor, PluginB, Types)
- `Router/` - Deprecated router components (RouterV0, BuildPlan, StopRules, etc.)
- `Output/` - Deprecated output management (OutputManager, PipelineOutput)
- `App/` - Deprecated UI components (ResultPreviewView)

## Removal Timeline

- PR#3: Code moved to deprecated/ (this PR)
- PR#4: Router cleanup (should not affect deprecated code)
- PR#5: This directory will be permanently deleted

