# PR#5 Docker Linux SPM Permission Fix

**Date**: 2025-01-18  
**Issue**: NSCocoaErrorDomain Code=513 "You don't have permission" in Docker Linux builds  
**Status**: Fixed

---

## Problem Statement

When running `swift build` or `swift test` inside a Docker container (`swift:5.9-jammy`, running as root) with the repository bind-mounted from macOS, SPM fails with permission errors:

```
error: 'swift-asn1': Error Domain=NSCocoaErrorDomain Code=513 "You don't have permission."
error: 'swift-crypto': Error Domain=NSCocoaErrorDomain Code=513 "You don't have permission."
```

This occurs immediately after SPM attempts to fetch/compute versions for repository dependencies.

---

## Root Cause Analysis

### Why NSCocoaErrorDomain 513 Occurs in Linux Containers

**NSCocoaErrorDomain Code=513** corresponds to `NSFileWriteNoPermissionError` or `NSFileReadNoPermissionError`. In the context of SPM (Swift Package Manager), this error indicates that SPM cannot write to or read from its workspace directories.

### The Permission Problem Chain

1. **Bind Mount Ownership Mismatch**:
   - Repository is mounted from macOS host filesystem into Docker container
   - macOS files have ownership/permissions set for macOS user (e.g., `501:20`)
   - Container runs as `root` (UID 0)
   - Even though root can technically read/write, macOS extended attributes, ACLs, and filesystem semantics can cause permission issues

2. **SPM Workspace Directories**:
   - SPM uses several directories for its workspace:
     - `.build/` - Build artifacts and intermediate files
     - `.swiftpm/` - Package resolution cache and checkouts
     - `~/.swiftpm/` or `$HOME/.swiftpm/` - User-level cache
     - `/tmp/` - Temporary files (via `TMPDIR`)
   - When SPM tries to create or write to these directories inside the bind-mounted workspace, it encounters permission issues

3. **macOS Extended Attributes**:
   - macOS filesystems (APFS, HFS+) store extended attributes (`com.apple.*`) that Linux cannot fully understand
   - These attributes can make files appear read-only or inaccessible even to root
   - Docker bind mounts preserve these attributes, causing cross-platform permission conflicts

4. **Mixed Ownership**:
   - `.build/` and `.swiftpm/` directories may have been created on macOS with macOS user ownership
   - Container's root user cannot reliably modify these directories due to ownership mismatch
   - Even `chmod -R` may not fully resolve extended attribute issues

---

## The Fix: Container-Local Writable Workspace

### Strategy

Instead of working directly in the bind-mounted workspace (which has macOS ownership/permissions), we:

1. **Mount repository as read-only** (`-v "$PWD:/workspace:ro"`):
   - Prevents accidental writes to host filesystem
   - Avoids ownership/permission conflicts for source files
   - Source files remain unchanged

2. **Create container-local writable copy**:
   - Use `rsync -a` to copy `/workspace/` to `/tmp/aether3d_src/`
   - Container-local copy has correct ownership (root:root)
   - No macOS extended attributes or permission issues

3. **Set SPM directories to container-local paths**:
   - `.build/` → `/tmp/aether3d_build/`
   - `TMPDIR=/tmp` (container-local temp directory)
   - `HOME=/tmp/home` (container-local home, ensures `.swiftpm` cache is writable)
   - All SPM operations happen in writable container-local directories

4. **Work in container-local copy**:
   - `cd /tmp/aether3d_src/` before running `swift build` or `swift test`
   - SPM resolves dependencies, builds, and tests in container-local environment
   - No permission issues because all directories are writable by root

### Why This Works

- **No ownership conflicts**: Container-local directories are owned by root (container user)
- **No extended attributes**: Container filesystem (ext4) doesn't have macOS extended attributes
- **Writable by default**: `/tmp/` is always writable by root in Linux containers
- **Isolated from host**: Host filesystem remains unchanged, no permission modifications needed
- **Deterministic**: Same behavior every time, regardless of host filesystem permissions

---

## Implementation

The implementation uses a two-script architecture to clearly separate host and container responsibilities:

### Script Architecture

**Host Script**: `scripts/docker_linux_ci.sh`
- Runs **ONLY on the host** (detects and fails if run inside container)
- Responsibilities:
  - Checks Docker availability and daemon status
  - Pulls Docker image if needed
  - Launches Docker container with proper mounts
  - Invokes inner script inside container
- **MUST NOT** reference Docker commands inside container context

**Container Script**: `scripts/linux_ci_inner.sh`
- Runs **ONLY inside Docker container**
- Responsibilities:
  - Copies `/workspace/` to `/tmp/aether3d_src/` (container-local)
  - Installs Linux dependencies (`apt-get`)
  - Sets environment variables (`TMPDIR`, `HOME`)
  - Runs SPM commands (`swift package clean`, `swift build`, `swift test`)
- **MUST NOT** reference Docker commands (not available in container)

### Why Script Separation is Required

1. **Docker is not available inside containers**:
   - Containers don't have Docker daemon access
   - Attempting to run `docker` inside a container causes "Docker is not installed" errors
   - This is expected behavior and indicates incorrect architecture

2. **Clear responsibility boundaries**:
   - Host script: Container orchestration only
   - Container script: Build/test execution only
   - No ambiguity about where each script runs

3. **Prevents accidental misuse**:
   - Host script detects container execution and fails fast
   - Clear error messages guide users to correct usage
   - Future-proof for GitHub Actions (which may run in containers)

### Implementation Steps

1. **Host script** (`docker_linux_ci.sh`):
   - Detects container execution (checks `/.dockerenv` and `/proc/self/cgroup`)
   - Mounts repo as read-only: `-v "$PWD:/workspace:ro"`
   - Mounts inner script: `-v "$INNER_SCRIPT:/linux_ci_inner.sh:ro"`
   - Invokes: `docker run ... /bin/bash /linux_ci_inner.sh`

2. **Container script** (`linux_ci_inner.sh`):
   - Copies workspace: `rsync -a /workspace/ /tmp/aether3d_src/`
   - Sets environment variables:
     - `TMPDIR=/tmp`
     - `HOME=/tmp/home`
     - `SWIFT_PACKAGE_BUILD_DIR=/tmp/aether3d_build`
   - Works in container-local copy: `cd /tmp/aether3d_src/`
   - Runs SPM commands: `swift package clean`, `swift build`, `swift test`

---

## Verification

Run the Docker script:

```bash
bash scripts/docker_linux_ci.sh
```

Expected behavior:
- ✅ Build succeeds without permission errors
- ✅ Tests run successfully
- ✅ Logs saved to `./artifacts/docker-linux/`
- ✅ No NSCocoaErrorDomain 513 errors

---

## Related Issues

- **GitHub Actions**: GitHub Actions runners don't have this issue because they run natively on Linux (no macOS bind mount)
- **Local macOS**: No issue because macOS user owns the workspace
- **Docker on Linux host**: May still have issues if host filesystem has restrictive permissions, but less common than macOS→Linux bind mount

---

## Host vs Container Script Separation

### Why Docker Must Never Be Invoked Inside Containers

**Fundamental Constraint**: Docker containers do not have access to the Docker daemon by default. Attempting to run `docker` commands inside a container will fail with "Docker is not installed or not in PATH", even if Docker is installed on the host.

**Design Principle**: Scripts must be designed with clear execution contexts:
- **Host scripts**: Can use Docker commands, mount volumes, launch containers
- **Container scripts**: Cannot use Docker commands, must work with mounted filesystems only

**Failure Detection**: The host script (`docker_linux_ci.sh`) detects if it's running inside a container and fails fast with a clear error message, preventing misuse.

### Why Bind Mounts Are Unsafe for SwiftPM Builds

**Problem**: When mounting a macOS filesystem into a Linux container:
1. **Ownership mismatch**: macOS files owned by macOS user (e.g., `501:20`) vs container root (`0:0`)
2. **Extended attributes**: macOS filesystems (APFS, HFS+) store extended attributes that Linux cannot fully understand
3. **Permission conflicts**: Even root cannot reliably write to macOS-owned directories due to extended attributes
4. **SPM workspace**: SPM needs to create `.build/` and `.swiftpm/` directories, which fails due to permission issues

**Solution**: 
- Mount source as **read-only** (`:ro` flag)
- Copy to **container-local writable location** (`/tmp/aether3d_src/`)
- Run all SPM operations in container-local directories
- No permission issues because container-local directories are owned by container user

### Prevention

To prevent similar issues in the future:

1. **Always use container-local directories** for SPM workspace when using Docker
2. **Mount source as read-only** to avoid accidental host filesystem modifications
3. **Set explicit environment variables** (`TMPDIR`, `HOME`) to ensure writable paths
4. **Separate host and container scripts** with clear responsibility boundaries
5. **Detect container execution** in host scripts and fail fast with clear errors
6. **Document Docker usage** so developers know the correct workflow
7. **Never invoke Docker commands inside container scripts**

---

## References

- [Swift Package Manager Documentation](https://www.swift.org/package-manager/)
- [Docker Bind Mount Permissions](https://docs.docker.com/storage/bind-mounts/)
- [NSCocoaErrorDomain Error Codes](https://developer.apple.com/documentation/foundation/nscocoaerrordomain)
