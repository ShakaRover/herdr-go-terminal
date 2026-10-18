// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'HerdrGoT';

  @override
  String get allBridges => 'All';

  @override
  String get settingsTooltip => 'Settings';

  @override
  String get switchSessionTooltip => 'Switch session';

  @override
  String get defaultSession => 'Default';

  @override
  String sessionSummary(String name, int blocked, int working) {
    return '$name ($blocked waiting / $working working)';
  }

  @override
  String connectionsInterrupted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count connections interrupted',
      one: '1 connection interrupted',
    );
    return '$_temp0';
  }

  @override
  String get easyTierConnecting => 'Connecting to the EasyTier network…';

  @override
  String easyTierFailed(String error) {
    return 'EasyTier connection failed ($error)';
  }

  @override
  String virtualIpTimeout(int seconds) {
    return 'Timed out waiting for a virtual IP (${seconds}s)';
  }

  @override
  String get networkUnreachable => 'Network unreachable';

  @override
  String get connectionTimeout => 'Connection timed out';

  @override
  String get sendTimeout => 'Send timed out';

  @override
  String get responseTimeout => 'Response timed out';

  @override
  String get transferTimeout => 'Transfer timed out';

  @override
  String get badCertificate => 'TLS certificate validation failed';

  @override
  String get serverError => 'Server error';

  @override
  String get requestCancelled => 'Request cancelled';

  @override
  String get networkError => 'Network error';

  @override
  String get invalidJsonResponse => 'Response is not a JSON object';

  @override
  String connectionInterrupted(String error) {
    return 'Connection interrupted. Showing the last data ($error)';
  }

  @override
  String get herdrOffline =>
      'Herdr is offline (the bridge cannot reach the Herdr server)';

  @override
  String get readOnlyMode =>
      'This device is not authorized to write (read-only mode)';

  @override
  String get bridgeConnecting => 'Connecting to the bridge…';

  @override
  String get noAgents =>
      'No agents detected\nStart one in Herdr on your computer and it will appear here.';

  @override
  String get noDevicesTitle => 'No computers connected';

  @override
  String get noDevicesHelp =>
      'Add a computer to see and control its Herdr agents.';

  @override
  String get addDevice => 'Add computer';

  @override
  String get addFromString => 'Add from string';

  @override
  String get addFromStringTitle => 'Paste pairing string';

  @override
  String get addFromStringHelp =>
      'On the computer, run `herdr plugin action invoke herdrgo.pair-string` (or `herdrgo-bridge pair --string`) and paste the output here.';

  @override
  String get addFromStringHint => 'Paste the pairing JSON string';

  @override
  String get invalidPairingString => 'Invalid pairing string';

  @override
  String get sectionPinned => 'Pinned';

  @override
  String get sectionNeedsAttention => 'Needs your attention';

  @override
  String get sectionWorking => 'Working';

  @override
  String get sectionOther => 'Other';

  @override
  String get agentsTab => 'Agents';

  @override
  String get spacesTab => 'Spaces';

  @override
  String get noSpaces =>
      'No spaces detected\nCreate a workspace in Herdr on your computer and it will appear here.';

  @override
  String spaceNumber(int number) {
    return 'Space $number';
  }

  @override
  String spaceSummary(int tabs, int panes, int agents) {
    return '$tabs tabs · $panes panes · $agents agents';
  }

  @override
  String spaceWindowNumber(int number) {
    return 'Tab $number';
  }

  @override
  String get spaceWindowUnnamed => 'Tab';

  @override
  String spaceWindowPaneCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count panes',
      one: '1 pane',
    );
    return '$_temp0';
  }

  @override
  String get spaceNoPanes => 'No panes in this tab';

  @override
  String get spaceEmpty => 'This space has no tabs';

  @override
  String get spaceUnavailable => 'This space is no longer available';

  @override
  String get spaceFocused => 'Focused';

  @override
  String get shellPane => 'Shell';

  @override
  String get shellReplyHint => 'Send input…';

  @override
  String get statusBlocked => 'Waiting';

  @override
  String get statusWorking => 'Working';

  @override
  String get statusDone => 'Done';

  @override
  String get statusIdle => 'Idle';

  @override
  String get statusUnknown => 'Unknown';

  @override
  String get relativeJustNow => 'Just now';

  @override
  String relativeMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count minutes ago',
      one: '1 minute ago',
    );
    return '$_temp0';
  }

  @override
  String relativeHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String relativeDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String get pendingDialogTitle => 'A dialog is waiting on screen';

  @override
  String get pendingDialogBody =>
      'Sending Enter directly may select the highlighted option. You can continue if you intend to answer its free-text option.';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get sendAnyway => 'Send anyway';

  @override
  String get commonClose => 'Close';

  @override
  String get unknownError => 'Unknown error';

  @override
  String get sent => 'Sent';

  @override
  String get screenChangedRetry =>
      'The screen changed. Check the latest output and try again.';

  @override
  String get screenChangedShort => 'The screen changed. Try again.';

  @override
  String get screenChangedOpenDetails =>
      'The screen changed. Open details to confirm.';

  @override
  String get textDeliveredWarning =>
      'Text was entered, but Enter did not take effect. Do not resend it before checking the output.';

  @override
  String sendFailed(String error) {
    return 'Send failed: $error';
  }

  @override
  String keyFailed(String error) {
    return 'Key failed: $error';
  }

  @override
  String get imageUploaded =>
      'Image uploaded and its path was added to the reply.';

  @override
  String uploadFailed(String error) {
    return 'Upload failed: $error';
  }

  @override
  String get uploadFailedShort => 'Upload failed';

  @override
  String get sendFailedShort => 'Send failed';

  @override
  String get aliasCleared => 'Alias cleared';

  @override
  String get renamed => 'Renamed';

  @override
  String renameFailed(String error) {
    return 'Rename failed: $error';
  }

  @override
  String get renameFailedShort => 'Rename failed';

  @override
  String get refreshTooltip => 'Refresh';

  @override
  String get renameTooltip => 'Rename';

  @override
  String get historyTooltip => 'History';

  @override
  String outputRefreshFailed(String error) {
    return 'Output refresh failed. Showing old data ($error)';
  }

  @override
  String get readingOutput => 'Reading output…';

  @override
  String get terminalLoadEarlier => 'Load earlier output';

  @override
  String get backToLive => 'Back to live';

  @override
  String get sendImageTooltip => 'Send image';

  @override
  String get replyHint => 'Reply to agent…';

  @override
  String get renameAgentTitle => 'Rename agent';

  @override
  String get renamePaneTitle => 'Rename pane';

  @override
  String get renameAgentHelper =>
      'Leave empty to clear the alias and restore the default name';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get continueEnter => 'Continue (Enter)';

  @override
  String get bridgeNotConfigured => 'Bridge connection is not configured';

  @override
  String get unpinned => 'Unpinned';

  @override
  String get pinned => 'Pinned';

  @override
  String get unpinTooltip => 'Unpin';

  @override
  String get pinTooltip => 'Pin';

  @override
  String get readOnlyCannotRename => 'Cannot rename in read-only mode';

  @override
  String get openDetails => 'Open details';

  @override
  String readFailed(String error) {
    return 'Read failed: $error';
  }

  @override
  String historyTitle(String title) {
    return 'History · $title';
  }

  @override
  String get historyDisabled =>
      'History is disabled on the bridge (COLLIE_TRANSCRIPT)';

  @override
  String get historyNoSession => 'This agent has no session log';

  @override
  String get historyNoLog => 'The log file for this session was not found';

  @override
  String historyUnavailable(String reason) {
    return 'History unavailable: $reason';
  }

  @override
  String loadFailed(String error) {
    return 'Load failed: $error';
  }

  @override
  String get historyTruncated =>
      'The log is too large; only the tail was parsed';

  @override
  String get loading => 'Loading…';

  @override
  String get loadOlder => 'Load earlier';

  @override
  String get roleYou => 'You';

  @override
  String get roleAgent => 'Agent';

  @override
  String get roleSummary => 'Summary';

  @override
  String get roleSystem => 'System';

  @override
  String get connectionSettings => 'Connection settings';

  @override
  String get devices => 'Computers';

  @override
  String get remoteBridge => 'Remote bridges (scan to pair)';

  @override
  String get scanToAdd => 'Scan to add';

  @override
  String get notPaired =>
      'No bridge is paired yet. Scan the pairing QR code printed when herdrgo-bridge starts to connect through the EasyTier virtual network.';

  @override
  String get deviceAlias => 'Device alias';

  @override
  String get displayNameHint => 'Display name';

  @override
  String get commonDelete => 'Delete';

  @override
  String get deleteConfigTitle => 'Delete configuration';

  @override
  String deleteConfigBody(String label, String ip) {
    return 'Delete “$label” ($ip)?';
  }

  @override
  String profileAdded(String label) {
    return 'Added: $label';
  }

  @override
  String get editAliasTooltip => 'Edit alias';

  @override
  String get deleteTooltip => 'Delete';

  @override
  String get bridgeEnableHelp =>
      'Use each switch to control whether that bridge connects. Enable multiple bridges for multi-host mode.';

  @override
  String get computerSetup => 'Set up your computer';

  @override
  String get pluginSetupHelp =>
      'Install the HerdrGo Plugin on the computer running Herdr, start its bridge service, then display the pairing QR code.';

  @override
  String get pluginPairAgainHelp =>
      'To display the pairing QR code again later:';

  @override
  String get pluginInstallGuide => 'View the full website guide';

  @override
  String get deploymentHelp => 'Setup help';

  @override
  String get openLinkFailed => 'Could not open the website';

  @override
  String get otherSettings => 'Other settings';

  @override
  String get about => 'About';

  @override
  String get privacyPolicy => 'Privacy policy';

  @override
  String get technicalSupport => 'Support';

  @override
  String get language => 'Language';

  @override
  String get terminalAutoResize => 'Fit terminal output to phone';

  @override
  String get terminalAutoResizeHelp =>
      'Temporarily control the shared Herdr terminal while an agent is open, then return control when you leave. Turn this off to always keep the computer\'s terminal width.';

  @override
  String get terminalRefreshRate => 'Terminal refresh speed';

  @override
  String get terminalRefreshRateHelp =>
      'Controls the maximum refresh rate during active output. No output means no phone updates.';

  @override
  String get terminalRefreshAutomatic => 'Automatic';

  @override
  String get terminalRefreshSmooth => 'Smooth · up to 20 FPS';

  @override
  String get terminalRefreshBalanced => 'Balanced · up to 10 FPS';

  @override
  String get terminalRefreshBatterySaver => 'Battery saver · up to 4 FPS';

  @override
  String get terminalFontSize => 'Terminal text size';

  @override
  String get terminalFontSizeHelp =>
      'Pinch the terminal output with two fingers, or adjust it here.';

  @override
  String get terminalFontSizeReset => 'Reset terminal text size';

  @override
  String get diagnostics => 'Diagnostics';

  @override
  String get diagnosticLogging => 'EasyTier diagnostic logs';

  @override
  String get diagnosticLoggingHelp =>
      'Keep detailed connection logs for troubleshooting background and network reconnection issues.';

  @override
  String get diagnosticLoggingDetailsTitle => 'About diagnostic logs';

  @override
  String get diagnosticLoggingDetails =>
      'Logging is off by default. When enabled, HerdrGo keeps up to four 5 MB files in Documents/Diagnostics and excludes them from iCloud Backup. The logs may contain IP addresses and peer IDs, but HerdrGo does not add pairing secrets or terminal content.\n\nConnect and trust this iPhone or iPad to download the app container with Xcode on your Mac, or use Share logs below. iOS suspends ordinary apps in the background, so no new events can be recorded while the process is suspended.';

  @override
  String get shareDiagnosticLogs => 'Share logs';

  @override
  String get clearDiagnosticLogs => 'Clear logs';

  @override
  String get clearDiagnosticLogsTitle => 'Clear diagnostic logs?';

  @override
  String get clearDiagnosticLogsBody =>
      'This permanently deletes all current and rotated EasyTier diagnostic logs.';

  @override
  String get diagnosticLogsCleared => 'Diagnostic logs cleared';

  @override
  String diagnosticLogsError(String error) {
    return 'Diagnostic logs failed: $error';
  }

  @override
  String get systemLanguage => 'System default';

  @override
  String get simplifiedChinese => '简体中文';

  @override
  String get english => 'English';

  @override
  String get scanPairingTitle => 'Scan pairing QR code';

  @override
  String get scanPairingHelp =>
      'Point the camera at the pairing QR code printed when the bridge starts.';

  @override
  String get scanFromImageTooltip => 'Choose an image from gallery/files';

  @override
  String get scanImageNoCode => 'No QR code found in the image';

  @override
  String get scanImageInvalid => 'The QR code is not HerdrGo pairing data';

  @override
  String scanImageFailed(String error) {
    return 'Could not read the image: $error';
  }

  @override
  String cameraUnavailable(String error) {
    return 'Camera unavailable: $error. Choose a QR image from the gallery instead.';
  }

  @override
  String get toggleFlashTooltip => 'Toggle flashlight';

  @override
  String get switchCameraTooltip => 'Switch camera';

  @override
  String blockedNotificationTitle(String name) {
    return '$name needs your attention';
  }

  @override
  String get blockedNotificationChannel => 'Agent attention';

  @override
  String get blockedNotificationChannelDescription =>
      'Notifies you when an agent stops and waits for your reply';

  @override
  String get newAgent => 'New agent';

  @override
  String get createAgentTitle => 'Create agent';

  @override
  String get targetComputer => 'Computer';

  @override
  String get herdrSession => 'Herdr session';

  @override
  String get agentType => 'Agent type';

  @override
  String get agentName => 'Agent name';

  @override
  String get agentNameHint => 'Lowercase letters, numbers, - or _';

  @override
  String get workspace => 'Workspace';

  @override
  String get newWorkspace => 'New workspace';

  @override
  String get workingDirectory => 'Working directory';

  @override
  String get workingDirectoryHint => '/absolute/path/to/project';

  @override
  String get recentDirectories => 'Recent directories';

  @override
  String get initialTask => 'Initial task (optional)';

  @override
  String get initialTaskHint => 'What should the agent work on?';

  @override
  String get createAgentAction => 'Create';

  @override
  String get creatingAgent => 'Creating agent…';

  @override
  String get noWritableComputer =>
      'No connected computer is available for creating agents.';

  @override
  String get noAgentTypes => 'Herdr did not report any available agent types.';

  @override
  String loadCreateAgentOptionsFailed(String error) {
    return 'Could not load agent options: $error';
  }

  @override
  String get invalidAgentName =>
      'Use 1–32 characters: lowercase letters, numbers, - or _; start with a letter.';

  @override
  String get absolutePathRequired => 'Enter an absolute path.';

  @override
  String get agentCreatePartialTitle =>
      'The terminal was created, but setup did not finish';

  @override
  String agentCreatePartialBody(String paneId, String error) {
    return 'Pane $paneId was created. Open it to check the actual agent state before retrying.\n\n$error';
  }

  @override
  String get openTerminal => 'Open terminal';
}
