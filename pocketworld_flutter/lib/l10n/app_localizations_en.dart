// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appBrand => 'PocketWorld';

  @override
  String get splashSubtitle => '3D capture · minimalist workbench';

  @override
  String get splashRestoringSession => 'Restoring session…';

  @override
  String get splashPreparingSignIn => 'Preparing sign-in…';

  @override
  String get splashWaking3DEngine => 'Waking 3D engine…';

  @override
  String get splashRendererUnavailable => 'Renderer unavailable, retrying…';

  @override
  String get splashLoadingMesh => 'Loading 3D model…';

  @override
  String get splashAlmostReady => 'Almost ready';

  @override
  String get tabCommunity => 'Community';

  @override
  String get tabMe => 'Me';

  @override
  String get communitySummaryRunning => 'Running';

  @override
  String get communitySummaryAttention => 'Attention';

  @override
  String get communityLoading => 'Loading works';

  @override
  String get communityEmptyTitle => 'No works yet';

  @override
  String get communitySearchHint => 'Search works';

  @override
  String get communityTabHot => 'Hot';

  @override
  String get communityTabNearby => 'Nearby';

  @override
  String get communityTabDiscover => 'Discover';

  @override
  String get communityNearbyComingSoon => 'Nearby is coming soon — stay tuned.';

  @override
  String get meMyWorks => 'My works';

  @override
  String get meMyWorksEmpty =>
      'No works yet — tap the camera to start your first capture.';

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
  String get scanStatusUploading => 'Uploading';

  @override
  String get scanStatusTraining => 'Training';

  @override
  String get scanStatusPackaging => 'Exporting';

  @override
  String get scanStatusFailed => 'Failed';

  @override
  String get scanStatusCompleted => 'Completed';

  @override
  String get scanStatusPending => 'Pending review';

  @override
  String get scanLifecycleCompleted => 'Completed';

  @override
  String get scanLifecyclePending => 'Pending review';

  @override
  String get scanLifecycleFailed => 'Failed';

  @override
  String get scanLifecycleTraining => 'Training';

  @override
  String get scanLifecyclePackaging => 'Exporting';

  @override
  String get scanLifecycleUploading => 'Uploading';

  @override
  String get scanSampleHelmetName => 'Sample · Helmet';

  @override
  String scanRecordOpenPlaceholder(String name) {
    return 'Opening \"$name\" (viewer not wired)';
  }

  @override
  String get relativeJustNow => 'just now';

  @override
  String relativeMinutesAgo(int n) {
    return '$n min ago';
  }

  @override
  String relativeHoursAgo(int n) {
    return '$n h ago';
  }

  @override
  String relativeDaysAgo(int n) {
    return '$n d ago';
  }

  @override
  String relativeWeeksAgo(int n) {
    return '$n w ago';
  }

  @override
  String relativeMonthsAgo(int n) {
    return '$n mo ago';
  }

  @override
  String get meSettingsTitle => 'Settings';

  @override
  String get meEdit => 'Edit';

  @override
  String get meWorks => 'Works';

  @override
  String get meRunning => 'Running';

  @override
  String get meRemainingCloudTrainings => 'Cloud Credits Left';

  @override
  String get meCloudSync => 'Cloud Sync';

  @override
  String meCloudSyncSubtitle(String time) {
    return 'Synced · $time';
  }

  @override
  String get meCloudTraining => 'Cloud Training';

  @override
  String meCloudTrainingRemaining(int n) {
    return '$n left';
  }

  @override
  String get meNotifications => 'Notifications';

  @override
  String get meNotificationsOn => 'On';

  @override
  String get mePrivacy => 'Privacy';

  @override
  String get mePrivacyFollowersOnly => 'Followers only';

  @override
  String get meCloudSyncNever => 'Not synced';

  @override
  String get meCloudTrainingNotEnabled => 'Not enabled';

  @override
  String get meNotificationsOff => 'Off';

  @override
  String get mePrivacyPublic => 'Public';

  @override
  String get mePrivacyPrivate => 'Private';

  @override
  String get meSettingNotConfigured => 'Not configured';

  @override
  String get meLanguage => 'Language';

  @override
  String get meLanguageZh => '简体中文';

  @override
  String get meLanguageEn => 'English';

  @override
  String get meAbout => 'About';

  @override
  String get meSignOut => 'Sign out';

  @override
  String get meSignOutConfirmTitle => 'Sign out?';

  @override
  String get meSignOutConfirmBody =>
      'You\'ll need to sign in again to access cloud works.';

  @override
  String get authWelcomeBack => 'Welcome back';

  @override
  String get authCreateAccount => 'Create your account';

  @override
  String get authSignIn => 'Sign in';

  @override
  String get authSignUp => 'Sign up';

  @override
  String get authEmailHint => 'Email';

  @override
  String get authPasswordHint => 'Password';

  @override
  String get authPasswordHintMin => 'Set password (min 8 chars)';

  @override
  String get authDisplayNameHint => 'Display name (optional)';

  @override
  String get authForgotPassword => 'Forgot password?';

  @override
  String get authTermsAcceptance =>
      'By signing up you agree to PocketWorld\'s Terms of Service and Privacy Policy.';

  @override
  String get authErrorDialogTitle => 'Something went wrong';

  @override
  String get otpVerifyTitle => 'Verify your email';

  @override
  String otpVerifySubtitle(String email) {
    return 'We sent a 6-digit code to $email. Enter it below to finish signing up.';
  }

  @override
  String get otpInputHint => '6-digit code';

  @override
  String get otpVerify => 'Verify';

  @override
  String get otpVerifying => 'Verifying…';

  @override
  String get otpResend => 'Resend code';

  @override
  String otpResendCooldown(int seconds) {
    return 'Resend in ${seconds}s';
  }

  @override
  String get otpResendSent => 'Code re-sent';

  @override
  String get otpInvalidCode => 'Invalid or expired code';

  @override
  String get otpUseAnotherEmail => 'Use a different email';

  @override
  String get resetTitle => 'Reset password';

  @override
  String get resetSubtitleEnterEmail =>
      'Enter your email and we\'ll send you a 6-digit verification code.';

  @override
  String resetSubtitleEnterCode(String email) {
    return 'We sent a 6-digit code to $email. Enter it together with your new password.';
  }

  @override
  String get resetSendCode => 'Send code';

  @override
  String get resetNewPasswordHint => 'New password (min 8 chars)';

  @override
  String get resetConfirm => 'Reset password';

  @override
  String get captureRecording => 'Recording';

  @override
  String get captureRecBadge => 'REC';

  @override
  String get captureViewerTitleFallback => 'Viewer';

  @override
  String get captureModeLocal => 'Local';

  @override
  String get captureModeRemoteLegacy => 'Remote';

  @override
  String get captureModeNewRemote => 'New Remote';

  @override
  String get captureToolFlash => 'Flash';

  @override
  String get captureToolGrid => 'Grid';

  @override
  String get captureToolTimer => 'Timer';

  @override
  String get captureToolHdr => 'HDR';

  @override
  String get captureToolCloudTraining => 'Cloud Training';

  @override
  String get captureRecordGallery => 'Gallery';

  @override
  String get captureRecordSettings => 'Settings';

  @override
  String get captureRecordTapToStart => 'Tap to record';

  @override
  String get captureRecordTapToStop => 'Tap to stop';

  @override
  String get captureRecordRestart => 'Restart';

  @override
  String get captureGuidanceCenterSubject =>
      'Center the subject in the frame, then orbit it slowly.';

  @override
  String get captureGuidanceFramesCaptured => 'Captured';

  @override
  String get captureGuidanceCoverage => 'Coverage';

  @override
  String get captureGuidanceStability => 'Stable';

  @override
  String get captureGuidanceHardRejects => 'Rejects';

  @override
  String captureNotImplemented(String feature) {
    return '$feature is not connected yet (placeholder)';
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
  String get captureModePageTitle => 'Capture mode';

  @override
  String get captureModePageHero =>
      'Pick which capture pipeline runs this time.';

  @override
  String get captureModePageStep1 => 'Pick mode';

  @override
  String get captureModePageStep2 => 'Confirm entry';

  @override
  String get captureModePageStep3 => 'Start capturing';

  @override
  String get captureModePageWillHappen => 'What happens after you confirm';

  @override
  String get languageDialogTitle => 'Language';

  @override
  String get languageDialogChinese => '简体中文 (Chinese)';

  @override
  String get languageDialogEnglish => 'English';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonOk => 'OK';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonRetrying => 'Retrying…';
}
