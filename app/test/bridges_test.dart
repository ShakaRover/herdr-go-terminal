/// bridgesProvider / apiProvider family / focusedBridgeProvider /
/// aggregateBridgePanes 的测试（全 EasyTier，无直连分支）。
///
/// 用 fake EasyTierChannel（easytierChannelProvider override）+ 内存 prefs
/// 验证：
/// - 空配置 → bridgesProvider 空列表、apiProvider('x') null；
/// - 一条 enabled profile → 初态 connecting，fake 推进到 Ready 后 conn ready
///   且 api 指向 `127.0.0.1:<localPort>`；
/// - profile enabled=false → 列表无此项且不 startInstance；
/// - EasyTier Failed → conn failed 带 message；
/// - aggregateBridgePanes：状态优先，同状态按宿主机 label 字典序、再按
///   lastActiveAt 新的在前；failed/connecting 的 bridge 不参与聚合；
/// - focusedBridgeProvider 默认 ''，select 切换；
/// - blocked 通知路径（Android 前台 listener，apiProvider family override 成
///   脚本化 fake api）：心跳新鲜时抑制；心跳过期 + 新快照发通知写 seen；
///   退后台暂停轮询/停写心跳，回前台后补发。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/model/remote_profile.dart';
import 'package:herdrgo/notify/blocked_watch.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/state/easytier_runtime.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/state/snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'easytier_runtime_test.dart' show FakeEasyTierChannel;
import 'snapshot_multi_test.dart' show FakeBridgeApi;

const profileA = RemoteProfile(
  id: 'pa',
  label: 'alpha',
  server: ['tcp://10.0.0.2:22023'],
  networkName: 'net-a',
  secret: 's1',
  virtualIp: '10.10.64.62',
  port: 46810,
);

const profileB = RemoteProfile(
  id: 'pb',
  label: 'beta',
  server: ['tcp://10.0.0.3:22023'],
  networkName: 'net-b',
  secret: 's2',
  virtualIp: '10.10.64.99',
  port: 46811,
);

/// 用给定的 prefs 初始值 + fake channel 建 container。
Future<ProviderContainer> buildContainer(
  FakeEasyTierChannel channel, {
  Map<String, Object> initialValues = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(prefs),
    easytierChannelProvider.overrideWithValue(channel),
    bridgeReachabilityProbeProvider.overrideWithValue((_, _) async => true),
    // bridgesProvider 的 Android 通知副作用会 listen bridgeSnapshotProvider；
    // 本文件不测通知，发信口 override 成 no-op 避免触碰 method channel。
    blockedNotifierProvider.overrideWithValue(_NoopBlockedNotifier()),
  ]);
  addTearDown(container.dispose);
  return container;
}

class _NoopBlockedNotifier implements BlockedNotifier {
  @override
  Future<void> show(String bridgeId, String paneId, String label, String title,
          String body) async {}
}

/// 一次 blocked 通知调用的记录。
class NotifyCall {
  const NotifyCall(this.bridgeId, this.paneId, this.label, this.title,
      this.body);

  final String bridgeId;
  final String paneId;
  final String label;
  final String title;
  final String body;
}

/// 记录调用的 BlockedNotifier（通知路径测试用）。
class RecordingBlockedNotifier implements BlockedNotifier {
  final calls = <NotifyCall>[];

  @override
  Future<void> show(String bridgeId, String paneId, String label,
      String title, String body) async {
    calls.add(NotifyCall(bridgeId, paneId, label, title, body));
  }
}

/// 常驻监听 bridgesProvider（Provider 非 autoDispose，但保活以便后续读 notifier）。
Future<void> keepAliveBridges(ProviderContainer container) async {
  final sub = container.listen(bridgesProvider, (_, _) {});
  addTearDown(sub.close);
  await pumpEventQueue();
}

/// 等某 bridge 的 conn 状态满足条件（超时即失败）。
Future<BridgeConn> waitConn(
  ProviderContainer container,
  String id,
  bool Function(BridgeConn) test,
) {
  final c = Completer<BridgeConn>();
  final sub = container.listen(bridgesProvider, (_, next) {
    for (final conn in next) {
      if (conn.id == id && test(conn) && !c.isCompleted) c.complete(conn);
    }
  });
  addTearDown(sub.close);
  return c.future.timeout(const Duration(seconds: 5));
}

void main() {
  setUp(() {
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 10);
  });
  tearDown(() {
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 250);
    EasyTierRuntimeNotifier.virtualIpTimeout = const Duration(seconds: 15);
  });

  group('bridgesProvider / apiProvider', () {
    test('空配置 → 空列表、apiProvider null，不触达通道', () async {
      final channel = FakeEasyTierChannel();
      final container = await buildContainer(channel);
      await keepAliveBridges(container);

      expect(container.read(bridgesProvider), isEmpty);
      expect(container.read(apiProvider('x')), isNull);
      expect(channel.calls, isEmpty);
    });

    test('一条 enabled profile：初态 connecting，Ready 后 conn ready '
        '且 api 指向 127.0.0.1:<localPort>', () async {
      final channel = FakeEasyTierChannel();
      final container = await buildContainer(channel);
      await container.read(profileStoreProvider).add(profileA);
      await container.read(enabledProfilesProvider.notifier).reload();

      final ready = waitConn(container, 'pa', (c) => c.status == ConnStatus.ready);
      await keepAliveBridges(container);

      // 初态 connecting（api 为 null）。
      final initial = container
          .read(bridgesProvider)
          .singleWhere((c) => c.id == 'pa');
      expect(initial.label, 'alpha');
      expect(initial.status, ConnStatus.connecting);
      expect(initial.api, isNull);
      expect(container.read(apiProvider('pa')), isNull);

      final conn = await ready;
      expect(conn.status, ConnStatus.ready);
      expect(conn.api, isNotNull);
      // localPort 是 runtime 真实抢占的回环端口，与 fake 记录的 bind 一致。
      expect(conn.api!.baseUrl, 'http://127.0.0.1:${channel.lastBindPort}');
      expect(container.read(apiProvider('pa'))!.baseUrl,
          'http://127.0.0.1:${channel.lastBindPort}');
      // 生命周期由 bridgesProvider 驱动：channel 确实 startInstance。
      expect(channel.calls, contains('startInstance'));
      expect(channel.startedConfigs, hasLength(1));
    });

    test('enabled=false 的 profile 不在列表、不 startInstance；'
        '重新 enable 后接入', () async {
      final channel = FakeEasyTierChannel();
      final container = await buildContainer(channel);
      final store = container.read(profileStoreProvider);
      await store.add(profileA);
      await store.setEnabled('pa', false);
      await container.read(enabledProfilesProvider.notifier).reload();
      await keepAliveBridges(container);

      expect(container.read(bridgesProvider), isEmpty);
      expect(channel.calls, isEmpty);

      // 重新 enable → connect 被驱动。
      final ready = waitConn(container, 'pa', (c) => c.status == ConnStatus.ready);
      await store.setEnabled('pa', true);
      await container.read(enabledProfilesProvider.notifier).reload();
      await ready;
      expect(channel.startedConfigs, hasLength(1));
    });

    test('两条 enabled profile：各自 connect，label 按 profile 序', () async {
      final channel = FakeEasyTierChannel();
      final container = await buildContainer(channel);
      await container.read(profileStoreProvider).add(profileA);
      await container.read(profileStoreProvider).add(profileB);
      await container.read(enabledProfilesProvider.notifier).reload();

      final ra = waitConn(container, 'pa', (c) => c.status == ConnStatus.ready);
      final rb = waitConn(container, 'pb', (c) => c.status == ConnStatus.ready);
      await keepAliveBridges(container);
      await Future.wait([ra, rb]);

      final conns = container.read(bridgesProvider);
      expect(conns.map((c) => (c.id, c.label)),
          [('pa', 'alpha'), ('pb', 'beta')]);
      expect(conns.every((c) => c.status == ConnStatus.ready), isTrue);
      expect(channel.startedConfigs, hasLength(2));
    });

    test('EasyTier Failed → conn failed 带 message，api 为 null', () async {
      final channel = FakeEasyTierChannel()
        ..startInstanceError =
            PlatformException(code: 'easytier', message: 'boom');
      final container = await buildContainer(channel);
      await container.read(profileStoreProvider).add(profileA);
      await container.read(enabledProfilesProvider.notifier).reload();

      final failed = waitConn(container, 'pa', (c) => c.status == ConnStatus.failed);
      await keepAliveBridges(container);
      final conn = await failed;

      expect(conn.status, ConnStatus.failed);
      expect('${conn.error}', contains('boom'));
      expect(conn.api, isNull);
      expect(container.read(apiProvider('pa')), isNull);
    });
  });

  group('focusedBridgeProvider', () {
    test("默认 ''，select 切换", () async {
      final container = await buildContainer(FakeEasyTierChannel());
      expect(container.read(focusedBridgeProvider), '');
      container.read(focusedBridgeProvider.notifier).select('pa');
      expect(container.read(focusedBridgeProvider), 'pa');
      container.read(focusedBridgeProvider.notifier).select('');
      expect(container.read(focusedBridgeProvider), '');
    });
  });

  group('aggregateBridgePanes', () {
    PaneInfo pane(String paneId, AgentStatus status, [int? lastActiveAt]) =>
        PaneInfo(
          paneId: paneId,
          workspaceId: 'w0',
          workspaceLabel: 'ws0',
          workspaceNumber: 0,
          tabId: 'w0:t0',
          agent: 'claude',
          status: status,
          cwd: '/repo',
          focused: false,
          lastActiveAt: lastActiveAt,
        );

    BridgeConn conn(String id, String label, ConnStatus status) => BridgeConn(
        id: id, label: label, status: status, api: null);

    SnapshotState snap(List<PaneInfo> agents) => SnapshotState(
        data: Snapshot(
            bridgeConnected: true,
            agents: agents,
            shellPanes: const [],
            workspaces: const [],
            tabs: const [],
            sessions: const [],
            ts: 1));

    test('blocked 在前；同状态按宿主机 label 字典序、再按 lastActiveAt 新的在前',
        () {
      final conns = [
        conn('b1', 'zeta', ConnStatus.ready),
        conn('b2', 'alpha', ConnStatus.ready),
        conn('b3', 'beta', ConnStatus.ready),
      ];
      final snapshots = {
        'b1': snap([pane('p1', AgentStatus.blocked, 100)]),
        'b2': snap([pane('p2', AgentStatus.working, 300)]),
        'b3': snap([
          pane('p3', AgentStatus.working, 200),
          pane('p4', AgentStatus.working, 400),
        ]),
      };

      final got = aggregateBridgePanes(conns, snapshots);
      expect(got.map((bp) => bp.pane.paneId), ['p1', 'p2', 'p4', 'p3']);
      // 聚合元素带 bridge 标识。
      expect(got.first.bridgeId, 'b1');
      expect(got.first.bridgeLabel, 'zeta');
    });

    test('failed/connecting 的 bridge 不参与聚合；无快照的 ready bridge 跳过',
        () {
      final conns = [
        conn('ok', 'ok', ConnStatus.ready),
        conn('fail', 'fail', ConnStatus.failed),
        conn('ing', 'ing', ConnStatus.connecting),
        conn('empty', 'empty', ConnStatus.ready),
      ];
      final snapshots = {
        'ok': snap([pane('p1', AgentStatus.idle, 1)]),
        'fail': snap([pane('p2', AgentStatus.blocked, 1)]),
        'ing': snap([pane('p3', AgentStatus.blocked, 1)]),
        // 'empty' 无快照数据。
      };

      final got = aggregateBridgePanes(conns, snapshots);
      expect(got.map((bp) => bp.pane.paneId), ['p1']);
    });
  });

  group('blocked 通知路径（Android 前台 listener）', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      SnapshotNotifier.pollInterval = const Duration(milliseconds: 40);
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      SnapshotNotifier.pollInterval = const Duration(seconds: 3);
    });

    const paneWorking = PaneInfo(
      paneId: 'w1',
      workspaceId: 'w0',
      workspaceLabel: 'ws0',
      workspaceNumber: 0,
      tabId: 'w0:t0',
      agent: 'claude',
      status: AgentStatus.working,
      cwd: '/repo',
      focused: false,
      lastActiveAt: 900,
    );
    const paneBlocked = PaneInfo(
      paneId: 'w1',
      workspaceId: 'w0',
      workspaceLabel: 'ws0',
      workspaceNumber: 0,
      tabId: 'w0:t0',
      agent: 'claude',
      status: AgentStatus.blocked,
      cwd: '/repo',
      focused: false,
      lastActiveAt: 1000,
    );

    /// 通知路径专用 container：apiProvider('pa') override 成脚本化 fake api，
    /// blockedNotifierProvider override 成记录调用的 fake。
    Future<ProviderContainer> buildNotifyContainer(
      FakeBridgeApi api,
      RecordingBlockedNotifier notifier, {
      Map<String, Object> initialValues = const {},
    }) async {
      SharedPreferences.setMockInitialValues(initialValues);
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        easytierChannelProvider.overrideWithValue(FakeEasyTierChannel()),
        blockedNotifierProvider.overrideWithValue(notifier),
        apiProvider.overrideWith(
            (ref, bridgeId) => bridgeId == 'pa' ? api : null),
      ]);
      addTearDown(container.dispose);
      await container.read(profileStoreProvider).add(profileA);
      await container.read(enabledProfilesProvider.notifier).reload();
      return container;
    }

    /// 等 bridgeSnapshotProvider(id) 出现满足条件的快照。
    Future<SnapshotState> waitSnapshotWhere(
      ProviderContainer container,
      String id,
      bool Function(SnapshotState) test,
    ) {
      final c = Completer<SnapshotState>();
      final sub = container.listen(bridgeSnapshotProvider(id), (_, next) {
        if (test(next) && !c.isCompleted) c.complete(next);
      });
      addTearDown(sub.close);
      return c.future.timeout(const Duration(seconds: 5));
    }

    /// 实时轮询直到条件满足（5s 超时）。
    Future<void> until(bool Function() test) async {
      for (var i = 0; i < 500 && !test(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(test(), isTrue, reason: 'until 条件超时');
    }

    int heartbeatMs(ProviderContainer container) =>
        container.read(sharedPrefsProvider).getInt(foregroundHeartbeatKey) ??
        0;

    test('前台心跳新鲜：新 blocked 被抑制，心跳被续写', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final api = FakeBridgeApi('claude')..scriptedAgents = [paneWorking];
      final notifier = RecordingBlockedNotifier();
      final container = await buildNotifyContainer(api, notifier,
          initialValues: {foregroundHeartbeatKey: now});
      final first = waitSnapshotWhere(container, 'pa', (s) => s.data != null);
      await keepAliveBridges(container);
      await first;

      // 首轮前台轮询：心跳被续写，无 blocked 无通知。
      expect(heartbeatMs(container), greaterThan(0));
      expect(notifier.calls, isEmpty);

      // 新快照出现 blocked pane：心跳新鲜 → 抑制（不发通知、不写 seen）。
      api.scriptedAgents = [paneBlocked];
      await waitSnapshotWhere(
          container,
          'pa',
          (s) =>
              s.data?.agents.any((p) => p.status == AgentStatus.blocked) ??
              false);
      await pumpEventQueue();
      expect(notifier.calls, isEmpty);
      expect(readSeen(container.read(sharedPrefsProvider)), isEmpty);
      // 心跳仍新鲜（被续写）。
      final age = DateTime.now().millisecondsSinceEpoch -
          heartbeatMs(container);
      expect(age, lessThan(foregroundFreshWindow.inMilliseconds));
    });

    test('心跳过期 + 新快照 → 发通知并写 seen；同数据后续快照不重复',
        () async {
      final stale = DateTime.now().millisecondsSinceEpoch -
          foregroundFreshWindow.inMilliseconds -
          10000;
      final api = FakeBridgeApi('claude')..scriptedAgents = [paneBlocked];
      final notifier = RecordingBlockedNotifier();
      final container = await buildNotifyContainer(api, notifier,
          initialValues: {foregroundHeartbeatKey: stale});
      final first = waitSnapshotWhere(container, 'pa', (s) => s.data != null);
      await keepAliveBridges(container);
      await first;

      await until(() => notifier.calls.isNotEmpty);
      expect(notifier.calls.single.bridgeId, 'pa');
      expect(notifier.calls.single.paneId, 'w1');
      expect(notifier.calls.single.label, 'alpha');
      await until(() =>
          readSeen(container.read(sharedPrefsProvider))
              .containsKey('pa:w1'));

      // 同数据继续轮询：seen 已记 + 前台心跳已续写，不重复通知。
      await until(() => api.getSnapshotCount >= 4);
      expect(notifier.calls, hasLength(1));
      final age = DateTime.now().millisecondsSinceEpoch -
          heartbeatMs(container);
      expect(age, lessThan(foregroundFreshWindow.inMilliseconds));
    });

    test('退后台：轮询暂停、心跳停写；心跳过期后回前台 → 新 blocked 补发通知',
        () async {
      final api = FakeBridgeApi('claude')..scriptedAgents = [paneWorking];
      final notifier = RecordingBlockedNotifier();
      final container = await buildNotifyContainer(api, notifier);
      final first = waitSnapshotWhere(container, 'pa', (s) => s.data != null);
      await keepAliveBridges(container);
      await first;
      // riverpod 3 的 listener 通知走微任务：bridgesProvider 的通知 listener
      // 可能晚于 waitSnapshotWhere 的完成，等心跳真正写入。
      await until(() => heartbeatMs(container) > 0);
      final hb1 = heartbeatMs(container);
      expect(hb1, greaterThan(0));

      // 退后台（与 RootGate 的 AppLifecycleListener 相同的动作）。
      container.read(appForegroundProvider.notifier).setForeground(false);
      container.read(bridgeSnapshotProvider('pa').notifier).setPaused(true);
      await pumpEventQueue(); // 放掉 pause 瞬间在途的 refresh
      final countAtPause = api.getSnapshotCount;

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(api.getSnapshotCount, countAtPause, reason: '退后台后轮询应停止');
      expect(notifier.calls, isEmpty);
      expect(heartbeatMs(container), hb1, reason: '退后台后心跳停写');

      // 60s+ 过去（心跳过期），期间出现 blocked。
      final stale = DateTime.now().millisecondsSinceEpoch -
          foregroundFreshWindow.inMilliseconds -
          10000;
      await container
          .read(sharedPrefsProvider)
          .setInt(foregroundHeartbeatKey, stale);
      api.scriptedAgents = [paneBlocked];

      // 回前台：轮询恢复，首个新快照补发通知并写 seen。
      container.read(appForegroundProvider.notifier).setForeground(true);
      container.read(bridgeSnapshotProvider('pa').notifier).setPaused(false);
      await until(() => notifier.calls.isNotEmpty);
      expect(notifier.calls.single.paneId, 'w1');
      await until(() =>
          readSeen(container.read(sharedPrefsProvider))
              .containsKey('pa:w1'));
      // 前台续写心跳已被「心跳过期 + 新快照」用例覆盖；这里节流器 _last 仍是
      // 测试开头的时间（<15s），stamp 会被节流逝过，不断言心跳值。
    });
  });
}
