/// 本地通知封装 + workmanager 后台任务壳。
///
/// 通知 payload 是 `<bridgeId>\n<paneId>`，点击直达对应 bridge 的详情页。
/// 全 EasyTier 后没有可在后台 isolate 直连的配置（EasyTier 实例只能活在
/// app 进程里），后台不再轮询：实际通知路径是 app 活着时 bridgesProvider
/// 对 bridgeSnapshotProvider 的前台监听（见 state/bridges.dart）。后台
/// isolate 只保留 workmanager 注册/入口壳，任务体是空操作。
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

const _taskUniqueName = 'herdr-blocked-watch';
const _taskName = 'blockedWatch';
const _channelId = 'agent_blocked';

final _plugin = FlutterLocalNotificationsPlugin();

/// 通知 payload：`<bridgeId>\n<paneId>`（换行分隔，paneId 本身不含 \n）。
String encodeNotifyPayload(String bridgeId, String paneId) =>
    '$bridgeId\n$paneId';

/// 解析通知 payload。升级期旧通知无换行（只有 paneId）：bridgeId 回退 ''，
/// 调用方按「忽略并回到 dashboard」处理。
(String, String) decodeNotifyPayload(String payload) {
  final i = payload.indexOf('\n');
  if (i < 0) return ('', payload);
  return (payload.substring(0, i), payload.substring(i + 1));
}

/// 初始化通知（前台调用一次）。onTap: 点击通知携带的 bridgeId/paneId 导航。
Future<void> initNotifications({
  required void Function(String bridgeId, String paneId) onTap,
}) async {
  await _plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (res) {
      final payload = res.payload;
      if (payload != null && payload.isNotEmpty) {
        final (bridgeId, paneId) = decodeNotifyPayload(payload);
        onTap(bridgeId, paneId);
      }
    },
  );
  await _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
}

/// 冷启动时被通知拉起的目标（bridgeId, paneId；没有则 null）。
Future<(String, String)?> consumeLaunchTarget() async {
  final details = await _plugin.getNotificationAppLaunchDetails();
  if (details?.didNotificationLaunchApp ?? false) {
    final payload = details!.notificationResponse?.payload;
    if (payload != null && payload.isNotEmpty) {
      return decodeNotifyPayload(payload);
    }
  }
  return null;
}

/// 发一条 blocked 通知。title 加 `[宿主机 label]` 前缀；通知 id 按
/// bridgeId:paneId 稳定去重（同一 pane 重复通知覆盖而非堆叠）。
Future<void> showBlockedNotification(
  String bridgeId,
  String paneId,
  String label,
  String title,
  String body,
  String channelName,
  String channelDescription,
) {
  return _plugin.show(
    id: '$bridgeId:$paneId'.hashCode & 0x7fffffff,
    title: '[$label] $title',
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        channelName,
        channelDescription: channelDescription,
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
    payload: encodeNotifyPayload(bridgeId, paneId),
  );
}

/// 注册周期后台任务（app 启动时调用）。全 EasyTier 后后台 isolate 没有
/// 可直连的配置，任务体是空操作；保留注册只为未来恢复后台轮询时不必
/// 再动 workmanager 接线。
Future<void> registerBackgroundWatch() async {
  await Workmanager().initialize(blockedWatchDispatcher);
  await Workmanager().registerPeriodicTask(
    _taskUniqueName,
    _taskName,
    frequency: const Duration(minutes: 15),
  );
}

/// workmanager 入口。跑在独立的后台 isolate：全 EasyTier 后这里没有任何
/// 可直连的 bridge（EasyTier 实例随 app 进程存活），不做轮询，直接返回。
@pragma('vm:entry-point')
void blockedWatchDispatcher() {
  Workmanager().executeTask((task, inputData) async => true);
}
