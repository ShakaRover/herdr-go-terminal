/// SpaceScreen 与 shell pane 的联动测试：
/// - 空间详情按窗口列出 agent/shell 窗格；
/// - 点 shell 窗格进入 AgentScreen 后仍能接管终端尺寸（resize lease）、
///   输入框提示切换为 shell 文案。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/l10n/generated/app_localizations.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/ui/agent/agent_screen.dart';
import 'package:herdrgo/ui/spaces/space_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeBridgeApi extends BridgeApi {
  _FakeBridgeApi() : super(baseUrl: 'http://127.0.0.1:1');

  final paneStream = StreamController<PaneRead>.broadcast(sync: true);
  final holdCalls = <String>[];

  @override
  Future<Snapshot> getSnapshot({
    String? session,
    CancelToken? cancelToken,
  }) async => const Snapshot(
    bridgeConnected: true,
    agents: [
      PaneInfo(
        paneId: 'w1:p1',
        workspaceId: 'w1',
        workspaceLabel: 'project',
        workspaceNumber: 1,
        tabId: 'w1:t1',
        tabLabel: 'agents',
        agent: 'claude',
        status: AgentStatus.working,
        cwd: '/repo',
        focused: false,
      ),
    ],
    shellPanes: [
      PaneInfo(
        paneId: 'w1:p2',
        workspaceId: 'w1',
        workspaceLabel: 'project',
        workspaceNumber: 1,
        tabId: 'w1:t1',
        tabLabel: 'agents',
        agent: 'shell',
        status: AgentStatus.unknown,
        cwd: '/work/shells',
        focused: false,
        kind: 'shell',
      ),
    ],
    workspaces: [
      WorkspaceInfo(
        workspaceId: 'w1',
        number: 1,
        label: 'project',
        focused: true,
        activeTabId: 'w1:t1',
        tabCount: 1,
        paneCount: 2,
      ),
    ],
    tabs: [
      TabInfo(
        tabId: 'w1:t1',
        workspaceId: 'w1',
        number: 1,
        label: 'agents',
        focused: true,
        paneCount: 2,
      ),
    ],
    sessions: [],
    ts: 1,
  );

  @override
  Future<PaneRead> readPane(
    String paneId, {
    int? lines,
    String? session,
  }) async => PaneRead(
    paneId: paneId,
    text: 'shell output',
    truncated: false,
    revision: 1,
  );

  @override
  Stream<PaneRead> watchPane(
    String paneId, {
    int lines = 200,
    int intervalMs = 0,
    String? session,
  }) => paneStream.stream;

  @override
  Future<String> holdPaneSize(
    String paneId, {
    required int cols,
    required int rows,
    String? session,
    String? leaseId,
  }) async {
    holdCalls.add(paneId);
    return leaseId ?? 'lease-1';
  }

  @override
  Future<void> releasePaneSize(
    String paneId,
    String leaseId, {
    String? session,
  }) async {}

  Future<void> close() => paneStream.close();
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 200; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) return;
  }
  throw StateError('condition was not reached');
}

void main() {
  testWidgets('空间详情列出窗口/窗格，shell pane 可打开并接管终端', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final api = _FakeBridgeApi();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await api.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          apiProvider.overrideWith((ref, bridgeId) => api),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SpaceScreen(
            bridgeId: 'b1',
            workspaceId: 'w1',
            initialTitle: 'project',
          ),
        ),
      ),
    );

    await _pumpUntil(
      tester,
      () => find.text('Tab 1 · agents').evaluate().isNotEmpty,
    );
    expect(find.text('project'), findsOneWidget);
    expect(find.text('claude'), findsOneWidget);
    expect(find.text('shells'), findsOneWidget);
    expect(find.text('Shell'), findsOneWidget);

    await tester.tap(find.text('shells'));
    await _pumpUntil(
      tester,
      () => find.byType(AgentScreen).evaluate().isNotEmpty,
    );
    expect(find.text('Send input…'), findsOneWidget);
    await _pumpUntil(tester, () => api.holdCalls.contains('w1:p2'));
  });
}
