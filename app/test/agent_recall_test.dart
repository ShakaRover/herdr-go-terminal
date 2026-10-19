import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/l10n/generated/app_localizations.dart';
import 'package:herdrgo/model/history.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/state/sent_history.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/ui/agent/agent_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _agentPane = PaneInfo(
  paneId: 'w1:p1',
  workspaceId: 'w1',
  workspaceLabel: 'work',
  workspaceNumber: 1,
  tabId: 'w1:t1',
  agent: 'omp',
  status: AgentStatus.idle,
  cwd: '/repo',
  focused: true,
);

const _shellPane = PaneInfo(
  paneId: 'w1:p2',
  workspaceId: 'w1',
  workspaceLabel: 'work',
  workspaceNumber: 1,
  tabId: 'w1:t1',
  agent: 'shell',
  status: AgentStatus.unknown,
  cwd: '/repo',
  focused: false,
  kind: 'shell',
);

class _FakeBridgeApi extends BridgeApi {
  _FakeBridgeApi({required this.pane}) : super(baseUrl: 'http://127.0.0.1:1');

  final PaneInfo pane;
  final paneStream = StreamController<PaneRead>.broadcast(sync: true);
  int fetchHistoryCount = 0;
  String? sentText;

  @override
  Future<Snapshot> getSnapshot({
    String? session,
    CancelToken? cancelToken,
  }) async => Snapshot(
    bridgeConnected: true,
    agents: pane.isShell ? const [] : [pane],
    shellPanes: pane.isShell ? [pane] : const [],
    workspaces: const [],
    tabs: const [],
    sessions: const [],
    ts: 1,
  );

  @override
  Future<PaneRead> readPane(
    String paneId, {
    int? lines,
    String? session,
  }) async =>
      PaneRead(paneId: paneId, text: 'output', truncated: false, revision: 1);

  @override
  Stream<PaneRead> watchPane(
    String paneId, {
    int lines = 200,
    int intervalMs = 0,
    String? session,
  }) => paneStream.stream;

  @override
  Future<PaneHistory> fetchHistory(
    String paneId, {
    int? limit,
    String? before,
    String? session,
  }) async {
    fetchHistoryCount++;
    return const HistoryPage(
      entries: [
        TranscriptEntry(
          uuid: 'u1',
          ts: '2026-01-01T00:00:00Z',
          role: TranscriptRole.user,
          parts: [TextPart('first prompt')],
        ),
        TranscriptEntry(
          uuid: 'u2',
          ts: '2026-01-01T00:01:00Z',
          role: TranscriptRole.assistant,
          parts: [TextPart('answer')],
        ),
        TranscriptEntry(
          uuid: 'u3',
          ts: '2026-01-01T00:02:00Z',
          role: TranscriptRole.user,
          parts: [TextPart('second prompt')],
        ),
      ],
      hasMore: false,
      total: 3,
      fileTruncated: false,
    );
  }

  @override
  Future<ActionResult> sendReply(
    String paneId,
    String text, {
    bool submit = true,
    String? session,
    String? expectedPrompt,
  }) async {
    sentText = text;
    return const ActionResult.ok();
  }

  @override
  Future<ActionResult> sendKeys(
    String paneId,
    List<String> keys, {
    String? session,
    String? expectedPrompt,
  }) async => const ActionResult.ok();

  @override
  Future<String> holdPaneSize(
    String paneId, {
    required int cols,
    required int rows,
    String? session,
    String? leaseId,
  }) async => leaseId ?? 'lease';

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

Future<_FakeBridgeApi> _pump(
  WidgetTester tester,
  PaneInfo pane, {
  List<String> localHistory = const [],
}) async {
  final historyKey = (bridgeId: 'b1', session: null, paneId: pane.paneId);
  SharedPreferences.setMockInitialValues({
    sentHistoryPrefsKey: jsonEncode({
      sentHistoryStorageKey(historyKey): localHistory,
    }),
  });
  final prefs = await SharedPreferences.getInstance();
  final api = _FakeBridgeApi(pane: pane);
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
        home: AgentScreen(bridgeId: 'b1', paneId: pane.paneId),
      ),
    ),
  );
  await _pumpUntil(
    tester,
    () =>
        find.byTooltip('Fill from history').evaluate().isNotEmpty &&
        find.byType(TextField).evaluate().isNotEmpty,
  );
  return api;
}

void main() {
  testWidgets('history sheet merges local and journal user prompts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final api = await _pump(tester, _agentPane, localHistory: ['local prompt']);
    await tester.tap(find.byTooltip('Fill from history'));
    await _pumpUntil(
      tester,
      () => find.text('second prompt').evaluate().isNotEmpty,
    );

    expect(find.text('local prompt'), findsOneWidget);
    expect(find.text('second prompt'), findsOneWidget);
    expect(find.text('first prompt'), findsOneWidget);
    expect(api.fetchHistoryCount, 1);
  });

  testWidgets('Up/Down cycles local history and long press sends raw key', (
    tester,
  ) async {
    final api = await _pump(tester, _agentPane, localHistory: ['cmd2', 'cmd1']);

    await tester.tap(find.text('↑'));
    await _pumpUntil(
      tester,
      () =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text ==
          'cmd2',
    );
    await tester.tap(find.text('↑'));
    await _pumpUntil(
      tester,
      () =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text ==
          'cmd1',
    );
    await tester.tap(find.text('↓'));
    await _pumpUntil(
      tester,
      () =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text ==
          'cmd2',
    );
    await tester.tap(find.text('↓'));
    await _pumpUntil(
      tester,
      () =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text ==
          '',
    );

    // 长按 Up 走原始按键路径，不改本地输入框。
    await tester.longPress(find.text('↑'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.sentText, isNull);
  });

  testWidgets('send from history sends the filled text and clears', (
    tester,
  ) async {
    final api = await _pump(tester, _agentPane, localHistory: ['cmd2']);
    await tester.tap(find.text('↑'));
    await _pumpUntil(
      tester,
      () =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text ==
          'cmd2',
    );
    await tester.tap(find.byIcon(Icons.send));
    await _pumpUntil(tester, () => api.sentText == 'cmd2');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    // 发送后历史游标归零，下一次 Up 仍能取到同一条。
    await tester.tap(find.text('↑'));
    await _pumpUntil(
      tester,
      () =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text ==
          'cmd2',
    );
  });

  testWidgets('sent reply is recorded in local history', (tester) async {
    final api = await _pump(tester, _agentPane, localHistory: ['old']);
    await tester.enterText(find.byType(TextField), 'new prompt');
    await tester.tap(find.byIcon(Icons.send));
    await _pumpUntil(tester, () => api.sentText == 'new prompt');
    final prefs = await SharedPreferences.getInstance();
    final key = (bridgeId: 'b1', session: null, paneId: _agentPane.paneId);
    await _pumpUntil(
      tester,
      () => readSentHistory(prefs, key).firstOrNull == 'new prompt',
    );
    expect(readSentHistory(prefs, key), ['new prompt', 'old']);
  });

  testWidgets('shell history is local-only and skips journal fetch', (
    tester,
  ) async {
    final api = await _pump(tester, _shellPane, localHistory: ['ls -la']);
    await tester.tap(find.byTooltip('Fill from history'));
    await _pumpUntil(tester, () => find.text('ls -la').evaluate().isNotEmpty);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Sent commands'), findsOneWidget);
    expect(api.fetchHistoryCount, 0);
  });
}
