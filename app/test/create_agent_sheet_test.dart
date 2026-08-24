import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/l10n/generated/app_localizations.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/ui/dashboard/create_agent_sheet.dart';

class _FakeCreateApi extends BridgeApi {
  _FakeCreateApi() : super(baseUrl: 'http://127.0.0.1:1');

  String? name;
  String? kind;
  String? cwd;
  String? workspaceId;
  String? initialPrompt;
  String? session;

  @override
  Future<List<String>> getAgentKinds({String? session}) async {
    return ['claude', 'codex'];
  }

  @override
  Future<Snapshot> getSnapshot({
    String? session,
    CancelToken? cancelToken,
  }) async => const Snapshot(
    bridgeConnected: true,
    agents: [
      PaneInfo(
        paneId: 'p1',
        workspaceId: 'w1',
        workspaceLabel: 'HerdrGo',
        workspaceNumber: 1,
        tabId: 't1',
        agent: 'claude',
        status: AgentStatus.idle,
        cwd: '/repo/herdrgo',
        focused: true,
      ),
    ],
    shellPanes: [],
    workspaces: [
      WorkspaceInfo(
        workspaceId: 'w1',
        number: 1,
        label: 'HerdrGo',
        focused: true,
        activeTabId: 't1',
        tabCount: 1,
        paneCount: 1,
      ),
    ],
    tabs: [],
    sessions: [],
    ts: 1,
  );

  @override
  Future<CreateAgentResult> createAgent({
    required String name,
    required String kind,
    required String cwd,
    String? workspaceId,
    String? workspaceLabel,
    String? initialPrompt,
    String? session,
  }) async {
    this.name = name;
    this.kind = kind;
    this.cwd = cwd;
    this.workspaceId = workspaceId;
    this.initialPrompt = initialPrompt;
    this.session = session;
    return const CreateAgentResult(
      success: true,
      agentName: 'mobile-agent',
      workspaceId: 'w1',
      tabId: 't2',
      paneId: 'p2',
    );
  }
}

class _Launcher extends StatefulWidget {
  const _Launcher();

  @override
  State<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends State<_Launcher> {
  CreateAgentOutcome? outcome;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: () async {
            final value = await showCreateAgentSheet(
              context,
              initialBridgeId: 'b1',
            );
            if (mounted) setState(() => outcome = value);
          },
          child: const Text('open'),
        ),
        if (outcome != null) Text('created:${outcome!.result.paneId}'),
      ],
    ),
  );
}

void main() {
  testWidgets('加载动态选项并在已有 workspace 创建 agent', (tester) async {
    final api = _FakeCreateApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bridgesProvider.overrideWithValue([
            BridgeConn(
              id: 'b1',
              label: 'Mac',
              api: api,
              status: ConnStatus.ready,
            ),
          ]),
          apiProvider.overrideWith(
            (ref, bridgeId) => bridgeId == 'b1' ? api : null,
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: _Launcher(),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('创建 agent'), findsOneWidget);
    expect(find.text('Mac'), findsOneWidget);
    expect(find.text('codex'), findsOneWidget);
    expect(find.text('1 · HerdrGo'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('create-agent-name')),
      'mobile-agent',
    );
    await tester.enterText(
      find.byKey(const Key('create-agent-prompt')),
      '请检查测试',
    );
    final submit = find.byKey(const Key('create-agent-submit'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    expect(api.name, 'mobile-agent');
    expect(api.kind, 'codex');
    expect(api.cwd, '/repo/herdrgo');
    expect(api.workspaceId, 'w1');
    expect(api.initialPrompt, '请检查测试');
    expect(find.text('created:p2'), findsOneWidget);
  });
}
