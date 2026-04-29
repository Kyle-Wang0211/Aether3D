// Dart port of Core/Pipeline/RemoteB1Client.swift.
//
// Provider-agnostic upload/process/download protocol. Concrete backends:
//   • BackgroundUploadBrokerClient (HTTP broker — production)
//   • NotConfiguredRemoteB1Client  (fallback when config is missing)
//
// Legacy implementations (DanishGoldenSSH / LocalAether) are retained
// in the Swift repo but intentionally not ported — the broker path
// supersedes them and today's Flutter app has a single prod pipeline.

import 'dart:typed_data';

enum RemoteUploadPhase { transferring, finalizing }

class RemoteUploadProgress {
  final int uploadedBytes;
  final int totalBytes;
  final RemoteUploadPhase phase;

  const RemoteUploadProgress({
    required this.uploadedBytes,
    required this.totalBytes,
    this.phase = RemoteUploadPhase.transferring,
  });

  double? get fraction {
    if (totalBytes <= 0) return null;
    final f = uploadedBytes / totalBytes;
    return f.clamp(0.0, 1.0);
  }

  bool get isFinalizing => phase == RemoteUploadPhase.finalizing;
}

class RemoteJobProgress {
  final double? progressFraction;
  final String? stageKey;
  final String? phaseName;
  final String? currentTier;
  final String? title;
  final String? detail;
  final int? etaMinutes;
  final int? elapsedSeconds;
  final String? progressBasis;
  final Map<String, String> runtimeMetrics;

  const RemoteJobProgress({
    this.progressFraction,
    this.stageKey,
    this.phaseName,
    this.currentTier,
    this.title,
    this.detail,
    this.etaMinutes,
    this.elapsedSeconds,
    this.progressBasis,
    this.runtimeMetrics = const {},
  });
}

enum ArtifactFormat { ply, spz, splat, glb, zip, unknown }

ArtifactFormat artifactFormatFromExtension(String? ext) {
  switch (ext?.toLowerCase()) {
    case 'ply':
      return ArtifactFormat.ply;
    case 'spz':
      return ArtifactFormat.spz;
    case 'splat':
      return ArtifactFormat.splat;
    case 'glb':
      return ArtifactFormat.glb;
    case 'zip':
      return ArtifactFormat.zip;
    default:
      return ArtifactFormat.unknown;
  }
}

class DownloadedArtifact {
  final Uint8List data;
  final ArtifactFormat format;
  final String? sha256;

  const DownloadedArtifact({
    required this.data,
    required this.format,
    this.sha256,
  });
}

sealed class JobStatus {
  const JobStatus();

  const factory JobStatus.pending(RemoteJobProgress progress) = JobPending;
  const factory JobStatus.processing(RemoteJobProgress progress) =
      JobProcessing;
  const factory JobStatus.downloadReady(RemoteJobProgress progress) =
      JobDownloadReady;
  const factory JobStatus.completed(RemoteJobProgress? progress) =
      JobCompleted;
  const factory JobStatus.failed({
    required String reason,
    RemoteJobProgress? progress,
  }) = JobFailed;
  const factory JobStatus.cancelled(RemoteJobProgress? progress) =
      JobCancelled;
}

class JobPending extends JobStatus {
  final RemoteJobProgress progress;
  const JobPending(this.progress);
}

class JobProcessing extends JobStatus {
  final RemoteJobProgress progress;
  const JobProcessing(this.progress);
}

class JobDownloadReady extends JobStatus {
  final RemoteJobProgress progress;
  const JobDownloadReady(this.progress);
}

class JobCompleted extends JobStatus {
  final RemoteJobProgress? progress;
  const JobCompleted(this.progress);
}

class JobFailed extends JobStatus {
  final String reason;
  final RemoteJobProgress? progress;
  const JobFailed({required this.reason, this.progress});
}

class JobCancelled extends JobStatus {
  final RemoteJobProgress? progress;
  const JobCancelled(this.progress);
}

class RemoteB1ClientException implements Exception {
  final String code;
  final String message;
  final int? httpStatusCode;
  const RemoteB1ClientException({
    required this.code,
    required this.message,
    this.httpStatusCode,
  });
  @override
  String toString() =>
      'RemoteB1ClientException($code: $message${httpStatusCode != null ? ' http=$httpStatusCode' : ''})';
}

/// Protocol that every backend implementation satisfies. Stays narrow
/// so the UI layer doesn't care which backend is chosen.
abstract class RemoteB1Client {
  Future<String> upload({
    required String videoFilePath,
    void Function(RemoteUploadProgress)? onProgress,
  });

  Future<String> startJob({required String assetId});

  Future<JobStatus> pollStatus({required String jobId});

  Future<DownloadedArtifact> download({required String jobId});

  Future<void> cancel({required String jobId});
}
