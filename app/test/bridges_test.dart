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
/// - focusedBridgeProvider 默认 ''，select 切换。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/model/models.dart';
import 'package:herdr_web/model/remote_profile.dart';
import 'package:herdr_web/state/bridges.dart';
import 'package:herdr_web/state/easytier_runtime.dart';
import 'package:herdr_web/state/settings.dart';
import 'package:herdr_web/state/snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'easytier_runtime_test.dart' show FakeEasyTierChannel;

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
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 500);
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
      expect(conn.api!.baseUrl, 'http://127.0.0.1:40001');
      expect(container.read(apiProvider('pa'))!.baseUrl,
          'http://127.0.0.1:40001');
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
}
