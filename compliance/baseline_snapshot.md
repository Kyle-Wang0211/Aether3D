# Compliance Baseline Snapshot

- Snapshot UTC: 2026-02-18T16:51:21Z
- Repository HEAD: `4aca3950cdb4432001f250371e80ae1233b0d02e`
- Snapshot scope: dependency and release-compliance baselines for legal reproducibility.

## Locked Inputs

| Artifact | SHA256 |
|---|---|
| `Package.resolved` | `fd4e7f890211e715e2b7b76f221907d6c076fbb745bf64e8150b0df95bdb4ca8` |
| `server/requirements.txt` | `b104e58f8219fb8593a51d9f4dfd9ed81cdcb1c916d35568763081bb362024ce` |
| `server/requirements.lock.txt` | `1aa5b2e22411bba1f6a1cb5c66a32aceb051bd171be61f52f8a425bede67e418` |
| `compliance/third_party/manifest.v1.json` | `d1e460d8c8fa1ffa33ac04565e647a70f188d7c0daa626f767201d0dfdbae272` |
| `compliance/third_party/license_policy.json` | `d864ab401918ad1a22cbc822fd0aae5fa1211bd5c45b84307c7a810c2090e72f` |
| `toolchain.lock` | `e6b58279653cdbe3cb7e5214a1b240d1e4a2b13990150bbd1a270c24fe17fbbf` |

## Release Gating Rule

1. Any dependency update MUST update:
   - `server/requirements.lock.txt`
   - `compliance/third_party/manifest.v1.json`
   - `compliance/third_party/licenses/`
   - `NOTICE`
   - `docs/compliance/change_control.md`
2. Pull requests that modify lockfiles without compliance bundle updates MUST fail CI.
3. Tagging a release is blocked unless `scripts/ci/release_compliance_gate.sh` passes.

## Maintainer Sign-off

- Owner: Core Compliance Engineering
- Last reviewed: 2026-02-18
- Next mandatory review trigger: any lockfile digest change.
