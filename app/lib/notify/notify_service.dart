/// 本地通知封装 + workmanager 后台任务。
///
/// 后台任务（≥15min 周期，Android WorkManager 下限）拉一次 snapshot，
/// 对新增 blocked 的 agent 发本地通知；payload 带 paneId，点击直达详情页。
library;

import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../api/bridge_api.dart';
import '../state/settings.dart';
import 'blocked_watch.dart';

const _taskUniqueName = 'herdr-blocked-watch';
const _taskName = 'blockedWatch';
const _channelId = 'agent_blocked';

final _plugin = FlutterLocalNotificationsPlugin();

/// 初始化通知（前台调用一次）。onTap: 点击通知携带的 paneId 导航。
Future<void> initNotifications({
  required void Function(String paneId) onTap,
}) async {
  await _plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (res) {
      final payload = res.payload;
      if (payload != null && payload.isNotEmpty) onTap(payload);
    },
  );
  await _plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

/// 冷启动时被通知拉起的 paneId（没有则 null）。
Future<String?> consumeLaunchPaneId() async {
  final details = await _plugin.getNotificationAppLaunchDetails();
  if (details?.didNotificationLaunchApp ?? false) {
    final payload = details!.notificationResponse?.payload;
    if (payload != null && payload.isNotEmpty) return payload;
  }
  return null;
}

Future<void> _showBlocked(String paneId, String title, String body) {
  return _plugin.show(
    // 每个 pane 一个稳定 id：同一 pane 重复通知覆盖而非堆叠。
    id: paneId.hashCode & 0x7fffffff,
    title: title,
    body: body,
    notificationDetails: const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'agent 待处理',
        channelDescription: 'agent 停下来等你回复时提醒你',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: paneId,
  );
}

/// 注册周期后台任务（app 启动时调用；未配置 bridge 时任务会空转返回）。
Future<void> registerBackgroundWatch() async {
  await Workmanager().initialize(blockedWatchDispatcher);
  await Workmanager().registerPeriodicTask(
    _taskUniqueName,
    _taskName,
    frequency: const Duration(minutes: 15),
  );
}

/// workmanager 入口。跑在独立的后台 isolate，不能用 app 的 Riverpod
/// 容器——直接从 shared_preferences 读设置，手工构造 API 客户端。
@pragma('vm:entry-point')
void blockedWatchDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final settingsRaw = prefs.getString(bridgeSettingsPrefsKey);
      if (settingsRaw == null || settingsRaw.isEmpty) return true;
      final decoded = jsonDecode(settingsRaw);
      if (decoded is! Map<String, dynamic>) return true;
      final settings = BridgeSettings.fromJson(decoded);
      if (!settings.isConfigured) return true;

      // 前台心跳新鲜：用户正在看 app，不用通知。
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (shouldSuppress(prefs, nowMs: nowMs)) return true;

      final api =
          BridgeApi(baseUrl: settings.baseUrl, headers: settings.headers);
      final snap = await api.getSnapshot();

      final seen = readSeen(prefs);
      final fresh = newlyBlocked(snap, seen);
      for (final p in fresh) {
        await _showBlocked(
          p.paneId,
          '${p.displayName} 需要你处理',
          '${p.workspaceLabel} · ${p.agent}',
        );
      }
      await writeSeen(prefs, updateSeen(seen, snap, nowMs: nowMs));
      return true;
    } catch (_) {
      // 网络抖动/bridge 重启等：本轮放弃，下个周期再来。
      return true;
    }
  });
}
