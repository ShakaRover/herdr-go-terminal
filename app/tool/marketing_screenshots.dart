import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/l10n/generated/app_localizations.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/ui/agent/agent_screen.dart';
import 'package:herdrgo/ui/dashboard/dashboard_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _bridgeId = 'marketing-demo';
const _workingPaneId = 'demo:terminal';
const _approvalPaneId = 'demo:approval';
const _localeCode = String.fromEnvironment(
  'MARKETING_LOCALE',
  defaultValue: 'en',
);
const _screen = String.fromEnvironment(
  'MARKETING_SCREEN',
  defaultValue: 'dashboard',
);

const _workingOutput = '''
\x1b[38;2;128;217;205m›\x1b[0m Improve the mobile terminal layout

\x1b[2m•\x1b[0m Inspected viewport sizing
\x1b[2m•\x1b[0m Updated responsive width handling
\x1b[2m•\x1b[0m Added pinch zoom coverage

\x1b[38;2;80;200;140m✓\x1b[0m flutter test
  \x1b[2m240 tests passed\x1b[0m

\x1b[38;2;80;200;140m✓\x1b[0m flutter analyze
  \x1b[2mNo issues found\x1b[0m

\x1b[38;2;128;217;205m●\x1b[0m Running final visual checks...
''';

const _approvalOutput = '''
\x1b[38;2;128;217;205m›\x1b[0m Prepare the Android release

\x1b[38;2;80;200;140m✓\x1b[0m APK built and signed
\x1b[38;2;80;200;140m✓\x1b[0m Package contents verified

\x1b[1mBash command\x1b[0m

  flutter test && flutter analyze

This command requires approval

Do you want to proceed?

  1. Yes
  2. Yes, and don't ask again
  3. No

Esc to cancel · Tab to amend
''';

final _snapshot = Snapshot(
  bridgeConnected: true,
  agents: [
    PaneInfo(
      paneId: _approvalPaneId,
      workspaceId: 'demo',
      workspaceLabel: 'herdrgo-demo',
      workspaceNumber: 1,
      tabId: 'demo:release',
      agent: 'claude',
      status: AgentStatus.blocked,
      cwd: '/workspace/herdrgo-demo',
      focused: false,
      paneLabel: 'release-check',
      tabLabel: 'release',
      lastActiveAt: DateTime.now().millisecondsSinceEpoch,
    ),
    PaneInfo(
      paneId: _workingPaneId,
      workspaceId: 'demo',
      workspaceLabel: 'herdrgo-demo',
      workspaceNumber: 1,
      tabId: 'demo:mobile',
      agent: 'codex',
      status: AgentStatus.working,
      cwd: '/workspace/herdrgo-demo/app',
      focused: true,
      paneLabel: 'terminal-layout',
      tabLabel: 'mobile',
      lastActiveAt: DateTime.now().millisecondsSinceEpoch,
    ),
    PaneInfo(
      paneId: 'demo:docs',
      workspaceId: 'demo',
      workspaceLabel: 'herdrgo-demo',
      workspaceNumber: 1,
      tabId: 'demo:docs',
      agent: 'opencode',
      status: AgentStatus.working,
      cwd: '/workspace/herdrgo-demo/docs',
      focused: false,
      paneLabel: 'docs-refresh',
      tabLabel: 'docs',
      lastActiveAt: DateTime.now().millisecondsSinceEpoch,
    ),
  ],
  shellPanes: const [],
  workspaces: const [],
  tabs: const [],
  sessions: const [
    SessionSummary(
      name: 'main',
      isPrimary: true,
      reachable: true,
      agents: 3,
      working: 2,
      blocked: 1,
    ),
  ],
  ts: DateTime.now().millisecondsSinceEpoch,
);

class _MarketingBridgeApi extends BridgeApi {
  _MarketingBridgeApi() : super(baseUrl: 'http://127.0.0.1:1');

  @override
  Future<Snapshot> getSnapshot({
    String? session,
    CancelToken? cancelToken,
  }) async => _snapshot;

  @override
  Future<PaneRead> readPane(
    String paneId, {
    int? lines,
    String? session,
  }) async => PaneRead(
    paneId: paneId,
    text: paneId == _approvalPaneId ? _approvalOutput : _workingOutput,
    truncated: false,
    revision: 1,
  );

  @override
  Future<String> holdPaneSize(
    String paneId, {
    required int cols,
    required int rows,
    String? session,
    String? leaseId,
  }) async => 'marketing-lease';

  @override
  Future<void> releasePaneSize(
    String paneId,
    String leaseId, {
    String? session,
  }) async {}
}

/// Screenshot-only entrypoint with deterministic synthetic data.
///
/// Build it explicitly with `--target tool/marketing_screenshots.dart`; the
/// production app continues to use `lib/main.dart`.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(terminalAutoResizePreferenceKey, false);
  await prefs.setDouble(terminalFontSizePreferenceKey, 12.5);
  final api = _MarketingBridgeApi();
  final connection = BridgeConn(
    id: _bridgeId,
    label: 'Workstation',
    api: api,
    status: ConnStatus.ready,
  );

  runApp(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        bridgesProvider.overrideWithValue([connection]),
        apiProvider.overrideWith((ref, bridgeId) => api),
      ],
      child: const _MarketingApp(),
    ),
  );
}

class _MarketingApp extends StatelessWidget {
  const _MarketingApp();

  Widget get _home => switch (_screen) {
    'working' => const AgentScreen(
      bridgeId: _bridgeId,
      paneId: _workingPaneId,
    ),
    'approval' => const AgentScreen(
      bridgeId: _bridgeId,
      paneId: _approvalPaneId,
    ),
    _ => const DashboardScreen(),
  };

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale(_localeCode),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          systemOverlayStyle: SystemUiOverlayStyle.light,
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: _home,
    );
  }
}
