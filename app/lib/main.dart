import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notify/notify_service.dart';
import 'state/bridges.dart';
import 'state/settings.dart';
import 'state/snapshot.dart';
import 'ui/agent/agent_screen.dart';
import 'ui/dashboard/dashboard_screen.dart';
import 'ui/settings/settings_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

/// 通知点击直达对应 bridge 的详情页。升级期旧通知 payload 无 bridgeId
///（decode 回退 ''）：忽略并停在 dashboard。
void _openPane(String bridgeId, String paneId) {
  if (bridgeId.isEmpty) return;
  navigatorKey.currentState?.push(
    MaterialPageRoute(
      builder: (_) => AgentScreen(bridgeId: bridgeId, paneId: paneId),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // 后台 blocked 通知是 Android-only（WorkManager）；iOS v1 不做后台轮询。
  (String, String)? launchTarget;
  if (defaultTargetPlatform == TargetPlatform.android) {
    await registerBackgroundWatch();
    await initNotifications(onTap: _openPane);
    launchTarget = await consumeLaunchTarget();
  }
  runApp(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: HerdrApp(launchTarget: launchTarget),
    ),
  );
}

class HerdrApp extends StatelessWidget {
  const HerdrApp({super.key, this.launchTarget});

  /// 冷启动由通知拉起时的目标（bridgeId, paneId）。
  final (String, String)? launchTarget;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'herdr',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: RootGate(launchTarget: launchTarget),
    );
  }
}

/// 任一 enabled bridge 连接存在即视为已配置（RootGate 据此进 dashboard）。
/// bridgesProvider 只含 enabled 项。
bool hasAnyConnection(WidgetRef ref) =>
    ref.watch(bridgesProvider).isNotEmpty;

/// 任一 enabled bridge 连接存在 → dashboard；空配置 → 设置页。
/// 同时负责 app 前后台切换时暂停/恢复各 bridge 的 snapshot 轮询（后台停
/// 轮询 → 前台心跳停写 → 通知抑制按 foregroundFreshWindow 自然解除）。
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.launchTarget});

  final (String, String)? launchTarget;

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onStateChange: _onLifecycle);
    // 冷启动由通知拉起：launchTarget 只消费一次（build 会随
    // bridgesProvider 反复重建，放 build 里调度会叠多个相同详情页）。
    final target = widget.launchTarget;
    if (target != null) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _openPane(target.$1, target.$2));
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  /// 退后台：标记后台并暂停每条 enabled bridge 的快照轮询；回前台恢复。
  void _onLifecycle(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    ref.read(appForegroundProvider.notifier).setForeground(foreground);
    for (final conn in ref.read(bridgesProvider)) {
      ref
          .read(bridgeSnapshotProvider(conn.id).notifier)
          .setPaused(!foreground);
    }
  }

  @override
  Widget build(BuildContext context) {
    return hasAnyConnection(ref)
        ? const DashboardScreen()
        : const SettingsScreen();
  }
}
