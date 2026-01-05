> ARCHIVED — DO NOT USE AS SOURCE OF TRUTH.
> This document is historical and may be inconsistent with current specifications.
> Refer to docs/WHITEBOX.md and docs/ACCEPTANCE.md for the authoritative version.

# Manual Check Procedures

## Purpose

This document records all manual checks required during PR execution. Each check must be verified and documented with evidence.

## PR#3: Isolate Deprecated

### Check 1: Xcode Target Membership

**Action Required:**
1. Open the Xcode project
2. Navigate to the project navigator
3. For each file/directory in `deprecated/**`:
   - Select the file in Xcode
   - Open the File Inspector (right panel)
   - In "Target Membership", uncheck all targets
   - Verify the file is no longer in any target

**Verification:**
- Build Phases → Compile Sources: No files from `deprecated/**` should appear
- Search in Xcode for "deprecated" in Compile Sources list: Should return 0 results

**Evidence Required:**
- Screenshot path: `docs/_archive/manual_checks/PR3_target_membership.png`
- OR written record: "Checked Build Phases → Compile Sources, confirmed no deprecated files present"

### Check 2: Build Verification

**Action Required:**
- Attempt to build the project
- Verify that deprecated files are not compiled (should not cause build errors related to deprecated code)

**Evidence Required:**
- Build log showing no compilation of deprecated files
- OR written record: "Build attempted, deprecated files not compiled"

## PR#5: Delete Deprecated - Pre-deletion Verification

### Check 1: Core/Training/ Shaders Check

**Action Required:**
1. List contents of `Core/Training/`:
   ```bash
   find Core/Training -type f
   ```
2. If any `.metal`, `.glsl`, `.shader` files exist:
   - DO NOT DELETE `Core/Training/`
   - Document the files found in `REPO_INVENTORY.md`
   - Move Shaders to appropriate location if needed

**Verification:**
- `Core/Training/` contains only `.gitkeep` or is empty → Safe to delete
- `Core/Training/` contains shader files → DO NOT DELETE

**Evidence Required:**
- Output of `find Core/Training -type f` command
- Decision: Delete or Keep (with reason)

### Check 2: Features/ Xcode Target Check

**Action Required:**
1. Open Xcode project
2. Navigate to Build Phases → Compile Sources
3. Search for any file path containing "Features/"
4. If any files found:
   - DO NOT DELETE `Features/`
   - Document in `REPO_INVENTORY.md`

**Verification:**
- No files from `Features/` in Compile Sources → Safe to delete
- Files from `Features/` in Compile Sources → DO NOT DELETE

**Evidence Required:**
- Screenshot or written record of Compile Sources search results
- Decision: Delete or Keep (with reason)

