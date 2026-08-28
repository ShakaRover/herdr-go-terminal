import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'generated/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
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
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

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

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'HerdrGo'**
  String get appName;

  /// No description provided for @allBridges.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get allBridges;

  /// No description provided for @settingsTooltip.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;

  /// No description provided for @switchSessionTooltip.
  ///
  /// In en, this message translates to:
  /// **'Switch session'**
  String get switchSessionTooltip;

  /// No description provided for @defaultSession.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get defaultSession;

  /// No description provided for @sessionSummary.
  ///
  /// In en, this message translates to:
  /// **'{name} ({blocked} waiting / {working} working)'**
  String sessionSummary(String name, int blocked, int working);

  /// No description provided for @connectionsInterrupted.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 connection interrupted} other{{count} connections interrupted}}'**
  String connectionsInterrupted(int count);

  /// No description provided for @easyTierConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the EasyTier network…'**
  String get easyTierConnecting;

  /// No description provided for @easyTierFailed.
  ///
  /// In en, this message translates to:
  /// **'EasyTier connection failed ({error})'**
  String easyTierFailed(String error);

  /// No description provided for @virtualIpTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timed out waiting for a virtual IP ({seconds}s)'**
  String virtualIpTimeout(int seconds);

  /// No description provided for @networkUnreachable.
  ///
  /// In en, this message translates to:
  /// **'Network unreachable'**
  String get networkUnreachable;

  /// No description provided for @connectionTimeout.
  ///
  /// In en, this message translates to:
  /// **'Connection timed out'**
  String get connectionTimeout;

  /// No description provided for @sendTimeout.
  ///
  /// In en, this message translates to:
  /// **'Send timed out'**
  String get sendTimeout;

  /// No description provided for @responseTimeout.
  ///
  /// In en, this message translates to:
  /// **'Response timed out'**
  String get responseTimeout;

  /// No description provided for @transferTimeout.
  ///
  /// In en, this message translates to:
  /// **'Transfer timed out'**
  String get transferTimeout;

  /// No description provided for @badCertificate.
  ///
  /// In en, this message translates to:
  /// **'TLS certificate validation failed'**
  String get badCertificate;

  /// No description provided for @serverError.
  ///
  /// In en, this message translates to:
  /// **'Server error'**
  String get serverError;

  /// No description provided for @requestCancelled.
  ///
  /// In en, this message translates to:
  /// **'Request cancelled'**
  String get requestCancelled;

  /// No description provided for @networkError.
  ///
  /// In en, this message translates to:
  /// **'Network error'**
  String get networkError;

  /// No description provided for @invalidJsonResponse.
  ///
  /// In en, this message translates to:
  /// **'Response is not a JSON object'**
  String get invalidJsonResponse;

  /// No description provided for @connectionInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Connection interrupted. Showing the last data ({error})'**
  String connectionInterrupted(String error);

  /// No description provided for @herdrOffline.
  ///
  /// In en, this message translates to:
  /// **'Herdr is offline (the bridge cannot reach the Herdr server)'**
  String get herdrOffline;

  /// No description provided for @readOnlyMode.
  ///
  /// In en, this message translates to:
  /// **'This device is not authorized to write (read-only mode)'**
  String get readOnlyMode;

  /// No description provided for @bridgeConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to the bridge…'**
  String get bridgeConnecting;

  /// No description provided for @noAgents.
  ///
  /// In en, this message translates to:
  /// **'No agents detected\nStart one in Herdr on your computer and it will appear here.'**
  String get noAgents;

  /// No description provided for @noDevicesTitle.
  ///
  /// In en, this message translates to:
  /// **'No computers connected'**
  String get noDevicesTitle;

  /// No description provided for @noDevicesHelp.
  ///
  /// In en, this message translates to:
  /// **'Add a computer to see and control its Herdr agents.'**
  String get noDevicesHelp;

  /// No description provided for @addDevice.
  ///
  /// In en, this message translates to:
  /// **'Add computer'**
  String get addDevice;

  /// No description provided for @sectionPinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get sectionPinned;

  /// No description provided for @sectionNeedsAttention.
  ///
  /// In en, this message translates to:
  /// **'Needs your attention'**
  String get sectionNeedsAttention;

  /// No description provided for @sectionWorking.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get sectionWorking;

  /// No description provided for @sectionOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get sectionOther;

  /// No description provided for @statusBlocked.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get statusBlocked;

  /// No description provided for @statusWorking.
  ///
  /// In en, this message translates to:
  /// **'Working'**
  String get statusWorking;

  /// No description provided for @statusDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get statusDone;

  /// No description provided for @statusIdle.
  ///
  /// In en, this message translates to:
  /// **'Idle'**
  String get statusIdle;

  /// No description provided for @statusUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown'**
  String get statusUnknown;

  /// No description provided for @relativeJustNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get relativeJustNow;

  /// No description provided for @relativeMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 minute ago} other{{count} minutes ago}}'**
  String relativeMinutesAgo(int count);

  /// No description provided for @relativeHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 hour ago} other{{count} hours ago}}'**
  String relativeHoursAgo(int count);

  /// No description provided for @relativeDaysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 day ago} other{{count} days ago}}'**
  String relativeDaysAgo(int count);

  /// No description provided for @pendingDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'A dialog is waiting on screen'**
  String get pendingDialogTitle;

  /// No description provided for @pendingDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Sending Enter directly may select the highlighted option. You can continue if you intend to answer its free-text option.'**
  String get pendingDialogBody;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @sendAnyway.
  ///
  /// In en, this message translates to:
  /// **'Send anyway'**
  String get sendAnyway;

  /// No description provided for @commonClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get commonClose;

  /// No description provided for @unknownError.
  ///
  /// In en, this message translates to:
  /// **'Unknown error'**
  String get unknownError;

  /// No description provided for @sent.
  ///
  /// In en, this message translates to:
  /// **'Sent'**
  String get sent;

  /// No description provided for @screenChangedRetry.
  ///
  /// In en, this message translates to:
  /// **'The screen changed. Check the latest output and try again.'**
  String get screenChangedRetry;

  /// No description provided for @screenChangedShort.
  ///
  /// In en, this message translates to:
  /// **'The screen changed. Try again.'**
  String get screenChangedShort;

  /// No description provided for @screenChangedOpenDetails.
  ///
  /// In en, this message translates to:
  /// **'The screen changed. Open details to confirm.'**
  String get screenChangedOpenDetails;

  /// No description provided for @textDeliveredWarning.
  ///
  /// In en, this message translates to:
  /// **'Text was entered, but Enter did not take effect. Do not resend it before checking the output.'**
  String get textDeliveredWarning;

  /// No description provided for @sendFailed.
  ///
  /// In en, this message translates to:
  /// **'Send failed: {error}'**
  String sendFailed(String error);

  /// No description provided for @keyFailed.
  ///
  /// In en, this message translates to:
  /// **'Key failed: {error}'**
  String keyFailed(String error);

  /// No description provided for @imageUploaded.
  ///
  /// In en, this message translates to:
  /// **'Image uploaded and its path was added to the reply.'**
  String get imageUploaded;

  /// No description provided for @uploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed: {error}'**
  String uploadFailed(String error);

  /// No description provided for @uploadFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get uploadFailedShort;

  /// No description provided for @sendFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Send failed'**
  String get sendFailedShort;

  /// No description provided for @aliasCleared.
  ///
  /// In en, this message translates to:
  /// **'Alias cleared'**
  String get aliasCleared;

  /// No description provided for @renamed.
  ///
  /// In en, this message translates to:
  /// **'Renamed'**
  String get renamed;

  /// No description provided for @renameFailed.
  ///
  /// In en, this message translates to:
  /// **'Rename failed: {error}'**
  String renameFailed(String error);

  /// No description provided for @renameFailedShort.
  ///
  /// In en, this message translates to:
  /// **'Rename failed'**
  String get renameFailedShort;

  /// No description provided for @refreshTooltip.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refreshTooltip;

  /// No description provided for @renameTooltip.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get renameTooltip;

  /// No description provided for @historyTooltip.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get historyTooltip;

  /// No description provided for @outputRefreshFailed.
  ///
  /// In en, this message translates to:
  /// **'Output refresh failed. Showing old data ({error})'**
  String outputRefreshFailed(String error);

  /// No description provided for @readingOutput.
  ///
  /// In en, this message translates to:
  /// **'Reading output…'**
  String get readingOutput;

  /// No description provided for @sendImageTooltip.
  ///
  /// In en, this message translates to:
  /// **'Send image'**
  String get sendImageTooltip;

  /// No description provided for @replyHint.
  ///
  /// In en, this message translates to:
  /// **'Reply to agent…'**
  String get replyHint;

  /// No description provided for @renameAgentTitle.
  ///
  /// In en, this message translates to:
  /// **'Rename agent'**
  String get renameAgentTitle;

  /// No description provided for @renameAgentHelper.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to clear the alias and restore the default name'**
  String get renameAgentHelper;

  /// No description provided for @commonConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get commonConfirm;

  /// No description provided for @continueEnter.
  ///
  /// In en, this message translates to:
  /// **'Continue (Enter)'**
  String get continueEnter;

  /// No description provided for @bridgeNotConfigured.
  ///
  /// In en, this message translates to:
  /// **'Bridge connection is not configured'**
  String get bridgeNotConfigured;

  /// No description provided for @unpinned.
  ///
  /// In en, this message translates to:
  /// **'Unpinned'**
  String get unpinned;

  /// No description provided for @pinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

  /// No description provided for @unpinTooltip.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpinTooltip;

  /// No description provided for @pinTooltip.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get pinTooltip;

  /// No description provided for @readOnlyCannotRename.
  ///
  /// In en, this message translates to:
  /// **'Cannot rename in read-only mode'**
  String get readOnlyCannotRename;

  /// No description provided for @openDetails.
  ///
  /// In en, this message translates to:
  /// **'Open details'**
  String get openDetails;

  /// No description provided for @readFailed.
  ///
  /// In en, this message translates to:
  /// **'Read failed: {error}'**
  String readFailed(String error);

  /// No description provided for @historyTitle.
  ///
  /// In en, this message translates to:
  /// **'History · {title}'**
  String historyTitle(String title);

  /// No description provided for @historyDisabled.
  ///
  /// In en, this message translates to:
  /// **'History is disabled on the bridge (COLLIE_TRANSCRIPT)'**
  String get historyDisabled;

  /// No description provided for @historyNoSession.
  ///
  /// In en, this message translates to:
  /// **'This agent has no session log'**
  String get historyNoSession;

  /// No description provided for @historyNoLog.
  ///
  /// In en, this message translates to:
  /// **'The log file for this session was not found'**
  String get historyNoLog;

  /// No description provided for @historyUnavailable.
  ///
  /// In en, this message translates to:
  /// **'History unavailable: {reason}'**
  String historyUnavailable(String reason);

  /// No description provided for @loadFailed.
  ///
  /// In en, this message translates to:
  /// **'Load failed: {error}'**
  String loadFailed(String error);

  /// No description provided for @historyTruncated.
  ///
  /// In en, this message translates to:
  /// **'The log is too large; only the tail was parsed'**
  String get historyTruncated;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get loading;

  /// No description provided for @loadOlder.
  ///
  /// In en, this message translates to:
  /// **'Load earlier'**
  String get loadOlder;

  /// No description provided for @roleYou.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get roleYou;

  /// No description provided for @roleAgent.
  ///
  /// In en, this message translates to:
  /// **'Agent'**
  String get roleAgent;

  /// No description provided for @roleSummary.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get roleSummary;

  /// No description provided for @roleSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get roleSystem;

  /// No description provided for @connectionSettings.
  ///
  /// In en, this message translates to:
  /// **'Connection settings'**
  String get connectionSettings;

  /// No description provided for @devices.
  ///
  /// In en, this message translates to:
  /// **'Computers'**
  String get devices;

  /// No description provided for @remoteBridge.
  ///
  /// In en, this message translates to:
  /// **'Remote bridges (scan to pair)'**
  String get remoteBridge;

  /// No description provided for @scanToAdd.
  ///
  /// In en, this message translates to:
  /// **'Scan to add'**
  String get scanToAdd;

  /// No description provided for @notPaired.
  ///
  /// In en, this message translates to:
  /// **'No bridge is paired yet. Scan the pairing QR code printed when herdrgo-bridge starts to connect through the EasyTier virtual network.'**
  String get notPaired;

  /// No description provided for @deviceAlias.
  ///
  /// In en, this message translates to:
  /// **'Device alias'**
  String get deviceAlias;

  /// No description provided for @displayNameHint.
  ///
  /// In en, this message translates to:
  /// **'Display name'**
  String get displayNameHint;

  /// No description provided for @commonDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get commonDelete;

  /// No description provided for @deleteConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete configuration'**
  String get deleteConfigTitle;

  /// No description provided for @deleteConfigBody.
  ///
  /// In en, this message translates to:
  /// **'Delete “{label}” ({ip})?'**
  String deleteConfigBody(String label, String ip);

  /// No description provided for @profileAdded.
  ///
  /// In en, this message translates to:
  /// **'Added: {label}'**
  String profileAdded(String label);

  /// No description provided for @editAliasTooltip.
  ///
  /// In en, this message translates to:
  /// **'Edit alias'**
  String get editAliasTooltip;

  /// No description provided for @deleteTooltip.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get deleteTooltip;

  /// No description provided for @bridgeEnableHelp.
  ///
  /// In en, this message translates to:
  /// **'Use each switch to control whether that bridge connects. Enable multiple bridges for multi-host mode.'**
  String get bridgeEnableHelp;

  /// No description provided for @computerSetup.
  ///
  /// In en, this message translates to:
  /// **'Set up your computer'**
  String get computerSetup;

  /// No description provided for @pluginSetupHelp.
  ///
  /// In en, this message translates to:
  /// **'Install the HerdrGo Plugin on the computer running Herdr, start its bridge service, then display the pairing QR code.'**
  String get pluginSetupHelp;

  /// No description provided for @pluginPairAgainHelp.
  ///
  /// In en, this message translates to:
  /// **'To display the pairing QR code again later:'**
  String get pluginPairAgainHelp;

  /// No description provided for @pluginInstallGuide.
  ///
  /// In en, this message translates to:
  /// **'View the full website guide'**
  String get pluginInstallGuide;

  /// No description provided for @deploymentHelp.
  ///
  /// In en, this message translates to:
  /// **'Setup help'**
  String get deploymentHelp;

  /// No description provided for @openLinkFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the website'**
  String get openLinkFailed;

  /// No description provided for @otherSettings.
  ///
  /// In en, this message translates to:
  /// **'Other settings'**
  String get otherSettings;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get privacyPolicy;

  /// No description provided for @technicalSupport.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get technicalSupport;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @terminalAutoResize.
  ///
  /// In en, this message translates to:
  /// **'Fit terminal output to phone'**
  String get terminalAutoResize;

  /// No description provided for @terminalAutoResizeHelp.
  ///
  /// In en, this message translates to:
  /// **'Temporarily control the shared Herdr terminal while an agent is open, then return control when you leave. Turn this off to always keep the computer\'s terminal width.'**
  String get terminalAutoResizeHelp;

  /// No description provided for @terminalFontSize.
  ///
  /// In en, this message translates to:
  /// **'Terminal text size'**
  String get terminalFontSize;

  /// No description provided for @terminalFontSizeHelp.
  ///
  /// In en, this message translates to:
  /// **'Pinch the terminal output with two fingers, or adjust it here.'**
  String get terminalFontSizeHelp;

  /// No description provided for @terminalFontSizeReset.
  ///
  /// In en, this message translates to:
  /// **'Reset terminal text size'**
  String get terminalFontSizeReset;

  /// No description provided for @diagnostics.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics'**
  String get diagnostics;

  /// No description provided for @diagnosticLogging.
  ///
  /// In en, this message translates to:
  /// **'EasyTier diagnostic logs'**
  String get diagnosticLogging;

  /// No description provided for @diagnosticLoggingHelp.
  ///
  /// In en, this message translates to:
  /// **'Keep detailed connection logs for troubleshooting background and network reconnection issues.'**
  String get diagnosticLoggingHelp;

  /// No description provided for @diagnosticLoggingDetailsTitle.
  ///
  /// In en, this message translates to:
  /// **'About diagnostic logs'**
  String get diagnosticLoggingDetailsTitle;

  /// No description provided for @diagnosticLoggingDetails.
  ///
  /// In en, this message translates to:
  /// **'Logging is off by default. When enabled, HerdrGo keeps up to four 5 MB files in Documents/Diagnostics and excludes them from iCloud Backup. The logs may contain IP addresses and peer IDs, but HerdrGo does not add pairing secrets or terminal content.\n\nConnect and trust this iPhone or iPad to download the app container with Xcode on your Mac, or use Share logs below. iOS suspends ordinary apps in the background, so no new events can be recorded while the process is suspended.'**
  String get diagnosticLoggingDetails;

  /// No description provided for @shareDiagnosticLogs.
  ///
  /// In en, this message translates to:
  /// **'Share logs'**
  String get shareDiagnosticLogs;

  /// No description provided for @clearDiagnosticLogs.
  ///
  /// In en, this message translates to:
  /// **'Clear logs'**
  String get clearDiagnosticLogs;

  /// No description provided for @clearDiagnosticLogsTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear diagnostic logs?'**
  String get clearDiagnosticLogsTitle;

  /// No description provided for @clearDiagnosticLogsBody.
  ///
  /// In en, this message translates to:
  /// **'This permanently deletes all current and rotated EasyTier diagnostic logs.'**
  String get clearDiagnosticLogsBody;

  /// No description provided for @diagnosticLogsCleared.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic logs cleared'**
  String get diagnosticLogsCleared;

  /// No description provided for @diagnosticLogsError.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic logs failed: {error}'**
  String diagnosticLogsError(String error);

  /// No description provided for @systemLanguage.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get systemLanguage;

  /// No description provided for @simplifiedChinese.
  ///
  /// In en, this message translates to:
  /// **'简体中文'**
  String get simplifiedChinese;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @scanPairingTitle.
  ///
  /// In en, this message translates to:
  /// **'Scan pairing QR code'**
  String get scanPairingTitle;

  /// No description provided for @scanPairingHelp.
  ///
  /// In en, this message translates to:
  /// **'Point the camera at the pairing QR code printed when the bridge starts.'**
  String get scanPairingHelp;

  /// No description provided for @toggleFlashTooltip.
  ///
  /// In en, this message translates to:
  /// **'Toggle flashlight'**
  String get toggleFlashTooltip;

  /// No description provided for @switchCameraTooltip.
  ///
  /// In en, this message translates to:
  /// **'Switch camera'**
  String get switchCameraTooltip;

  /// No description provided for @blockedNotificationTitle.
  ///
  /// In en, this message translates to:
  /// **'{name} needs your attention'**
  String blockedNotificationTitle(String name);

  /// No description provided for @blockedNotificationChannel.
  ///
  /// In en, this message translates to:
  /// **'Agent attention'**
  String get blockedNotificationChannel;

  /// No description provided for @blockedNotificationChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Notifies you when an agent stops and waits for your reply'**
  String get blockedNotificationChannelDescription;

  /// No description provided for @newAgent.
  ///
  /// In en, this message translates to:
  /// **'New agent'**
  String get newAgent;

  /// No description provided for @createAgentTitle.
  ///
  /// In en, this message translates to:
  /// **'Create agent'**
  String get createAgentTitle;

  /// No description provided for @targetComputer.
  ///
  /// In en, this message translates to:
  /// **'Computer'**
  String get targetComputer;

  /// No description provided for @herdrSession.
  ///
  /// In en, this message translates to:
  /// **'Herdr session'**
  String get herdrSession;

  /// No description provided for @agentType.
  ///
  /// In en, this message translates to:
  /// **'Agent type'**
  String get agentType;

  /// No description provided for @agentName.
  ///
  /// In en, this message translates to:
  /// **'Agent name'**
  String get agentName;

  /// No description provided for @agentNameHint.
  ///
  /// In en, this message translates to:
  /// **'Lowercase letters, numbers, - or _'**
  String get agentNameHint;

  /// No description provided for @workspace.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get workspace;

  /// No description provided for @newWorkspace.
  ///
  /// In en, this message translates to:
  /// **'New workspace'**
  String get newWorkspace;

  /// No description provided for @workingDirectory.
  ///
  /// In en, this message translates to:
  /// **'Working directory'**
  String get workingDirectory;

  /// No description provided for @workingDirectoryHint.
  ///
  /// In en, this message translates to:
  /// **'/absolute/path/to/project'**
  String get workingDirectoryHint;

  /// No description provided for @recentDirectories.
  ///
  /// In en, this message translates to:
  /// **'Recent directories'**
  String get recentDirectories;

  /// No description provided for @initialTask.
  ///
  /// In en, this message translates to:
  /// **'Initial task (optional)'**
  String get initialTask;

  /// No description provided for @initialTaskHint.
  ///
  /// In en, this message translates to:
  /// **'What should the agent work on?'**
  String get initialTaskHint;

  /// No description provided for @createAgentAction.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get createAgentAction;

  /// No description provided for @creatingAgent.
  ///
  /// In en, this message translates to:
  /// **'Creating agent…'**
  String get creatingAgent;

  /// No description provided for @noWritableComputer.
  ///
  /// In en, this message translates to:
  /// **'No connected computer is available for creating agents.'**
  String get noWritableComputer;

  /// No description provided for @noAgentTypes.
  ///
  /// In en, this message translates to:
  /// **'Herdr did not report any available agent types.'**
  String get noAgentTypes;

  /// No description provided for @loadCreateAgentOptionsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load agent options: {error}'**
  String loadCreateAgentOptionsFailed(String error);

  /// No description provided for @invalidAgentName.
  ///
  /// In en, this message translates to:
  /// **'Use 1–32 characters: lowercase letters, numbers, - or _; start with a letter.'**
  String get invalidAgentName;

  /// No description provided for @absolutePathRequired.
  ///
  /// In en, this message translates to:
  /// **'Enter an absolute path.'**
  String get absolutePathRequired;

  /// No description provided for @agentCreatePartialTitle.
  ///
  /// In en, this message translates to:
  /// **'The terminal was created, but setup did not finish'**
  String get agentCreatePartialTitle;

  /// No description provided for @agentCreatePartialBody.
  ///
  /// In en, this message translates to:
  /// **'Pane {paneId} was created. Open it to check the actual agent state before retrying.\n\n{error}'**
  String agentCreatePartialBody(String paneId, String error);

  /// No description provided for @openTerminal.
  ///
  /// In en, this message translates to:
  /// **'Open terminal'**
  String get openTerminal;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
