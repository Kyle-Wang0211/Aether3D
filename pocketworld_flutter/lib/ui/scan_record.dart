// Dart port of the TestFlight prototype's ScanRecord + ScanJobStatus.
// Fields intentionally minimal — only the ones the current placeholder
// UI actually reads. When the Flutter app starts talking to a real
// backend / ScanRecordStore, extend this model and the view model that
// wraps it; the UI layer stays stable.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

/// The lifecycle a cloud-train job moves through. `null` = no job (local
/// capture only, or the job has settled into "completed / archived").
enum ScanJobStatus {
  uploading,
  queued,
  reconstructing,
  training,
  packaging,
  failed,
  cancelled,
}

extension ScanJobStatusLabel on ScanJobStatus {
  String get zhTitle {
    switch (this) {
      case ScanJobStatus.uploading:
        return '上传中';
      case ScanJobStatus.queued:
        return '排队中';
      case ScanJobStatus.reconstructing:
        return '处理中';
      case ScanJobStatus.training:
        return '训练中';
      case ScanJobStatus.packaging:
        return '导出中';
      case ScanJobStatus.failed:
        return '训练失败';
      case ScanJobStatus.cancelled:
        return '已取消';
    }
  }

  /// Progress fraction for the task-card progress bar. Null means
  /// "indeterminate / terminal state".
  double? get progressValue {
    switch (this) {
      case ScanJobStatus.uploading:
        return 0.16;
      case ScanJobStatus.queued:
        return 0.28;
      case ScanJobStatus.reconstructing:
        return 0.56;
      case ScanJobStatus.training:
        return 0.74;
      case ScanJobStatus.packaging:
        return 0.92;
      case ScanJobStatus.failed:
      case ScanJobStatus.cancelled:
        return null;
    }
  }

  bool get isRunning {
    switch (this) {
      case ScanJobStatus.uploading:
      case ScanJobStatus.queued:
      case ScanJobStatus.reconstructing:
      case ScanJobStatus.training:
      case ScanJobStatus.packaging:
        return true;
      case ScanJobStatus.failed:
      case ScanJobStatus.cancelled:
        return false;
    }
  }

  bool get needsAttention => this == ScanJobStatus.failed;
}

extension ScanJobStatusL10n on ScanJobStatus {
  String localizedTitle(AppL10n l) {
    switch (this) {
      case ScanJobStatus.uploading:
        return l.scanLifecycleUploading;
      case ScanJobStatus.queued:
        return l.scanLifecycleUploading;
      case ScanJobStatus.reconstructing:
        return l.scanLifecycleTraining;
      case ScanJobStatus.training:
        return l.scanLifecycleTraining;
      case ScanJobStatus.packaging:
        return l.scanLifecyclePackaging;
      case ScanJobStatus.failed:
        return l.scanLifecycleFailed;
      case ScanJobStatus.cancelled:
        return l.scanLifecycleFailed;
    }
  }
}

extension CaptureModeL10n on CaptureMode {
  String localizedTitle(AppL10n l) {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return l.captureModeRemoteLegacy;
      case CaptureMode.newRemote:
        return l.captureModeNewRemote;
      case CaptureMode.local:
        return l.captureModeLocal;
    }
  }
}

/// Which capture pipeline produced (or will produce) this record. Mirrors
/// the prototype's AetherCaptureMode. Stays client-side; the backend
/// doesn't see this distinction directly (the upload broker picks the
/// pipeline based on the mode the client selected at capture time).
enum CaptureMode {
  /// Legacy remote pipeline — for backward-compat validation.
  remoteLegacy,

  /// New remote (recommended default). Preview-first, HQ-upgrade flow.
  newRemote,

  /// Local-only pipeline. Runs on-device, fastest feedback, no cloud.
  local,
}

extension CaptureModeLabel on CaptureMode {
  String get title {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '远端方案';
      case CaptureMode.newRemote:
        return '新远端';
      case CaptureMode.local:
        return '本地方案';
    }
  }

  String get subtitle {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '兼容旧版云端高质量处理链路，适合对照验证。';
      case CaptureMode.newRemote:
        return '对象模式 Beta，先出 Preview，再升级成 Default 与 HQ。';
      case CaptureMode.local:
        return '本地扫描链路，适合快速验证、低延迟预览和离线调试。';
    }
  }

  String get detailTitle {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '适合继续跑远端兼容性样本';
      case CaptureMode.newRemote:
        return '适合作为新版主入口';
      case CaptureMode.local:
        return '适合现场快速确认采集效果';
    }
  }

  String get detailBody {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return '拍摄完成后走旧版远端处理，结果稳定，但反馈速度相对慢一些。';
      case CaptureMode.newRemote:
        return '拍摄后系统会优先返回 Preview，方便先做质量判断，再等待更高质量版本。';
      case CaptureMode.local:
        return '拍摄结束后优先保留本地成果，适合不稳定网络环境或临时验证。';
    }
  }

  String? get shortBadge {
    switch (this) {
      case CaptureMode.newRemote:
        return '推荐';
      case CaptureMode.remoteLegacy:
      case CaptureMode.local:
        return null;
    }
  }

  IconData get icon {
    switch (this) {
      case CaptureMode.remoteLegacy:
        return Icons.cloud_outlined;
      case CaptureMode.newRemote:
        return Icons.auto_awesome_rounded;
      case CaptureMode.local:
        return Icons.phone_iphone_rounded;
    }
  }
}

/// One scan, either in flight or finished. Immutable data container;
/// ViewModels hold lists of these.
@immutable
class ScanRecord {
  final String id;
  final String name;
  final DateTime createdAt;
  final ScanJobStatus? jobStatus;
  final String? pipelineStage;
  final String? failureMessage;
  final CaptureMode preferredCaptureMode;

  /// Null for now (no real image pipeline). Kept so ScanRecordCell can
  /// branch on it and the eventual backend integration has a landing
  /// spot without a schema change.
  final String? thumbnailPath;

  /// Null until the cloud job writes a viewer-ready artifact (glb / ply
  /// / mesh bundle). Drives the "已完成 / 待查看" UI branch.
  final String? artifactPath;

  /// Author display handle. Mock data for the social-feed demo; real
  /// production records would resolve this from the cloud author lookup.
  final String? authorHandle;

  /// Author one-line caption shown under the work title in the social
  /// feed. Free-form user-authored text; **not** translated (treated like
  /// the work name itself).
  final String? caption;

  /// Bundled GLB asset (under `assets/models/`) the viewer should load
  /// when this card is tapped. Null = no preview model yet (e.g. job
  /// still running). Used by Vault → CapturePage(viewer mode) to swap
  /// the Dawn scene without spinning up a new IOSurface.
  final String? bundledGlbAsset;

  const ScanRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    this.jobStatus,
    this.pipelineStage,
    this.failureMessage,
    this.preferredCaptureMode = CaptureMode.newRemote,
    this.thumbnailPath,
    this.artifactPath,
    this.authorHandle,
    this.caption,
    this.bundledGlbAsset,
  });

  bool get isRunningTask => jobStatus?.isRunning ?? false;
  bool get needsAttention => jobStatus?.needsAttention ?? false;
  bool get hasCompletedArtifact => artifactPath != null;

  String get lifecycleTitle {
    if (jobStatus == null) {
      return artifactPath == null ? '待查看' : '已完成';
    }
    return jobStatus!.zhTitle;
  }

  /// Localized lifecycle label — replaces lifecycleTitle in user-visible
  /// surfaces. lifecycleTitle (zh-only) is kept for legacy callers /
  /// debug logs only.
  String localizedLifecycleTitle(AppL10n l) {
    if (jobStatus == null) {
      return artifactPath == null
          ? l.scanLifecyclePending
          : l.scanLifecycleCompleted;
    }
    return jobStatus!.localizedTitle(l);
  }

  String get taskStatusDescription {
    if (jobStatus == null) {
      return artifactPath == null ? '结果尚未可查看。' : '结果已可查看。';
    }
    switch (jobStatus!) {
      case ScanJobStatus.uploading:
        return '素材正在上传，上传完成后会自动进入后续处理。';
      case ScanJobStatus.queued:
        return '任务已提交，正在等待处理资源。';
      case ScanJobStatus.reconstructing:
        return '系统正在整理素材并建立几何基础结果。';
      case ScanJobStatus.training:
        return '系统正在生成预览或训练更高质量结果。';
      case ScanJobStatus.packaging:
        return '系统正在导出可查看文件，马上就绪。';
      case ScanJobStatus.failed:
        return failureMessage ?? '任务未产出可用结果，建议查看原因后重新拍摄。';
      case ScanJobStatus.cancelled:
        return '任务已取消，本次流程不会继续执行。';
    }
  }
}
