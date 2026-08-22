/// bridgeSnapshotProvider / sessionFilterProvider 按 bridgeId family 化的测试。
///
/// fake api 按 bridge 脚本化（apiProvider(bridgeId) family override），验证：
/// - bridgeSnapshotProvider('b1') 与 ('b2') 各自轮询互不干扰；
/// - getSnapshot 带 sessionFilterProvider(bridgeId) 的当前值；
/// - sessionFilterProvider('b1') 的 select 不影响 ('b2')。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/api/bridge_api.dart';
import 'package:herdr_web/model/models.dart';
import 'package:herdr_web/state/bridges.dart';
import 'package:herdr_web/state/settings.dart';
import 'package:herdr_web/state/snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// fake BridgeApi：脚本化 snapshot 的 agents，捕获 session 参数。
class FakeBridgeApi extends BridgeApi {
  FakeBridgeApi(this.agentName) : super(baseUrl: 'http://127.0.0.1:1');

  final String agentName;
  final seenSessions = <String?>[];

  @override
  Future<Snapshot> getSnapshot({String? session}) async {
    seenSessions.add(session);
    return Snapshot(
      bridgeConnected: true,
      agents: [
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
}
