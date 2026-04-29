// Dart stand-in for Core/Pipeline/Artifacts/ArtifactManifest.swift.
//
// NB: The Swift source file wasn't present in the repo snapshot we
// read. This Dart implementation matches the behavior described by
// the user and the references in BackgroundUploadBrokerClient.swift:
//   • Broker response carries a manifest listing produced files
//     (primary artifact, comparison asset, comparison metrics, HQ
//     asset, viewer bundle) with per-file SHA256 hashes.
//   • Client verifies each file after download.
//   • Records without a user-supplied name default to "未命名作品" and
//     can be renamed by the user from the vault/detail UI. The legacy
//     name "草稿" is accepted on read for back-compat with old records.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Default display name for a newly-created scan record before the
/// user renames it. Matches the user's direction 2026-04-27.
const String kDefaultScanRecordName = '未命名作品';

/// Previously-used default name. Accepted on read for back-compat.
const String kLegacyDraftName = '草稿';

enum ArtifactKind {
  /// Primary single-file artifact (glb / ply / spz / splat).
  primaryAsset,

  /// Viewer bundle (multi-file package for the web / vision viewer).
  viewerBundle,

  /// Pair for quality comparison (asset + metrics .json).
  comparisonAsset,
  comparisonMetrics,

  /// HQ upgrade for premium tier.
  hqAsset,
}

extension ArtifactKindKey on ArtifactKind {
  String get slug {
    switch (this) {
      case ArtifactKind.primaryAsset:
        return 'primary_asset';
      case ArtifactKind.viewerBundle:
        return 'viewer_bundle';
      case ArtifactKind.comparisonAsset:
        return 'comparison_asset';
      case ArtifactKind.comparisonMetrics:
        return 'comparison_metrics';
      case ArtifactKind.hqAsset:
        return 'hq_asset';
    }
  }

  static ArtifactKind? fromSlug(String slug) {
    for (final k in ArtifactKind.values) {
      if (k.slug == slug) return k;
    }
    return null;
  }
}

class ArtifactFileEntry {
  final ArtifactKind kind;

  /// Filename as returned by the broker (informational — client can
  /// rename on disk).
  final String filename;

  /// Byte size reported by the broker. Null if not provided.
  final int? sizeBytes;

  /// Lowercase hex SHA256 digest as reported by the broker. Null when
  /// the broker response didn't include one (rare — treat as
  /// unverifiable download).
  final String? sha256;

  /// Optional download URL. When null, the client fetches from the
  /// standard `/v1/mobile-jobs/{jobId}/artifact-download/{kind.slug}`
  /// path.
  final String? downloadUrl;

  const ArtifactFileEntry({
    required this.kind,
    required this.filename,
    this.sizeBytes,
    this.sha256,
    this.downloadUrl,
  });

  factory ArtifactFileEntry.fromJson(Map<String, dynamic> json) {
    final kindSlug =
        json['kind'] as String? ?? json['asset_kind'] as String? ?? '';
    final kind = ArtifactKindKey.fromSlug(kindSlug) ?? ArtifactKind.primaryAsset;
    return ArtifactFileEntry(
      kind: kind,
      filename: json['filename'] as String? ??
          json['name'] as String? ??
          '${kind.slug}.bin',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ??
          (json['bytes'] as num?)?.toInt(),
      sha256: (json['sha256'] as String?)?.toLowerCase(),
      downloadUrl: json['download_url'] as String?,
    );
  }
}

class BrokerArtifactManifest {
  /// Stable per-record identifier minted by the broker when the job is
  /// created. Persisted client-side and used for all subsequent
  /// status / download calls.
  final String jobId;

  /// User-visible name. Defaults to "未命名作品" if the broker didn't
  /// supply one; the user can rename via the vault detail UI.
  final String displayName;

  /// File list — may be empty while a job is still processing.
  final List<ArtifactFileEntry> files;

  const BrokerArtifactManifest({
    required this.jobId,
    required this.displayName,
    required this.files,
  });

  factory BrokerArtifactManifest.fromJson(Map<String, dynamic> json) {
    final rawName = (json['display_name'] as String?) ??
        (json['name'] as String?) ??
        '';
    final name = rawName.trim().isEmpty
        ? kDefaultScanRecordName
        : (rawName.trim() == kLegacyDraftName ? rawName.trim() : rawName.trim());
    final filesJson = (json['files'] as List<dynamic>? ?? []);
    return BrokerArtifactManifest(
      jobId: json['job_id'] as String? ?? json['id'] as String? ?? '',
      displayName: name,
      files: filesJson
          .whereType<Map<String, dynamic>>()
          .map(ArtifactFileEntry.fromJson)
          .toList(growable: false),
    );
  }

  /// Returns the file for `kind` or throws. Use `maybeFile` for optional
  /// lookup.
  ArtifactFileEntry file(ArtifactKind kind) {
    final hit = maybeFile(kind);
    if (hit == null) {
      throw StateError('Manifest missing file for kind=${kind.slug}');
    }
    return hit;
  }

  ArtifactFileEntry? maybeFile(ArtifactKind kind) {
    for (final f in files) {
      if (f.kind == kind) return f;
    }
    return null;
  }

  BrokerArtifactManifest copyWithDisplayName(String newName) {
    return BrokerArtifactManifest(
      jobId: jobId,
      displayName: newName.trim().isEmpty ? kDefaultScanRecordName : newName.trim(),
      files: files,
    );
  }
}

/// Verifies a downloaded blob's SHA256 against the manifest entry.
/// Returns true if the manifest has no sha256 (skip verification) OR
/// the hash matches.
bool verifyDownloadedFile(ArtifactFileEntry entry, Uint8List bytes) {
  final expected = entry.sha256;
  if (expected == null || expected.isEmpty) return true;
  final actual = sha256.convert(bytes).toString().toLowerCase();
  return actual == expected;
}

class ArtifactIntegrityException implements Exception {
  final ArtifactKind kind;
  final String expected;
  final String actual;
  const ArtifactIntegrityException({
    required this.kind,
    required this.expected,
    required this.actual,
  });
  @override
  String toString() =>
      'ArtifactIntegrityException(kind=${kind.slug} expected=$expected actual=$actual)';
}
