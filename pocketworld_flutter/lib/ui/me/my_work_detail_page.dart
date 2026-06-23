// MyWorkDetailPage — full-screen viewer for one of the user's OWN
// scans, plus the publish-to-community workflow.
//
// Three states the page handles:
//   • running — no artifact yet; shows a processing placeholder.
//   • viewable — artifactPath points at a local file:// URL. Renders the
//                aether_cpp viewer (orbit + pinch). "Publish" is enabled
//                when signed in AND not already published.
//   • published — cloudWorkId is set; the publish action shows "已发布".
//
// Publish flow (re-introduced 2026-06-23 per
//   docs/superpowers/specs/2026-06-23-publish-to-community-design.md):
//   tap publish → _PublishForm bottom sheet (title + optional desc) →
//   capture a thumbnail frame from the live viewer → PublishService
//   orchestrates normalize → upload → insert → thumbnail → mark the
//   local record cloudWorkId → success SnackBar.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../community/publish_service.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../community/aether_cpp_card_demo.dart';
import '../community/viewer_impl.dart';
import '../design_system.dart';
import '../scan_record.dart';

class MyWorkDetailPage extends StatefulWidget {
  final String recordId;

  /// Injectable for tests; defaults to a fresh PublishService wired to
  /// the live Supabase client + a fresh CommunityService.
  final PublishService? publishService;

  const MyWorkDetailPage({
    super.key,
    required this.recordId,
    this.publishService,
  });

  @override
  State<MyWorkDetailPage> createState() => _MyWorkDetailPageState();
}

class _MyWorkDetailPageState extends State<MyWorkDetailPage> {
  late final ScanRecordStore _store = ScanRecordStore.instance;
  late final PublishService _publishService =
      widget.publishService ?? PublishService();
  StreamSubscription<List<ScanRecord>>? _sub;
  ScanRecord? _record;

  /// Live viewer captured via onViewerReady — used to snapshot a
  /// thumbnail frame at publish time.
  AetherCppViewerImpl? _viewer;

  /// Double-tap / re-entry guard.
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _record = _store.byId(widget.recordId);
    _sub = _store.changes.listen((_) {
      final fresh = _store.byId(widget.recordId);
      if (mounted && fresh != null) setState(() => _record = fresh);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get _canPublish {
    final r = _record;
    if (r == null) return false;
    return r.artifactPath != null &&
        r.cloudWorkId == null &&
        Supabase.instance.client.auth.currentUser != null;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final r = _record;
    if (r == null) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(backgroundColor: Colors.white, elevation: 0),
        body: Center(child: Text(l.meDetailRecordNotFound)),
      );
    }
    final published = r.cloudWorkId != null;
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded,
              color: AetherColors.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          r.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AetherColors.textPrimary,
          ),
        ),
        centerTitle: true,
        actions: [
          if (r.artifactPath != null)
            if (published)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: Text(
                    l.meDetailPublished,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AetherColors.textSecondary,
                    ),
                  ),
                ),
              )
            else
              TextButton(
                onPressed: _canPublish && !_publishing ? _onPublishTap : null,
                child: Text(
                  l.meDetailPublish,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
        ],
      ),
      body: SafeArea(child: _buildBody(r)),
    );
  }

  Widget _buildBody(ScanRecord r) {
    final url = r.artifactPath;
    if (url == null) {
      // "No artifact yet" = the local W3 pipeline hasn't run on this
      // capture's photos directory; show a generic processing placeholder.
      return const _RunningState();
    }
    return AetherCppCardDemo(
      key: ValueKey('mywork-aether-${r.id}'),
      modelUrl: url,
      interactive: true,
      onViewerReady: (viewer) => _viewer = viewer,
    );
  }

  Future<void> _onPublishTap() async {
    final r = _record;
    if (r == null || !_canPublish || _publishing) return;

    final formResult = await showModalBottomSheet<_PublishFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PublishForm(defaultTitle: r.name),
    );
    if (formResult == null || !mounted) return;

    await _runPublish(
      record: r,
      title: formResult.title,
      description: formResult.description,
    );
  }

  Future<void> _runPublish({
    required ScanRecord record,
    required String title,
    String? description,
  }) async {
    if (_publishing) return;
    setState(() => _publishing = true);

    final l = AppL10n.of(context);
    final progress = ValueNotifier<PublishProgress>(
      const PublishProgress(phase: 'reading', fraction: 0.0),
    );
    // Non-dismissible modal progress overlay.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PublishProgressDialog(progress: progress),
    ));

    PublishResult? result;
    Object? error;
    try {
      // Best-effort thumbnail from the live viewer's last-seen frame.
      Uint8List? jpeg;
      try {
        jpeg = await _viewer?.captureThumb(quality: 0.85);
      } catch (_) {
        jpeg = null;
      }

      result = await _publishService.publish(
        record: record,
        title: title,
        description: description,
        thumbnailJpeg: jpeg,
        onProgress: (p) => progress.value = p,
      );
    } catch (e) {
      error = e;
    }

    // Dismiss the progress dialog.
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    progress.dispose();

    if (!mounted) {
      _publishing = false;
      return;
    }

    if (result != null) {
      // Mark the local record published so the button flips to "已发布".
      final cur = _store.byId(record.id);
      if (cur != null) {
        await _store.addOrUpdate(cur.copyWith(cloudWorkId: result.workId));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.meDetailPublishSuccess)),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_publishErrorMessage(l, error))),
      );
    }

    if (mounted) setState(() => _publishing = false);
  }

  String _publishErrorMessage(AppL10n l, Object? error) {
    if (error is PublishException) {
      switch (error.phase) {
        case 'reading':
          return l.meDetailPublishErrorReading;
        case 'normalizing':
          return l.meDetailPublishErrorNormalizing;
        case 'uploading':
          return l.meDetailPublishErrorUploading;
        case 'inserting':
          return l.meDetailPublishErrorGeneric;
      }
    }
    return l.meDetailPublishErrorGeneric;
  }
}

/// Result returned by [_PublishForm].
class _PublishFormResult {
  final String title;
  final String? description;
  const _PublishFormResult({required this.title, this.description});
}

/// Modal bottom sheet collecting the work title (required, 1–100 chars)
/// and an optional description (≤5000 chars).
class _PublishForm extends StatefulWidget {
  final String defaultTitle;
  const _PublishForm({required this.defaultTitle});

  @override
  State<_PublishForm> createState() => _PublishFormState();
}

class _PublishFormState extends State<_PublishForm> {
  late final TextEditingController _titleCtrl =
      TextEditingController(text: widget.defaultTitle);
  final TextEditingController _descCtrl = TextEditingController();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  bool get _titleValid {
    final t = _titleCtrl.text.trim();
    return t.isNotEmpty && t.length <= 100;
  }

  void _submit() {
    final title = _titleCtrl.text.trim();
    final desc = _descCtrl.text.trim();
    Navigator.of(context).pop(
      _PublishFormResult(
        title: title,
        description: desc.isEmpty ? null : desc,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + bottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.meDetailPublishFormTitle,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AetherColors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleCtrl,
            maxLength: 100,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l.meDetailPublishTitleLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _descCtrl,
            maxLength: 5000,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: l.meDetailPublishDescLabel,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.meDetailPublishCancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _titleValid ? _submit : null,
                  child: Text(l.meDetailPublishConfirm),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Non-dismissible modal progress overlay driven by [PublishProgress].
class _PublishProgressDialog extends StatelessWidget {
  final ValueListenable<PublishProgress> progress;
  const _PublishProgressDialog({required this.progress});

  static String _label(AppL10n l, PublishProgress p) {
    switch (p.phase) {
      case 'reading':
        return l.meDetailPublishPhaseReading;
      case 'normalizing':
        return p.detail == null
            ? l.meDetailPublishPhaseNormalizing
            : l.meDetailPublishPhaseNormalizingDetail(p.detail!);
      case 'uploading':
        return l.meDetailPublishPhaseUploading;
      case 'inserting':
        return l.meDetailPublishPhaseInserting;
      case 'thumbnail':
        return l.meDetailPublishPhaseThumbnail;
      case 'done':
        return l.meDetailPublishPhaseDone;
      default:
        return l.meDetailPublishPhaseProcessing;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ValueListenableBuilder<PublishProgress>(
            valueListenable: progress,
            builder: (context, p, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _label(l, p),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AetherColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: p.fraction.clamp(0.0, 1.0),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RunningState extends StatelessWidget {
  const _RunningState();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: AetherSpacing.md),
          Text(l.meDetailRunningProcessing, style: AetherTextStyles.bodySm),
        ],
      ),
    );
  }
}
