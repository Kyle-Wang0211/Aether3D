// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppL10nZh extends AppL10n {
  AppL10nZh([String locale = 'zh']) : super(locale);

  @override
  String get appBrand => '方寸间';

  @override
  String get splashSubtitle => '三维捕捉 · 极简工作台';

  @override
  String get splashRestoringSession => '正在恢复会话…';

  @override
  String get splashPreparingSignIn => '准备登录界面…';

  @override
  String get splashWaking3DEngine => '正在唤醒 3D 引擎…';

  @override
  String get splashRendererUnavailable => '渲染器不可用，即将进入重试';

  @override
  String get splashLoadingMesh => '正在加载 3D 模型…';

  @override
  String get splashAlmostReady => '即将就绪';

  @override
  String get tabCommunity => '社区';

  @override
  String get tabMe => '我';

  @override
  String get communitySummaryRunning => '进行中';

  @override
  String get communitySummaryAttention => '待处理';

  @override
  String get communityLoading => '正在加载作品';

  @override
  String get communityEmptyTitle => '社区还没有作品';

  @override
  String get meMyWorks => '我的作品';

  @override
  String get meMyWorksEmpty => '还没有作品 —— 点右下角的相机开始第一次扫描。';

  @override
  String communityRecordSubtitle(String owner, String time) {
    return '$owner · $time';
  }

  @override
  String communityRecordSubtitleWithStatus(
    String owner,
    String time,
    String status,
  ) {
    return '$owner · $time · $status';
  }

  @override
  String get scanStatusUploading => '上传中';

  @override
  String get scanStatusTraining => '训练中';

  @override
  String get scanStatusPackaging => '导出中';

  @override
  String get scanStatusFailed => '失败';

  @override
  String get scanStatusCompleted => '已完成';

  @override
  String get scanStatusPending => '待查看';

  @override
  String get scanLifecycleCompleted => '已完成';

  @override
  String get scanLifecyclePending => '待查看';

  @override
  String get scanLifecycleFailed => '失败';

  @override
  String get scanLifecycleTraining => '训练中';

  @override
  String get scanLifecyclePackaging => '导出中';

  @override
  String get scanLifecycleUploading => '上传中';

  @override
  String get scanSampleHelmetName => '样板 · 头盔';

  @override
  String scanRecordOpenPlaceholder(String name) {
    return '打开「$name」（查看器待接入）';
  }

  @override
  String get relativeJustNow => '刚刚';

  @override
  String relativeMinutesAgo(int n) {
    return '$n 分钟前';
  }

  @override
  String relativeHoursAgo(int n) {
    return '$n 小时前';
  }

  @override
  String relativeDaysAgo(int n) {
    return '$n 天前';
  }

  @override
  String relativeWeeksAgo(int n) {
    return '$n 周前';
  }

  @override
  String relativeMonthsAgo(int n) {
    return '$n 个月前';
  }

  @override
  String get meSettingsTitle => '设置';

  @override
  String get meEdit => '编辑';

  @override
  String get meWorks => '作品';

  @override
  String get meRunning => '进行中';

  @override
  String get meRemainingCloudTrainings => '云训练额度';

  @override
  String get meCloudSync => '云端同步';

  @override
  String meCloudSyncSubtitle(String time) {
    return '已同步 · $time';
  }

  @override
  String get meCloudTraining => '云训练';

  @override
  String meCloudTrainingRemaining(int n) {
    return '剩 $n 次';
  }

  @override
  String get meNotifications => '通知';

  @override
  String get meNotificationsOn => '开启';

  @override
  String get mePrivacy => '隐私';

  @override
  String get mePrivacyFollowersOnly => '仅粉丝可见';

  @override
  String get meCloudSyncNever => '未同步';

  @override
  String get meCloudTrainingNotEnabled => '暂未开通';

  @override
  String get meNotificationsOff => '已关闭';

  @override
  String get mePrivacyPublic => '公开';

  @override
  String get mePrivacyPrivate => '仅自己可见';

  @override
  String get meSettingNotConfigured => '未配置';

  @override
  String get meLanguage => '语言';

  @override
  String get meLanguageZh => '简体中文';

  @override
  String get meLanguageEn => 'English';

  @override
  String get meAbout => '关于';

  @override
  String get meSignOut => '退出登录';

  @override
  String get meSignOutConfirmTitle => '退出登录？';

  @override
  String get meSignOutConfirmBody => '退出后需要重新登录才能访问云端作品。';

  @override
  String get authWelcomeBack => '欢迎回来';

  @override
  String get authCreateAccount => '创建你的账号';

  @override
  String get authSignIn => '登录';

  @override
  String get authSignUp => '注册';

  @override
  String get authEmailHint => '邮箱';

  @override
  String get authPasswordHint => '密码';

  @override
  String get authPasswordHintMin => '设置密码（至少 8 位）';

  @override
  String get authDisplayNameHint => '昵称（可选）';

  @override
  String get authForgotPassword => '忘记密码？';

  @override
  String get authTermsAcceptance => '注册即表示你同意方寸间的服务条款与隐私政策。';

  @override
  String get authErrorDialogTitle => '出错了';

  @override
  String get otpVerifyTitle => '验证邮箱';

  @override
  String otpVerifySubtitle(String email) {
    return '我们已向 $email 发送 6 位验证码，请在下方输入完成注册。';
  }

  @override
  String get otpInputHint => '6 位验证码';

  @override
  String get otpVerify => '验证';

  @override
  String get otpVerifying => '验证中…';

  @override
  String get otpResend => '重新发送';

  @override
  String otpResendCooldown(int seconds) {
    return '$seconds 秒后可重发';
  }

  @override
  String get otpResendSent => '已重新发送';

  @override
  String get otpInvalidCode => '验证码错误或已过期';

  @override
  String get otpUseAnotherEmail => '换一个邮箱';

  @override
  String get resetTitle => '重置密码';

  @override
  String get resetSubtitleEnterEmail => '输入你的邮箱，我们会发送 6 位验证码';

  @override
  String resetSubtitleEnterCode(String email) {
    return '我们已向 $email 发送 6 位验证码，请连同新密码一起输入';
  }

  @override
  String get resetSendCode => '发送验证码';

  @override
  String get resetNewPasswordHint => '新密码（至少 8 位）';

  @override
  String get resetConfirm => '重置密码';

  @override
  String get captureRecording => '正在采集';

  @override
  String get captureRecBadge => 'REC';

  @override
  String get captureViewerTitleFallback => '查看';

  @override
  String get captureModeLocal => '本地方案';

  @override
  String get captureModeRemoteLegacy => '远程方案';

  @override
  String get captureModeNewRemote => '新远程方案';

  @override
  String get captureToolFlash => '闪光';

  @override
  String get captureToolGrid => '网格';

  @override
  String get captureToolTimer => '延时';

  @override
  String get captureToolHdr => 'HDR';

  @override
  String get captureToolCloudTraining => '云训练';

  @override
  String get captureRecordGallery => '相册';

  @override
  String get captureRecordSettings => '参数';

  @override
  String get captureRecordTapToStart => '点击开始录制';

  @override
  String get captureRecordTapToStop => '点击停止';

  @override
  String get captureRecordRestart => '重新开始';

  @override
  String get captureGuidanceCenterSubject => '将物体放在画面中央，开始后沿着主体缓慢绕一圈。';

  @override
  String get captureGuidanceFramesCaptured => '已采集';

  @override
  String get captureGuidanceCoverage => '完整度';

  @override
  String get captureGuidanceStability => '稳定';

  @override
  String get captureGuidanceHardRejects => '硬拒';

  @override
  String captureNotImplemented(String feature) {
    return '$feature 尚未接通（占位）';
  }

  @override
  String get captureErrorNoCamera => 'No camera available on this device';

  @override
  String get captureErrorPermissionDenied =>
      'Camera permission denied. Please enable it in Settings.';

  @override
  String captureErrorInitFailedCode(String code) {
    return 'Camera initialization failed: $code';
  }

  @override
  String captureErrorInitFailedGeneric(String error) {
    return 'Camera initialization failed: $error';
  }

  @override
  String get captureSnackFootageTooShort =>
      'Too little footage — keep recording a bit longer before stopping.';

  @override
  String captureSnackStartFailed(String error) {
    return 'Couldn\'t start recording: $error';
  }

  @override
  String get captureUploadErrorNoConcurrentRecording =>
      'This device can\'t record video while scanning — nothing to upload.';

  @override
  String get captureUploadOverlayTooShortTitle => 'Footage too short';

  @override
  String get captureUploadOverlayTooShortSubtitle =>
      'Keep recording a bit longer next time.';

  @override
  String get captureUploadOverlayFailedTitle => 'Upload failed';

  @override
  String get captureUploadOverlayDoneTitle => 'Uploaded';

  @override
  String captureUploadOverlayJobSubtitle(String jobId) {
    return 'jobId · $jobId';
  }

  @override
  String get captureUploadPhasePreparingTitle => 'Preparing';

  @override
  String get captureUploadPhaseCreatingJobTitle => 'Registering job';

  @override
  String get captureUploadPhaseUploadingVideoTitle => 'Uploading video';

  @override
  String get captureUploadPhaseUploadingCuratedTitle => 'Uploading manifest';

  @override
  String get captureUploadPhaseGenericTitle => 'Uploading';

  @override
  String get captureUploadDetailPreparing => 'Preparing upload…';

  @override
  String get captureUploadDetailPickingFrames =>
      'Picking the best frames to upload';

  @override
  String captureUploadDetailRegisteringJob(int frames) {
    return 'Registering with the cloud ($frames frames)';
  }

  @override
  String captureUploadDetailUploadingVideo(String sentMb, String totalMb) {
    return '$sentMb MB / $totalMb MB';
  }

  @override
  String captureUploadDetailUploadingCurated(int bytes) {
    return '$bytes B';
  }

  @override
  String get captureModePageTitle => '拍摄方案';

  @override
  String get captureModePageHero => '先决定这次走哪条采集链路';

  @override
  String get captureModePageStep1 => '选方案';

  @override
  String get captureModePageStep2 => '确认入口';

  @override
  String get captureModePageStep3 => '开始拍摄';

  @override
  String get captureModePageWillHappen => '确认后会发生什么';

  @override
  String get languageDialogTitle => '语言';

  @override
  String get languageDialogChinese => '简体中文';

  @override
  String get languageDialogEnglish => 'English';

  @override
  String get commonCancel => '取消';

  @override
  String get commonOk => '确定';

  @override
  String get commonConfirm => '确认';

  @override
  String get commonRetry => '重试';

  @override
  String get commonRetrying => '重试中…';
}
