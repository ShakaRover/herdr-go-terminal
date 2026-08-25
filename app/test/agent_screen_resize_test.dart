library;

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
import 'package:shared_preferences/shared_preferences.dart';

typedef _ResizeCall = ({String paneId, int cols, int rows, String? session});

class _FakeBridgeApi extends BridgeApi {
  _FakeBridgeApi() : super(baseUrl: 'http://127.0.0.1:1');

  final resizeCalls = <_ResizeCall>[];

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
        workspaceLabel: 'work',
        workspaceNumber: 1,
        tabId: 'w1:t1',
        agent: 'codex',
        status: AgentStatus.working,
        cwd: '/repo',
        focused: true,
      ),
    ],
    shellPanes: [],
    workspaces: [],
    tabs: [],
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
    text: 'phone output',
    truncated: false,
    revision: 1,
  );

  @override
  Future<ActionResult> resizePane(
    String paneId, {
    required int cols,
    required int rows,
    String? session,
  }) async {
    resizeCalls.add((paneId: paneId, cols: cols, rows: rows, session: session));
    return const ActionResult.ok();
  }
}

Future<void> _pumpAgent(
  WidgetTester tester,
  _FakeBridgeApi api, {
  required bool? autoResize,
}) async {
  SharedPreferences.setMockInitialValues({
    terminalAutoResizePreferenceKey: ?autoResize,
  });
  final prefs = await SharedPreferences.getInstance();
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
        home: const AgentScreen(bridgeId: 'bridge-1', paneId: 'w1:p1'),
      ),
    ),
  );
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    if (condition()) return;
  }
  throw StateError('condition was not reached');
}

void main() {
  testWidgets('resizes on entry and width change but not height-only change', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = _FakeBridgeApi();

    await _pumpAgent(tester, api, autoResize: null);
    await _pumpUntil(tester, () => api.resizeCalls.isNotEmpty);

    final first = api.resizeCalls.single;
    expect(first.paneId, 'w1:p1');
    expect(first.cols, inInclusiveRange(20, 300));
    expect(first.rows, inInclusiveRange(5, 200));

    tester.view.physicalSize = const Size(390, 700);
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.resizeCalls, hasLength(1));

    tester.view.physicalSize = const Size(844, 390);
    await _pumpUntil(tester, () => api.resizeCalls.length == 2);
    expect(api.resizeCalls.last.cols, isNot(first.cols));
  });

  testWidgets('persisted off option suppresses automatic resize', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = _FakeBridgeApi();

    await _pumpAgent(tester, api, autoResize: false);
    await tester.pump(const Duration(milliseconds: 500));

    expect(api.resizeCalls, isEmpty);
  });
}
