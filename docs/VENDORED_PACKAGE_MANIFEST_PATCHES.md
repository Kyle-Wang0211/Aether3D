# Vendored Package Manifest Patches

`Aether3D` currently relies on local vendored Swift packages under `.deps/` for the mobile SSH transport stack.

Those vendor directories are local git repositories, so direct edits inside `.deps/` do not appear in the main repository's `git status`. To make the required manifest changes reproducible and reviewable, the source of truth lives in tracked patch files:

- `patches/vendor/swift-ssh-client-Package.swift.patch`
- `patches/vendor/swift-crypto-Package.swift.patch`

Apply or verify those patches with:

```bash
bash scripts/vendor/apply_local_manifest_patches.sh
```

Current intent:

- `swift-ssh-client`
  - upgrades to newer SwiftPM / NIO SSH ranges
  - points `swift-crypto` at the local vendored path
  - links `Crypto` and `CCryptoBoringSSL`
- `swift-crypto`
  - exports `CCryptoBoringSSL` as a regular static library product so the iOS SSH client can link cleanly

This keeps `.deps/` as a local vendor workspace while ensuring the manifest changes are versioned in the main repository.
