/// RootGate 的 widget 测试：
/// - launchTarget 只消费一次：先让冷启动 push AgentScreen，pop 掉露出
///   home 后制造 bridgesProvider 重建风暴，确认不会再 push；
/// - AppLifecycleListener 驱动前后台切换：退后台对各 enabled bridge
///   setPaused(true)（轮询停止）并标记 appForegroundProvider=false，回前台
///   恢复。
///
/// 两个坑：
/// - 不能用 pumpAndSettle：snapshot/paneRead 的常驻轮询计时器会让它拖到
///   超时，一律用固定步长的 pump；
/// - 被不透明路由盖住的后页 TickerMode 关闭，riverpod 3 会暂停其 provider
///   订阅（不再重建）——所以「重建风暴」必须在 pop 详情页、home 重新露出
///   之后制造，否则旧实现在测试里根本重建不出来。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/main.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/state/easytier_runtime.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/ui/agent/agent_screen.dart';
import 'package:herdrgo/ui/dashboard/dashboard_screen.dart';
import 'package:herdrgo/ui/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridges_test.dart' show profileA, RecordingBlockedNotifier;
import 'easytier_runtime_test.dart' show FakeEasyTierChannel;

/// 最简 fake api：getSnapshot/readPane 各返回固定内容，记录 getSnapshot
/// 调用次数（轮询暂停/恢复断言用）。
class _FakeBridgeApi extends BridgeApi {
  _FakeBridgeApi() : super(baseUrl: 'http://127.0.0.1:1');

  int getSnapshotCount = 0;

  @override
  Future<Snapshot> getSnapshot({String? session}) async {
    getSnapshotCount++;
    return Snapshot(
      bridgeConnected: true,
      agents: const [],
      shellPanes: const [],
      workspaces: const [],
      tabs: const [],
      sessions: const [],
      ts: 1,
    );
  }

  @override
  Future<PaneRead> readPane(String paneId,
      {int? lines, String? session}) async {
    return PaneRead(paneId: paneId, text: '', truncated: false, revision: 1);
  }
}

/// 固定步长打若干帧（见文件头：本文件不能 pumpAndSettle）。
Future<void> _pumpFrames(WidgetTester tester,
    [int frames = 10, Duration step = const Duration(milliseconds: 200)]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(step);
  }
}

Future<void> _pumpApp(
  WidgetTester tester,
  _FakeBridgeApi api, {
  (String, String)? launchTarget,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        easytierChannelProvider.overrideWithValue(FakeEasyTierChannel()),
        blockedNotifierProvider.overrideWithValue(RecordingBlockedNotifier()),
        apiProvider.overrideWith(
            (ref, bridgeId) => bridgeId == 'pa' ? api : null),
      ],
      child: HerdrApp(launchTarget: launchTarget),
    ),
  );
}

void main() {
  testWidgets('launchTarget 只消费一次：bridgesProvider 重建不重复 push '
      'AgentScreen', (tester) async {
    final api = _FakeBridgeApi();
    await _pumpApp(tester, api, launchTarget: ('pa', 'w1'));
    await _pumpFrames(tester);
    // RootGate 此时被 AgentScreen 盖住（offstage），找元素要带 skipOffstage。
    final container = ProviderScope.containerOf(
        tester.element(find.byType(RootGate, skipOffstage: false)),
        listen: false);
    // 空配置 → 设置页；post-frame 完成首次 push（含路由动画）。
    expect(find.byType(SettingsScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(AgentScreen, skipOffstage: false), findsOneWidget);

    // 弹掉详情页露出 home（见文件头：被盖住的后页不会重建）。
    navigatorKey.currentState!.pop();
    await _pumpFrames(tester);
    expect(find.byType(AgentScreen, skipOffstage: false), findsNothing);

    // 启动期 bridgesProvider 反复重建（空 → connecting → ready）：若
    // launchTarget 在 build 里消费，每次重建都会再 push 一个 AgentScreen。
    await container.read(profileStoreProvider).add(profileA);
    await container.read(enabledProfilesProvider.notifier).reload();
    expect(container.read(bridgesProvider), isNotEmpty,
        reason: 'enabled profile 接入后 bridgesProvider 应立即重建为非空');
    await _pumpFrames(tester, 20);
    expect(find.byType(DashboardScreen), findsOneWidget);
    // 再多打几帧，确认不会再叠。
    await _pumpFrames(tester);

    expect(find.byType(AgentScreen, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退后台暂停各 bridge 轮询并标记后台；回前台恢复', (tester) async {
    final api = _FakeBridgeApi();
    await _pumpApp(tester, api);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(RootGate)),
        listen: false);
    await container.read(profileStoreProvider).add(profileA);
    await container.read(enabledProfilesProvider.notifier).reload();
    await _pumpFrames(tester);
    expect(find.byType(DashboardScreen), findsOneWidget);
    expect(container.read(appForegroundProvider), isTrue);

    // 前台轮询持续推进。
    final count1 = api.getSnapshotCount;
    await _pumpFrames(tester, 10, const Duration(seconds: 1));
    expect(api.getSnapshotCount, greaterThan(count1));

    // 退后台（resumed → inactive → hidden → paused，遵循
    // AppLifecycleListener 的合法状态机）：轮询停止、标记转 false。
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
    expect(container.read(appForegroundProvider), isFalse);
    final countAtPause = api.getSnapshotCount;
    await _pumpFrames(tester, 5, const Duration(seconds: 2));
    expect(api.getSnapshotCount, countAtPause, reason: '退后台后轮询应停止');

    // 回前台（paused → hidden → inactive → resumed）：恢复轮询、标记回 true。
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
    expect(container.read(appForegroundProvider), isTrue);
    await _pumpFrames(tester, 10, const Duration(seconds: 1));
    expect(api.getSnapshotCount, greaterThan(countAtPause),
        reason: '回前台后轮询应恢复');
  });
}
