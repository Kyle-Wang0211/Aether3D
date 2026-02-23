<!-- SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary -->

# Mobile Local Fullchain Migration and Retention Policy

## Goal

Migrate to the mobile local fullchain while retaining both prior versions in the repository:

1. legacy Swift core stack
2. legacy cloud pipeline stack

No destructive replacement is allowed during migration.

## Track policy

Track definitions live in:

- `governance/pipeline_tracks_manifest.json`

Status rules:

- `retained`: legacy track must stay buildable/addressable and cannot be deleted.
- `active`: current default track under active development.

## CI enforcement

The retention gate is enforced by:

- `scripts/ci/validate_legacy_tracks_retention.sh`
- wired into `scripts/ci/run_all.sh`

Gate behavior:

- validates all required paths exist for every declared track
- fails CI if any retained-track path is removed

## Migration execution rule

During migration:

- keep old tracks as independent code paths
- introduce compatibility adapters instead of deleting old modules
- only mark a track `deprecated` after explicit governance decision (not by default)
