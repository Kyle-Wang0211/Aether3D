// MyWorkDetailPage — full-screen viewer for one of the user's OWN
// scans, plus the publish-to-community workflow.
//
// Three states the page handles:
//   • running — job is still queued/reconstructing/training/packaging.
//                Shows a spinner with the lifecycle status; no GLB yet.
//   • viewable — artifactPath points at a local file:// URL. Renders
//                LiveModelView (orbit on, manipulator drives camera).
//                "Publish" button is enabled.
//   • failed — job came back failed; shows reason + a retry-from-this-
//                record button (TODO; v1 just shows the message).
//
// Publish flow:
//   tap publish action → bottom sheet with title (1..100, required) and
//   description (0..5000, optional) → tap confirm → PublishService
//   uploads the GLB to `works/<uid>/<recordId>.glb` and inserts a
//   `works` row with visibility='public' and published_at=now(). On
//   success the page re-renders with a "published" pill instead of the
//   button; tap that pill to edit/unpublish.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../me/publish_service.dart';
import '../../me/scan_record_store.dart';
import '../community/live_model_view.dart';
import '../design_system.dart';
import '../scan_record.dart';

class MyWorkDetailPage extends StatefulWidget {
  final String recordId;

  const MyWorkDetailPage({super.key, required this.recordId});

  @override
  State<MyWorkDetailPage> createState() => _MyWorkDetailPageState();
}

class _MyWorkDetailPageState extends State<MyWorkDetailPage> {
  late final ScanRecordStore _store = ScanRecordStore.instance;
  StreamSubscription<List<ScanRecord>>? _sub;
  ScanRecord? _record;

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
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody(r)),
            _buildBottomBar(r, l),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ScanRecord r) {
    if (r.jobStatus == ScanJobStatus.failed) {
      return _FailedState(message: r.failureMessage);
    }
    if (r.isRunningTask) {
      return _RunningState(record: r);
    }
    final url = r.artifactPath;
    if (url == null) {
      return const _RunningState();
    }
    return LiveModelView(
      key: ValueKey('mywork-${r.id}'),
      modelUrl: url,
      interactive: true,
      cameraDistance: 5.0,
    );
  }

  Widget _buildBottomBar(ScanRecord r, AppL10n l) {
    final canPublish =
        r.artifactPath != null && r.jobStatus == null && !r.needsAttention;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: AetherColors.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              r.publishedWorkId == null
                  ? l.meDetailVisibilityPrivate
                  : l.meDetailPublishedBadge,
              style: AetherTextStyles.bodySm,
            ),
          ),
          if (r.publishedWorkId == null)
            FilledButton(
              onPressed: canPublish ? () => _openPublishSheet(r) : null,
              style: FilledButton.styleFrom(
                backgroundColor: AetherColors.primary,
                disabledBackgroundColor: AetherColors.borderStrong,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AetherRadii.pill),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              child: Text(l.meDetailActionPublish,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            )
          else
            OutlinedButton(
              onPressed: () => _openPublishSheet(r),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AetherRadii.pill),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                side: const BorderSide(color: AetherColors.border),
              ),
              child: Text(l.meDetailActionEdit,
                  style: const TextStyle(
                    color: AetherColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  )),
            ),
        ],
      ),
    );
  }

  Future<void> _openPublishSheet(ScanRecord r) async {
    final result = await showModalBottomSheet<_PublishFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _PublishForm(record: r),
    );
    if (result == null || !mounted) return;
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (r.publishedWorkId == null) {
        await PublishService.instance.publish(
          record: r,
          title: result.title,
          description: result.description,
        );
        messenger.showSnackBar(SnackBar(
          content: Text(l.meDetailToastPublished),
          behavior: SnackBarBehavior.floating,
        ));
      } else {
        await PublishService.instance.editPublished(
          workId: r.publishedWorkId!,
          title: result.title,
          description: result.description,
          recordId: r.id,
        );
        messenger.showSnackBar(SnackBar(
          content: Text(l.meDetailToastUpdated),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } on PublishException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(l.meDetailToastPublishFailed(e.detail ?? e.code)),
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(l.meDetailToastPublishFailed(e.toString())),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

class _PublishFormResult {
  final String title;
  final String? description;
  const _PublishFormResult({required this.title, this.description});
}

class _PublishForm extends StatefulWidget {
  final ScanRecord record;

  const _PublishForm({required this.record});

  @override
  State<_PublishForm> createState() => _PublishFormState();
}

class _PublishFormState extends State<_PublishForm> {
  late final TextEditingController _titleCtrl =
      TextEditingController(text: widget.record.name);
  late final TextEditingController _descCtrl =
      TextEditingController(text: widget.record.caption ?? '');
  final _formKey = GlobalKey<FormState>();
  bool _submitting = false;

  static const int _maxTitle = 100;
  static const int _maxDescription = 5000;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final isEdit = widget.record.publishedWorkId != null;
    final viewInsets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Form(
        key: _formKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AetherColors.border,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                isEdit ? l.meDetailSheetTitleEdit : l.meDetailSheetTitlePublish,
                style: AetherTextStyles.h2,
              ),
              const SizedBox(height: 6),
              Text(
                isEdit
                    ? l.meDetailSheetSubtitleEdit
                    : l.meDetailSheetSubtitlePublish,
                style: AetherTextStyles.bodySm,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _titleCtrl,
                maxLength: _maxTitle,
                textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: l.meDetailLabelTitle,
                  hintText: l.meDetailHintTitle,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AetherRadii.md),
                  ),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.isEmpty) return l.meDetailValidationTitleEmpty;
                  if (t.length > _maxTitle) {
                    return l.meDetailValidationTitleTooLong(_maxTitle);
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descCtrl,
                maxLines: 5,
                maxLength: _maxDescription,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  labelText: l.meDetailLabelDescription,
                  hintText: l.meDetailHintDescription(_maxDescription),
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AetherRadii.md),
                  ),
                ),
                validator: (v) {
                  final t = v?.trim() ?? '';
                  if (t.length > _maxDescription) {
                    return l.meDetailValidationDescriptionTooLong(
                        _maxDescription);
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _submitting ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AetherColors.primary,
                    disabledBackgroundColor: AetherColors.borderStrong,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AetherRadii.pill),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          ),
                        )
                      : Text(
                          isEdit
                              ? l.meDetailButtonSave
                              : l.meDetailButtonPublish,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    Navigator.of(context).pop(_PublishFormResult(
      title: _titleCtrl.text.trim(),
      description:
          _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
    ));
  }
}

class _RunningState extends StatelessWidget {
  final ScanRecord? record;
  const _RunningState({this.record});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final stage =
        record?.jobStatus?.localizedTitle(l) ?? l.meDetailRunningProcessing;
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
          Text(stage, style: AetherTextStyles.bodySm),
          if (record?.pipelineStage != null) ...[
            const SizedBox(height: 4),
            Text(record!.pipelineStage!, style: AetherTextStyles.caption),
          ],
        ],
      ),
    );
  }
}

class _FailedState extends StatelessWidget {
  final String? message;
  const _FailedState({this.message});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AetherSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              size: 56,
              color: AetherColors.danger,
            ),
            const SizedBox(height: AetherSpacing.md),
            Text(
              l.meDetailFailedTitle,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AetherColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            if (message != null)
              Text(
                message!,
                textAlign: TextAlign.center,
                style: AetherTextStyles.bodySm,
              ),
          ],
        ),
      ),
    );
  }
}
