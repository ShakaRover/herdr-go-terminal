import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notify/notify_service.dart';
import 'state/settings.dart';
import 'state/snapshot.dart';
import 'ui/agent/agent_screen.dart';
import 'ui/dashboard/dashboard_screen.dart';
import 'ui/settings/settings_screen.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void _openPane(String paneId) {
  navigatorKey.currentState?.push(
    MaterialPageRoute(builder: (_) => AgentScreen(paneId: paneId)),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  // 后台 blocked 通知是 Android-only（WorkManager）；iOS v1 不做后台轮询。
  String? launchPaneId;
  if (defaultTargetPlatform == TargetPlatform.android) {
    await registerBackgroundWatch();
    await initNotifications(onTap: _openPane);
    launchPaneId = await consumeLaunchPaneId();
  }
  runApp(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: HerdrApp(launchPaneId: launchPaneId),
    ),
  );
}

class HerdrApp extends StatelessWidget {
  const HerdrApp({super.key, this.launchPaneId});

  /// 冷启动由通知拉起时目标 pane。
  final String? launchPaneId;

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
      home: RootGate(launchPaneId: launchPaneId),
    );
  }
}

/// 已配置 bridge → dashboard；未配置 → 设置页。
/// 同时负责 app 前后台切换时暂停/恢复 snapshot 轮询。
class RootGate extends ConsumerStatefulWidget {
  const RootGate({super.key, this.launchPaneId});

  final String? launchPaneId;

  @override
  ConsumerState<RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<RootGate> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        ref
            .read(snapshotProvider.notifier)
            .setPaused(state != AppLifecycleState.resumed);
      },
    );
    final paneId = widget.launchPaneId;
    if (paneId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openPane(paneId));
    }
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(settingsProvider).isConfigured;
    return configured ? const DashboardScreen() : const SettingsScreen();
  }
}
