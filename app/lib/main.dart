import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/easytier_channel.dart';
import 'notify/notify_service.dart';
import 'l10n/generated/app_localizations.dart';
import 'state/bridges.dart';
import 'state/easytier_runtime.dart';
import 'state/settings.dart';
import 'state/snapshot.dart';
import 'ui/agent/agent_screen.dart';
import 'ui/dashboard/dashboard_screen.dart';

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
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      await const EasyTierChannel().configureDiagnosticLogging(
        prefs.getBool(diagnosticLoggingPreferenceKey) ?? false,
      );
    } catch (error) {
      debugPrint('Failed to restore EasyTier diagnostic logging: $error');
    }
  }
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

class HerdrApp extends ConsumerWidget {
  const HerdrApp({super.key, this.launchTarget});

  /// 冷启动由通知拉起时的目标（bridgeId, paneId）。
  final (String, String)? launchTarget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(appLocaleProvider).locale;
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appName,
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
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

/// App 首页以及前后台生命周期入口。
///
/// 首页始终保留 dashboard；空配置时由 dashboard 提供添加设备入口，避免把
/// 设置页当成无法返回的根路由。同时负责 app 前后台切换时暂停/恢复各 bridge
/// 的 snapshot 轮询；iOS 还会撤销/重建回环端口转发，EasyTier 实例本身始终
/// 保持运行。
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.launchTarget});

  final (String, String)? launchTarget;

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  late final AppLifecycleListener _lifecycleListener;
  bool _foreground = true;
  int _lifecycleGeneration = 0;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onStateChange: _onLifecycle);
    // 冷启动由通知拉起：launchTarget 只消费一次（build 会随
    // bridgesProvider 反复重建，放 build 里调度会叠多个相同详情页）。
    final target = widget.launchTarget;
    if (target != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openPane(target.$1, target.$2),
      );
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  /// 非 resumed 的多个中间状态只处理一次。iOS 普通 app 挂起时可能回收
  /// listener 的内核资源却不唤醒 Tokio accept，因此退后台先撤销转发，
  /// 回前台重建成功后再恢复轮询。这个历史兼容逻辑必须留在宿主 app 层，
  /// 不要把 iOS 生命周期概念下沉到 EasyTier core。
  void _onLifecycle(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    final generation = ++_lifecycleGeneration;
    unawaited(_applyLifecycle(foreground, generation));
  }

  Future<void> _applyLifecycle(bool foreground, int generation) async {
    ref.read(appForegroundProvider.notifier).setForeground(foreground);
    final connections = ref.read(bridgesProvider);

    if (!foreground) {
      for (final conn in connections) {
        ref.read(bridgeSnapshotProvider(conn.id).notifier).setPaused(true);
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await Future.wait([
          for (final conn in connections)
            ref
                .read(easytierRuntimeProvider(conn.id).notifier)
                .suspendPortForward(),
        ]);
      }
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // 每条 bridge 独立恢复：某个远端不可达时，其可达性探测会继续等待，
      // 但不能阻塞其他 bridge 已经恢复的快照轮询。
      for (final conn in connections) {
        unawaited(_resumeBridge(conn.id, generation));
      }
      return;
    }
    if (!mounted || generation != _lifecycleGeneration) return;
    for (final conn in connections) {
      ref.read(bridgeSnapshotProvider(conn.id).notifier).setPaused(false);
    }
  }

  Future<void> _resumeBridge(String bridgeId, int generation) async {
    if (!ref.read(enabledProfilesProvider).any((p) => p.id == bridgeId)) return;
    await ref
        .read(easytierRuntimeProvider(bridgeId).notifier)
        .resumePortForward();
    if (!mounted || generation != _lifecycleGeneration) return;
    if (!ref.read(enabledProfilesProvider).any((p) => p.id == bridgeId)) return;
    if (ref.read(easytierRuntimeProvider(bridgeId)) is! EasyTierReady) return;
    ref.read(bridgeSnapshotProvider(bridgeId).notifier).setPaused(false);
  }

  @override
  Widget build(BuildContext context) {
    return const DashboardScreen();
  }
}
