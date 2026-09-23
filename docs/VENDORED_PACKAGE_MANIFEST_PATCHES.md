# Vendored Package Manifest Patches

`Aether3D` relies on vendored Swift packages under `.deps/` (`Package.swift` uses `.package(path: ".deps/...")`): MetalSplatter for splat I/O, and swift-crypto / swift-nio-ssh / swift-ssh-client for the mobile SSH transport stack.

Each `.deps/` package is a git submodule pinned to an exact upstream release tag:

| Path | Upstream | Tag | Commit |
|---|---|---|---|
| `.deps/MetalSplatter` | https://github.com/scier/MetalSplatter | `1.0.1` | `71ff248e3016ac43c0a9271e322538421b28c360` |
| `.deps/swift-crypto` | https://github.com/apple/swift-crypto | `3.15.1` | `95ba0316a9b733e92bb6b071255ff46263bbe7dc` |
| `.deps/swift-nio-ssh` | https://github.com/apple/swift-nio-ssh | `0.12.0` | `8f33cac67309a13aecc0a4d95044543549b20ffb` |
| `.deps/swift-ssh-client` | https://github.com/gaetanzanella/swift-ssh-client | `0.1.4` | `a907468362efb68a16e5b0ad5c0d9bfef90276ae` |

Two of them need local changes on top of the pinned tag. Edits inside a submodule do not appear in the main repository's history, so the source of truth lives in tracked patch files:

- `patches/vendor/swift-ssh-client-Package.swift.patch`
- `patches/vendor/swift-ssh-client-sources.patch`
- `patches/vendor/swift-crypto-Package.swift.patch`

Set up a fresh clone (before `swift package resolve` / `swift build`) with:

```bash
git submodule update --init .deps
bash scripts/vendor/apply_local_manifest_patches.sh
```

The script is idempotent: it applies each patch, or reports it as already applied, and fails on drift. `.gitmodules` sets `ignore = dirty` on the two patched submodules so the applied patches do not show up in `git status`.

Current intent:

- `swift-ssh-client` manifest
  - upgrades to newer SwiftPM / NIO SSH ranges
  - points `swift-crypto` at the local vendored path
  - links `Crypto` and `CCryptoBoringSSL`
- `swift-ssh-client` sources
  - surfaces the underlying transport error on disconnect instead of `.unknown` (adds `SSHConnectionError.transport(String)`, makes `SSHConnectionError` `Equatable` + `Sendable`)
  - resolves the authentication promise exactly once, and fails it on `errorCaught` / `channelInactive`
  - closes half-created channels without letting a close failure mask the original error
  - pipelines SFTP writes (up to 64 slices of 32000 bytes in flight per batch) instead of writing one slice at a time
- `swift-crypto` manifest
  - exports `CCryptoBoringSSL` as a regular static library product so the iOS SSH client can link cleanly

swift-nio-ssh and MetalSplatter are used unmodified. The root package's `.package(path:)` declarations take precedence over the URL dependencies declared by the vendored manifests, so every package resolves to its `.deps/` copy.
