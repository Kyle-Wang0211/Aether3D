import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// Brand wordmark — English
  ///
  /// In en, this message translates to:
  /// **'PocketWorld'**
  String get appBrand;

  /// No description provided for @splashSubtitle.
  ///
  /// In en, this message translates to:
  /// **'3D capture · minimalist workbench'**
  String get splashSubtitle;

  /// No description provided for @splashRestoringSession.
  ///
  /// In en, this message translates to:
  /// **'Restoring session…'**
  String get splashRestoringSession;

  /// No description provided for @splashPreparingSignIn.
  ///
  /// In en, this message translates to:
  /// **'Preparing sign-in…'**
  String get splashPreparingSignIn;

  /// No description provided for @splashWaking3DEngine.
  ///
  /// In en, this message translates to:
  /// **'Waking 3D engine…'**
  String get splashWaking3DEngine;

  /// No description provided for @splashRendererUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Renderer unavailable, retrying…'**
  String get splashRendererUnavailable;

  /// No description provided for @splashLoadingMesh.
  ///
  /// In en, this message translates to:
  /// **'Loading 3D model…'**
  String get splashLoadingMesh;

  /// No description provided for @splashAlmostReady.
  ///
  /// In en, this message translates to:
  /// **'Almost ready'**
  String get splashAlmostReady;

  /// No description provided for @tabCommunity.
  ///
  /// In en, this message translates to:
  /// **'Community'**
  String get tabCommunity;

  /// No description provided for @tabMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get tabMe;

  /// No description provided for @communitySummaryRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get communitySummaryRunning;

  /// No description provided for @communitySummaryAttention.
  ///
  /// In en, this message translates to:
  /// **'Attention'**
  String get communitySummaryAttention;

  /// No description provided for @communityLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading works'**
  String get communityLoading;

  /// No description provided for @communityEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No works yet'**
  String get communityEmptyTitle;

  /// No description provided for @communitySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search works'**
  String get communitySearchHint;

  /// No description provided for @communityTabHot.
  ///
  /// In en, this message translates to:
  /// **'Hot'**
  String get communityTabHot;

  /// No description provided for @communityTabNearby.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get communityTabNearby;

  /// No description provided for @communityTabDiscover.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get communityTabDiscover;

  /// No description provided for @communityNearbyComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Nearby is coming soon — stay tuned.'**
  String get communityNearbyComingSoon;

  /// No description provided for @meMyWorks.
  ///
  /// In en, this message translates to:
  /// **'My works'**
  String get meMyWorks;

  /// No description provided for @meMyWorksEmpty.
  ///
  /// In en, this message translates to:
  /// **'No works yet — tap the camera to start your first capture.'**
  String get meMyWorksEmpty;

  /// No description provided for @communityRecordSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{owner} · {time}'**
  String communityRecordSubtitle(String owner, String time);

  /// No description provided for @communityRecordSubtitleWithStatus.
  ///
  /// In en, this message translates to:
  /// **'{owner} · {time} · {status}'**
  String communityRecordSubtitleWithStatus(
    String owner,
    String time,
    String status,
  );

  /// No description provided for @scanStatusUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading'**
  String get scanStatusUploading;

  /// No description provided for @scanStatusTraining.
  ///
  /// In en, this message translates to:
  /// **'Training'**
  String get scanStatusTraining;

  /// No description provided for @scanStatusPackaging.
  ///
  /// In en, this message translates to:
  /// **'Exporting'**
  String get scanStatusPackaging;

  /// No description provided for @scanStatusFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get scanStatusFailed;

  /// No description provided for @scanStatusCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get scanStatusCompleted;

  /// No description provided for @scanStatusPending.
  ///
  /// In en, this message translates to:
  /// **'Pending review'**
  String get scanStatusPending;

  /// No description provided for @scanLifecycleCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get scanLifecycleCompleted;

  /// No description provided for @scanLifecyclePending.
  ///
  /// In en, this message translates to:
  /// **'Pending review'**
  String get scanLifecyclePending;

  /// No description provided for @scanLifecycleFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get scanLifecycleFailed;

  /// No description provided for @scanLifecycleTraining.
  ///
  /// In en, this message translates to:
  /// **'Training'**
  String get scanLifecycleTraining;

  /// No description provided for @scanLifecyclePackaging.
  ///
  /// In en, this message translates to:
  /// **'Exporting'**
  String get scanLifecyclePackaging;

  /// No description provided for @scanLifecycleUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading'**
  String get scanLifecycleUploading;

  /// No description provided for @scanSampleHelmetName.
  ///
  /// In en, this message translates to:
  /// **'Sample · Helmet'**
  String get scanSampleHelmetName;

  /// No description provided for @scanRecordOpenPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Opening \"{name}\" (viewer not wired)'**
  String scanRecordOpenPlaceholder(String name);

  /// No description provided for @relativeJustNow.
  ///
  /// In en, this message translates to:
  /// **'just now'**
  String get relativeJustNow;

  /// No description provided for @relativeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} min ago'**
  String relativeMinutesAgo(int n);

  /// No description provided for @relativeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} h ago'**
  String relativeHoursAgo(int n);

  /// No description provided for @relativeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} d ago'**
  String relativeDaysAgo(int n);

  /// No description provided for @relativeWeeksAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} w ago'**
  String relativeWeeksAgo(int n);

  /// No description provided for @relativeMonthsAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} mo ago'**
  String relativeMonthsAgo(int n);

  /// No description provided for @meSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get meSettingsTitle;

  /// No description provided for @meSyncAddedWorks.
  ///
  /// In en, this message translates to:
  /// **'Synced {n} new work(s)'**
  String meSyncAddedWorks(int n);

  /// No description provided for @meSyncUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Already up to date'**
  String get meSyncUpToDate;

  /// No description provided for @meSyncFailed.
  ///
  /// In en, this message translates to:
  /// **'Sync failed'**
  String get meSyncFailed;

  /// No description provided for @meEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get meEdit;

  /// No description provided for @meWorks.
  ///
  /// In en, this message translates to:
  /// **'Works'**
  String get meWorks;

  /// No description provided for @meRunning.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get meRunning;

  /// No description provided for @meRemainingCloudTrainings.
  ///
  /// In en, this message translates to:
  /// **'Cloud Credits Left'**
  String get meRemainingCloudTrainings;

  /// No description provided for @meCloudSync.
  ///
  /// In en, this message translates to:
  /// **'Cloud Sync'**
  String get meCloudSync;

  /// No description provided for @meCloudSyncSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Synced · {time}'**
  String meCloudSyncSubtitle(String time);

  /// No description provided for @meCloudTraining.
  ///
  /// In en, this message translates to:
  /// **'Cloud Training'**
  String get meCloudTraining;

  /// No description provided for @meCloudTrainingRemaining.
  ///
  /// In en, this message translates to:
  /// **'{n} left'**
  String meCloudTrainingRemaining(int n);

  /// No description provided for @meNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get meNotifications;

  /// No description provided for @meNotificationsOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get meNotificationsOn;

  /// No description provided for @mePrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get mePrivacy;

  /// No description provided for @mePrivacyFollowersOnly.
  ///
  /// In en, this message translates to:
  /// **'Followers only'**
  String get mePrivacyFollowersOnly;

  /// No description provided for @meCloudSyncNever.
  ///
  /// In en, this message translates to:
  /// **'Not synced'**
  String get meCloudSyncNever;

  /// No description provided for @meCloudTrainingNotEnabled.
  ///
  /// In en, this message translates to:
  /// **'Not enabled'**
  String get meCloudTrainingNotEnabled;

  /// No description provided for @meNotificationsOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get meNotificationsOff;

  /// No description provided for @mePrivacyPublic.
  ///
  /// In en, this message translates to:
  /// **'Public'**
  String get mePrivacyPublic;

  /// No description provided for @mePrivacyPrivate.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get mePrivacyPrivate;

  /// No description provided for @meSettingNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Not configured'**
  String get meSettingNotConfigured;

  /// No description provided for @meLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get meLanguage;

  /// No description provided for @meLanguageZh.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get meLanguageZh;

  /// No description provided for @meLanguageEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get meLanguageEn;

  /// No description provided for @meAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get meAbout;

  /// No description provided for @meSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get meSignOut;

  /// No description provided for @meSignOutConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out?'**
  String get meSignOutConfirmTitle;

  /// No description provided for @meSignOutConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'You\'ll need to sign in again to access cloud works.'**
  String get meSignOutConfirmBody;

  /// No description provided for @authWelcomeBack.
  ///
  /// In en, this message translates to:
  /// **'Welcome back'**
  String get authWelcomeBack;

  /// No description provided for @authCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create your account'**
  String get authCreateAccount;

  /// No description provided for @authSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get authSignIn;

  /// No description provided for @authSignUp.
  ///
  /// In en, this message translates to:
  /// **'Sign up'**
  String get authSignUp;

  /// No description provided for @authEmailHint.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get authEmailHint;

  /// No description provided for @authPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get authPasswordHint;

  /// No description provided for @authPasswordHintMin.
  ///
  /// In en, this message translates to:
  /// **'Set password (min 8 chars)'**
  String get authPasswordHintMin;

  /// No description provided for @authDisplayNameHint.
  ///
  /// In en, this message translates to:
  /// **'Display name (optional)'**
  String get authDisplayNameHint;

  /// No description provided for @authForgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get authForgotPassword;

  /// No description provided for @authTermsAcceptance.
  ///
  /// In en, this message translates to:
  /// **'By signing up you agree to PocketWorld\'s Terms of Service and Privacy Policy.'**
  String get authTermsAcceptance;

  /// No description provided for @authErrorDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong'**
  String get authErrorDialogTitle;

  /// No description provided for @otpVerifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify your email'**
  String get otpVerifyTitle;

  /// No description provided for @otpVerifySubtitle.
  ///
  /// In en, this message translates to:
  /// **'We sent a 6-digit code to {email}. Enter it below to finish signing up.'**
  String otpVerifySubtitle(String email);

  /// No description provided for @otpInputHint.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get otpInputHint;

  /// No description provided for @otpVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get otpVerify;

  /// No description provided for @otpVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying…'**
  String get otpVerifying;

  /// No description provided for @otpResend.
  ///
  /// In en, this message translates to:
  /// **'Resend code'**
  String get otpResend;

  /// No description provided for @otpResendCooldown.
  ///
  /// In en, this message translates to:
  /// **'Resend in {seconds}s'**
  String otpResendCooldown(int seconds);

  /// No description provided for @otpResendSent.
  ///
  /// In en, this message translates to:
  /// **'Code re-sent'**
  String get otpResendSent;

  /// No description provided for @otpInvalidCode.
  ///
  /// In en, this message translates to:
  /// **'Invalid or expired code'**
  String get otpInvalidCode;

  /// No description provided for @otpUseAnotherEmail.
  ///
  /// In en, this message translates to:
  /// **'Use a different email'**
  String get otpUseAnotherEmail;

  /// No description provided for @resetTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetTitle;

  /// No description provided for @resetSubtitleEnterEmail.
  ///
  /// In en, this message translates to:
  /// **'Enter your email and we\'ll send you a 6-digit verification code.'**
  String get resetSubtitleEnterEmail;

  /// No description provided for @resetSubtitleEnterCode.
  ///
  /// In en, this message translates to:
  /// **'We sent a 6-digit code to {email}. Enter it together with your new password.'**
  String resetSubtitleEnterCode(String email);

  /// No description provided for @resetSendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get resetSendCode;

  /// No description provided for @resetNewPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'New password (min 8 chars)'**
  String get resetNewPasswordHint;

  /// No description provided for @resetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset password'**
  String get resetConfirm;

  /// No description provided for @captureRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get captureRecording;

  /// No description provided for @captureRecBadge.
  ///
  /// In en, this message translates to:
  /// **'REC'**
  String get captureRecBadge;

  /// No description provided for @captureViewerTitleFallback.
  ///
  /// In en, this message translates to:
  /// **'Viewer'**
  String get captureViewerTitleFallback;

  /// No description provided for @captureModeLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get captureModeLocal;

  /// No description provided for @captureModeRemoteLegacy.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get captureModeRemoteLegacy;

  /// No description provided for @captureModeNewRemote.
  ///
  /// In en, this message translates to:
  /// **'New Remote'**
  String get captureModeNewRemote;

  /// No description provided for @captureToolFlash.
  ///
  /// In en, this message translates to:
  /// **'Flash'**
  String get captureToolFlash;

  /// No description provided for @captureToolGrid.
  ///
  /// In en, this message translates to:
  /// **'Grid'**
  String get captureToolGrid;

  /// No description provided for @captureToolTimer.
  ///
  /// In en, this message translates to:
  /// **'Timer'**
  String get captureToolTimer;

  /// No description provided for @captureToolHdr.
  ///
  /// In en, this message translates to:
  /// **'HDR'**
  String get captureToolHdr;

  /// No description provided for @captureToolCloudTraining.
  ///
  /// In en, this message translates to:
  /// **'Cloud Training'**
  String get captureToolCloudTraining;

  /// No description provided for @captureRecordGallery.
  ///
  /// In en, this message translates to:
  /// **'Gallery'**
  String get captureRecordGallery;

  /// No description provided for @captureRecordSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get captureRecordSettings;

  /// No description provided for @captureRecordTapToStart.
  ///
  /// In en, this message translates to:
  /// **'Tap to record'**
  String get captureRecordTapToStart;

  /// No description provided for @captureRecordTapToStop.
  ///
  /// In en, this message translates to:
  /// **'Tap to stop'**
  String get captureRecordTapToStop;

  /// No description provided for @captureRecordRestart.
  ///
  /// In en, this message translates to:
  /// **'Restart'**
  String get captureRecordRestart;

  /// No description provided for @captureGuidanceCenterSubject.
  ///
  /// In en, this message translates to:
  /// **'Center the subject in the frame, then orbit it slowly.'**
  String get captureGuidanceCenterSubject;

  /// No description provided for @captureGuidanceFramesCaptured.
  ///
  /// In en, this message translates to:
  /// **'Captured'**
  String get captureGuidanceFramesCaptured;

  /// No description provided for @captureGuidanceCoverage.
  ///
  /// In en, this message translates to:
  /// **'Coverage'**
  String get captureGuidanceCoverage;

  /// No description provided for @captureGuidanceStability.
  ///
  /// In en, this message translates to:
  /// **'Stable'**
  String get captureGuidanceStability;

  /// No description provided for @captureGuidanceHardRejects.
  ///
  /// In en, this message translates to:
  /// **'Rejects'**
  String get captureGuidanceHardRejects;

  /// No description provided for @captureNotImplemented.
  ///
  /// In en, this message translates to:
  /// **'{feature} is not connected yet (placeholder)'**
  String captureNotImplemented(String feature);

  /// No description provided for @captureErrorNoCamera.
  ///
  /// In en, this message translates to:
  /// **'No camera available on this device'**
  String get captureErrorNoCamera;

  /// No description provided for @captureErrorPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera permission denied. Please enable it in Settings.'**
  String get captureErrorPermissionDenied;

  /// No description provided for @captureErrorInitFailedCode.
  ///
  /// In en, this message translates to:
  /// **'Camera initialization failed: {code}'**
  String captureErrorInitFailedCode(String code);

  /// No description provided for @captureErrorInitFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'Camera initialization failed: {error}'**
  String captureErrorInitFailedGeneric(String error);

  /// No description provided for @captureSnackFootageTooShort.
  ///
  /// In en, this message translates to:
  /// **'Too little footage — keep recording a bit longer before stopping.'**
  String get captureSnackFootageTooShort;

  /// No description provided for @captureSnackStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t start recording: {error}'**
  String captureSnackStartFailed(String error);

  /// No description provided for @captureUploadErrorNoConcurrentRecording.
  ///
  /// In en, this message translates to:
  /// **'This device can\'t record video while scanning — nothing to upload.'**
  String get captureUploadErrorNoConcurrentRecording;

  /// No description provided for @captureUploadOverlayTooShortTitle.
  ///
  /// In en, this message translates to:
  /// **'Footage too short'**
  String get captureUploadOverlayTooShortTitle;

  /// No description provided for @captureUploadOverlayTooShortSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Keep recording a bit longer next time.'**
  String get captureUploadOverlayTooShortSubtitle;

  /// No description provided for @captureUploadOverlayFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get captureUploadOverlayFailedTitle;

  /// No description provided for @captureUploadOverlayDoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Uploaded'**
  String get captureUploadOverlayDoneTitle;

  /// No description provided for @captureUploadOverlayJobSubtitle.
  ///
  /// In en, this message translates to:
  /// **'jobId · {jobId}'**
  String captureUploadOverlayJobSubtitle(String jobId);

  /// No description provided for @captureUploadPhasePreparingTitle.
  ///
  /// In en, this message translates to:
  /// **'Preparing'**
  String get captureUploadPhasePreparingTitle;

  /// No description provided for @captureUploadPhaseCreatingJobTitle.
  ///
  /// In en, this message translates to:
  /// **'Registering job'**
  String get captureUploadPhaseCreatingJobTitle;

  /// No description provided for @captureUploadPhaseUploadingVideoTitle.
  ///
  /// In en, this message translates to:
  /// **'Uploading video'**
  String get captureUploadPhaseUploadingVideoTitle;

  /// No description provided for @captureUploadPhaseUploadingCuratedTitle.
  ///
  /// In en, this message translates to:
  /// **'Uploading manifest'**
  String get captureUploadPhaseUploadingCuratedTitle;

  /// No description provided for @captureUploadPhaseGenericTitle.
  ///
  /// In en, this message translates to:
  /// **'Uploading'**
  String get captureUploadPhaseGenericTitle;

  /// No description provided for @captureUploadDetailPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing upload…'**
  String get captureUploadDetailPreparing;

  /// No description provided for @captureUploadDetailPickingFrames.
  ///
  /// In en, this message translates to:
  /// **'Picking the best frames to upload'**
  String get captureUploadDetailPickingFrames;

  /// No description provided for @captureUploadDetailRegisteringJob.
  ///
  /// In en, this message translates to:
  /// **'Registering with the cloud ({frames} frames)'**
  String captureUploadDetailRegisteringJob(int frames);

  /// No description provided for @captureUploadDetailUploadingVideo.
  ///
  /// In en, this message translates to:
  /// **'{sentMb} MB / {totalMb} MB'**
  String captureUploadDetailUploadingVideo(String sentMb, String totalMb);

  /// No description provided for @captureUploadDetailUploadingCurated.
  ///
  /// In en, this message translates to:
  /// **'{bytes} B'**
  String captureUploadDetailUploadingCurated(int bytes);

  /// No description provided for @captureModePageTitle.
  ///
  /// In en, this message translates to:
  /// **'Capture mode'**
  String get captureModePageTitle;

  /// No description provided for @captureModePageHero.
  ///
  /// In en, this message translates to:
  /// **'Pick which capture pipeline runs this time.'**
  String get captureModePageHero;

  /// No description provided for @captureModePageStep1.
  ///
  /// In en, this message translates to:
  /// **'Pick mode'**
  String get captureModePageStep1;

  /// No description provided for @captureModePageStep2.
  ///
  /// In en, this message translates to:
  /// **'Confirm entry'**
  String get captureModePageStep2;

  /// No description provided for @captureModePageStep3.
  ///
  /// In en, this message translates to:
  /// **'Start capturing'**
  String get captureModePageStep3;

  /// No description provided for @captureModePageWillHappen.
  ///
  /// In en, this message translates to:
  /// **'What happens after you confirm'**
  String get captureModePageWillHappen;

  /// No description provided for @languageDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageDialogTitle;

  /// No description provided for @languageDialogChinese.
  ///
  /// In en, this message translates to:
  /// **'简体中文 (Chinese)'**
  String get languageDialogChinese;

  /// No description provided for @languageDialogEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageDialogEnglish;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonOk.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get commonOk;

  /// No description provided for @commonConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get commonConfirm;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonRetrying.
  ///
  /// In en, this message translates to:
  /// **'Retrying…'**
  String get commonRetrying;
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppL10nEn();
    case 'zh':
      return AppL10nZh();
  }

  throw FlutterError(
    'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
