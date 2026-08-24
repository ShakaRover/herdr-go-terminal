/// bridgeSnapshotProvider / sessionFilterProvider 按 bridgeId family 化的测试。
///
/// fake api 按 bridge 脚本化（apiProvider(bridgeId) family override），验证：
/// - bridgeSnapshotProvider('b1') 与 ('b2') 各自轮询互不干扰；
/// - getSnapshot 带 sessionFilterProvider(bridgeId) 的当前值；
/// - sessionFilterProvider('b1') 的 select 不影响 ('b2')。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/state/snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// fake BridgeApi：脚本化 snapshot 的 agents，捕获 session 参数。
class FakeBridgeApi extends BridgeApi {
  FakeBridgeApi(this.agentName) : super(baseUrl: 'http://127.0.0.1:1');

  final String agentName;
  final seenSessions = <String?>[];

  /// 非空时优先于 [agentName] 默认 pane 作为 agents 返回（脚本化场景）。
  List<PaneInfo>? scriptedAgents;

  /// getSnapshot 调用次数（轮询暂停/恢复断言用）。
  int getSnapshotCount = 0;

  @override
  Future<Snapshot> getSnapshot(
      {String? session, CancelToken? cancelToken}) async {
    getSnapshotCount++;
    seenSessions.add(session);
    return Snapshot(
      bridgeConnected: true,
      agents: scriptedAgents ??
          [
            PaneInfo(
              paneId: 'w0',
              workspaceId: 'w0',
              workspaceLabel: 'ws0',
              workspaceNumber: 0,
              tabId: 'w0:t0',
              agent: agentName,
              status: AgentStatus.working,
              cwd: '/repo',
              focused: false,
            ),
          ],
      shellPanes: const [],
      workspaces: const [],
      tabs: const [],
      sessions: const [],
      ts: 1,
    );
  }
}

Future<ProviderContainer> buildContainer(
    FakeBridgeApi b1, FakeBridgeApi b2) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(prefs),
    apiProvider.overrideWith((ref, bridgeId) => switch (bridgeId) {
          'b1' => b1,
          'b2' => b2,
          _ => null,
        }),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// 等指定 bridge 的 snapshot 拉取成功（state.data 非空）。
Future<SnapshotState> waitSnapshot(ProviderContainer container, String bridgeId) {
  final c = Completer<SnapshotState>();
  final sub = container.listen(bridgeSnapshotProvider(bridgeId), (_, next) {
    if (next.data != null && !c.isCompleted) c.complete(next);
  });
  addTearDown(sub.close);
  return c.future.timeout(const Duration(seconds: 5));
}

void main() {
  test('b1 与 b2 各自轮询互不干扰，数据来自各自的 api', () async {
    final b1 = FakeBridgeApi('claude-b1');
    final b2 = FakeBridgeApi('claude-b2');
    final container = await buildContainer(b1, b2);

    final s1 = waitSnapshot(container, 'b1');
    final s2 = waitSnapshot(container, 'b2');
    container.listen(bridgeSnapshotProvider('b1'), (_, _) {});
    container.listen(bridgeSnapshotProvider('b2'), (_, _) {});

    expect((await s1).data!.agents.single.agent, 'claude-b1');
    expect((await s2).data!.agents.single.agent, 'claude-b2');
    expect(container.read(bridgeSnapshotProvider('b1')).data!.agents.single.agent,
        'claude-b1');
    expect(container.read(bridgeSnapshotProvider('b2')).data!.agents.single.agent,
        'claude-b2');
  });

  test('getSnapshot 带 sessionFilterProvider(bridgeId) 的当前值；'
      "select('b1') 不影响 'b2'", () async {
    final b1 = FakeBridgeApi('b1');
    final b2 = FakeBridgeApi('b2');
    final container = await buildContainer(b1, b2);

    // 两个 bridge 的 session filter 初值都是 null，select 互不影响。
    container.read(sessionFilterProvider('b1').notifier).select('work');
    expect(container.read(sessionFilterProvider('b1')), 'work');
    expect(container.read(sessionFilterProvider('b2')), isNull);
    container.read(sessionFilterProvider('b2').notifier).select('ops');

    final s1 = waitSnapshot(container, 'b1');
    final s2 = waitSnapshot(container, 'b2');
    container.listen(bridgeSnapshotProvider('b1'), (_, _) {});
    container.listen(bridgeSnapshotProvider('b2'), (_, _) {});
    await s1;
    await s2;

    expect(b1.seenSessions, everyElement('work'));
    expect(b2.seenSessions, everyElement('ops'));

    // b1 改选不影响 b2。
    container.read(sessionFilterProvider('b1').notifier).select(null);
    expect(container.read(sessionFilterProvider('b2')), 'ops');
  });

  test('未知 bridgeId（api null）不轮询、无数据', () async {
    final b1 = FakeBridgeApi('b1');
    final b2 = FakeBridgeApi('b2');
    final container = await buildContainer(b1, b2);

    container.listen(bridgeSnapshotProvider('nope'), (_, _) {});
    await pumpEventQueue();

    final s = container.read(bridgeSnapshotProvider('nope'));
    expect(s.data, isNull);
    expect(s.error, isNull);
  });

  test('snapshot 失败后按快速重试间隔恢复，不等待正常轮询周期', () async {
    SnapshotNotifier.pollInterval = const Duration(seconds: 1);
    SnapshotNotifier.retryInterval = const Duration(milliseconds: 10);
    addTearDown(() {
      SnapshotNotifier.pollInterval = const Duration(seconds: 3);
      SnapshotNotifier.retryInterval = const Duration(milliseconds: 500);
    });
    final flaky = _FlakyBridgeApi();
    final container = await buildContainer(flaky, FakeBridgeApi('b2'));

    final snapshot = waitSnapshot(container, 'b1');
    container.listen(bridgeSnapshotProvider('b1'), (_, _) {});
    await snapshot;

    expect(flaky.getSnapshotCount, 2);
  });

  test('暂停取消未完成的请求，恢复后立即重新拉取且忽略旧响应', () async {
    SnapshotNotifier.pollInterval = const Duration(hours: 1);
    addTearDown(() {
      SnapshotNotifier.pollInterval = const Duration(seconds: 3);
    });
    final api = _SuspendingBridgeApi();
    final container = await buildContainer(api, FakeBridgeApi('b2'));

    final recovered = waitSnapshot(container, 'b1');
    await pumpEventQueue();
    expect(api.getSnapshotCount, 1);

    final notifier = container.read(bridgeSnapshotProvider('b1').notifier);
    notifier.setPaused(true);
    expect(api.firstCancelToken, isNotNull);
    expect(api.firstCancelToken!.isCancelled, isTrue);

    notifier.setPaused(false);
    final state = await recovered;
    expect(api.getSnapshotCount, 2);
    expect(state.data!.agents.single.agent, 'recovered');

    api.completeFirstRequest();
    await pumpEventQueue();
    expect(container
        .read(bridgeSnapshotProvider('b1'))
        .data!
        .agents
        .single
        .agent, 'recovered');
  });

  test('暂停期间 session 依赖重建不会偷偷恢复轮询', () async {
    SnapshotNotifier.pollInterval = const Duration(milliseconds: 20);
    addTearDown(() {
      SnapshotNotifier.pollInterval = const Duration(seconds: 3);
    });
    final api = FakeBridgeApi('b1');
    final container = await buildContainer(api, FakeBridgeApi('b2'));

    await waitSnapshot(container, 'b1');
    final notifier = container.read(bridgeSnapshotProvider('b1').notifier);
    notifier.setPaused(true);
    final countAtPause = api.getSnapshotCount;

    container.read(sessionFilterProvider('b1').notifier).select('ops');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(api.getSnapshotCount, countAtPause);

    final resumed = waitSnapshot(container, 'b1');
    notifier.setPaused(false);
    await resumed;
    expect(api.getSnapshotCount, greaterThan(countAtPause));
  });
}

class _FlakyBridgeApi extends FakeBridgeApi {
  _FlakyBridgeApi() : super('recovered');

  bool _failed = false;

  @override
  Future<Snapshot> getSnapshot(
      {String? session, CancelToken? cancelToken}) {
    if (!_failed) {
      _failed = true;
      getSnapshotCount++;
      seenSessions.add(session);
      return Future.error(const ApiException('暂时不可达'));
    }
    return super.getSnapshot(session: session, cancelToken: cancelToken);
  }
}

class _SuspendingBridgeApi extends FakeBridgeApi {
  _SuspendingBridgeApi() : super('unused');

  final _firstRequest = Completer<Snapshot>();
  CancelToken? firstCancelToken;

  @override
  Future<Snapshot> getSnapshot(
      {String? session, CancelToken? cancelToken}) {
    getSnapshotCount++;
    seenSessions.add(session);
    if (getSnapshotCount == 1) {
      firstCancelToken = cancelToken;
      return _firstRequest.future;
    }
    return Future.value(_snapshot('recovered', 2));
  }

  void completeFirstRequest() => _firstRequest.complete(_snapshot('stale', 1));

  Snapshot _snapshot(String agent, int ts) => Snapshot(
        bridgeConnected: true,
        agents: [
          PaneInfo(
            paneId: 'w0',
            workspaceId: 'w0',
            workspaceLabel: 'ws0',
            workspaceNumber: 0,
            tabId: 'w0:t0',
            agent: agent,
            status: AgentStatus.working,
            cwd: '/repo',
            focused: false,
          ),
        ],
        shellPanes: const [],
        workspaces: const [],
        tabs: const [],
        sessions: const [],
        ts: ts,
      );
}
