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
import 'package:shared_preferences/shared_preferences.dart';

typedef _HoldCall = ({
  String paneId,
  int cols,
  int rows,
  String? session,
  String? leaseId,
});
typedef _ReleaseCall = ({String paneId, String leaseId, String? session});

class _FakeBridgeApi extends BridgeApi {
  _FakeBridgeApi() : super(baseUrl: 'http://127.0.0.1:1');

  final holdCalls = <_HoldCall>[];
  final releaseCalls = <_ReleaseCall>[];
  final readLines = <int?>[];
  final paneStream = StreamController<PaneRead>.broadcast(sync: true);
  var _nextLease = 1;
  var outputTruncated = false;
  var outputText = 'phone output';
  Completer<void>? holdGate;

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
  }) async {
    readLines.add(lines);
    return PaneRead(
      paneId: paneId,
      text: outputText,
      truncated: outputTruncated,
      revision: 1,
    );
  }

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
    holdCalls.add((
      paneId: paneId,
      cols: cols,
      rows: rows,
      session: session,
      leaseId: leaseId,
    ));
    await holdGate?.future;
    return leaseId ?? 'lease-${_nextLease++}';
  }

  @override
  Future<void> releasePaneSize(
    String paneId,
    String leaseId, {
    String? session,
  }) async {
    releaseCalls.add((paneId: paneId, leaseId: leaseId, session: session));
  }

  Future<void> close() => paneStream.close();
}

Future<void> _pumpAgent(
  WidgetTester tester,
  _FakeBridgeApi api, {
  required bool? autoResize,
  double? fontSize,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await api.close();
  });
  SharedPreferences.setMockInitialValues({
    terminalAutoResizePreferenceKey: ?autoResize,
    terminalFontSizePreferenceKey: ?fontSize,
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
  testWidgets('live output does not interrupt an active upward scroll', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final firstFrame = List.generate(
      120,
      (index) => index == 119 ? 'working ⠋' : 'line $index',
    ).join('\n');
    final api = _FakeBridgeApi()..outputText = firstFrame;
    await _pumpAgent(tester, api, autoResize: false);
    await _pumpUntil(tester, () => api.readLines.contains(200));
    await tester.pumpAndSettle();

    final scrollView = tester.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    final controller = scrollView.controller!;
    expect(controller.offset, controller.position.maxScrollExtent);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('terminal-output-gesture-area'))),
    );
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    final userOffset = controller.offset;
    expect(userOffset, lessThan(controller.position.maxScrollExtent));

    api.paneStream.add(
      PaneRead(
        paneId: 'w1:p1',
        text: firstFrame.replaceFirst('working ⠋', 'working ⠙'),
        truncated: false,
        revision: 2,
      ),
    );
    await tester.pump();

    expect(controller.offset, userOffset);
    await gesture.up();
    await tester.pump();

    api.paneStream.add(
      PaneRead(
        paneId: 'w1:p1',
        text: firstFrame.replaceFirst('working ⠋', 'working ⠹'),
        truncated: false,
        revision: 3,
      ),
    );
    await tester.pump();

    expect(controller.offset, userOffset);
  });

  testWidgets('loads larger static output windows and returns to live mode', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = _FakeBridgeApi()
      ..outputTruncated = true
      ..outputText = List.generate(120, (index) => 'line $index').join('\n');
    await _pumpAgent(tester, api, autoResize: false);
    await _pumpUntil(tester, () => api.readLines.contains(200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('load-earlier-output-button')), findsNothing);

    await tester.drag(
      find.byKey(const Key('terminal-output-gesture-area')),
      const Offset(0, 4000),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('load-earlier-output-button')), findsOneWidget);

    api.outputText = List.generate(240, (index) => 'line $index').join('\n');
    await tester.tap(find.byKey(const Key('load-earlier-output-button')));
    await _pumpUntil(tester, () => api.readLines.contains(1000));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('back-to-live-button')), findsOneWidget);
    expect(find.byKey(const Key('load-earlier-output-button')), findsNothing);

    await tester.tap(find.byKey(const Key('back-to-live-button')));
    await _pumpUntil(tester, () => api.readLines.last == 200);
    expect(find.byKey(const Key('back-to-live-button')), findsNothing);
  });

  testWidgets('holds lease on entry and resizes it only when width changes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = _FakeBridgeApi();

    await _pumpAgent(tester, api, autoResize: null);
    await _pumpUntil(tester, () => api.holdCalls.isNotEmpty);

    final first = api.holdCalls.single;
    expect(first.paneId, 'w1:p1');
    expect(first.leaseId, isNull);
    expect(first.cols, inInclusiveRange(20, 300));
    expect(first.rows, inInclusiveRange(5, 200));

    tester.view.physicalSize = const Size(390, 700);
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.holdCalls, hasLength(1));

    tester.view.physicalSize = const Size(844, 390);
    await _pumpUntil(tester, () => api.holdCalls.length == 2);
    expect(api.holdCalls.last.cols, isNot(first.cols));
    expect(api.holdCalls.last.leaseId, 'lease-1');

    await tester.pumpWidget(const SizedBox());
    await _pumpUntil(tester, () => api.releaseCalls.isNotEmpty);
    expect(api.releaseCalls.single.leaseId, 'lease-1');
  });

  testWidgets('renews the held lease before the bridge TTL', (tester) async {
    final api = _FakeBridgeApi();
    await _pumpAgent(tester, api, autoResize: null);
    await _pumpUntil(tester, () => api.holdCalls.isNotEmpty);

    await tester.pump(const Duration(seconds: 5));
    await _pumpUntil(tester, () => api.holdCalls.length == 2);

    expect(api.holdCalls.last.leaseId, 'lease-1');
  });

  testWidgets('releases in background and reacquires after resume', (
    tester,
  ) async {
    final api = _FakeBridgeApi();
    await _pumpAgent(tester, api, autoResize: null);
    await _pumpUntil(tester, () => api.holdCalls.isNotEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _pumpUntil(tester, () => api.releaseCalls.isNotEmpty);
    expect(api.releaseCalls.single.leaseId, 'lease-1');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _pumpUntil(tester, () => api.holdCalls.length == 2);
    expect(api.holdCalls.last.leaseId, isNull);
  });

  testWidgets('releases a lease acquired while the page is closing', (
    tester,
  ) async {
    final api = _FakeBridgeApi()..holdGate = Completer<void>();
    await _pumpAgent(tester, api, autoResize: null);
    await _pumpUntil(tester, () => api.holdCalls.isNotEmpty);

    await tester.pumpWidget(const SizedBox());
    api.holdGate!.complete();
    await _pumpUntil(tester, () => api.releaseCalls.isNotEmpty);

    expect(api.releaseCalls.single.leaseId, 'lease-1');
  });

  testWidgets('pinch previews locally then resizes once and persists', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = _FakeBridgeApi();
    await _pumpAgent(tester, api, autoResize: null);
    await _pumpUntil(tester, () => api.holdCalls.isNotEmpty);
    final initial = api.holdCalls.single;
    final target = find.byKey(const Key('terminal-output-gesture-area'));
    final center = tester.getCenter(target);

    final first = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 10,
    );
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 11,
    );
    await tester.pump();
    await first.moveTo(center - const Offset(60, 0));
    await second.moveTo(center + const Offset(60, 0));
    await tester.pump();

    expect(find.textContaining('pt ·'), findsOneWidget);
    expect(api.holdCalls, hasLength(1));

    await first.up();
    await second.up();
    await _pumpUntil(tester, () => api.holdCalls.length == 2);

    expect(find.textContaining('pt ·'), findsNothing);
    expect(api.holdCalls.last.leaseId, 'lease-1');
    expect(api.holdCalls.last.cols, lessThan(initial.cols));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(terminalFontSizePreferenceKey), 16.0);
  });

  testWidgets('pinch with auto resize off only changes local text size', (
    tester,
  ) async {
    final api = _FakeBridgeApi();
    await _pumpAgent(tester, api, autoResize: false);
    final target = find.byKey(const Key('terminal-output-gesture-area'));
    await _pumpUntil(tester, () => target.evaluate().isNotEmpty);
    final center = tester.getCenter(target);

    final first = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 20,
    );
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 21,
    );
    await first.moveTo(center - const Offset(45, 0));
    await second.moveTo(center + const Offset(45, 0));
    await first.up();
    await second.up();
    await tester.pump();

    expect(api.holdCalls, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getDouble(terminalFontSizePreferenceKey),
      greaterThan(terminalDefaultFontSize),
    );
  });

  testWidgets('one pointer does not start terminal zoom', (tester) async {
    final api = _FakeBridgeApi();
    await _pumpAgent(tester, api, autoResize: null);
    await _pumpUntil(tester, () => api.holdCalls.isNotEmpty);
    final target = find.byKey(const Key('terminal-output-gesture-area'));
    final center = tester.getCenter(target);

    final gesture = await tester.startGesture(center, pointer: 30);
    await gesture.moveBy(const Offset(0, -40));
    await gesture.up();
    await tester.pump();

    expect(find.textContaining('pt ·'), findsNothing);
    expect(api.holdCalls, hasLength(1));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(terminalFontSizePreferenceKey), isNull);
  });

  testWidgets('persisted off option never acquires a controller lease', (
    tester,
  ) async {
    final api = _FakeBridgeApi();

    await _pumpAgent(tester, api, autoResize: false);
    await tester.pump(const Duration(milliseconds: 500));

    expect(api.holdCalls, isEmpty);
    expect(api.releaseCalls, isEmpty);
  });
}
