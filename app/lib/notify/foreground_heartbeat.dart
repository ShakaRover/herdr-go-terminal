/// 前台心跳写的节流器（无 Flutter 依赖，纯 Dart 可测）。
///
/// 前台轮询每 3s 一次，心跳写盘按 [heartbeatWriteInterval] 节流；
/// 后台通知任务（以及前台通知副作用）据此判断「用户正在看」。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'blocked_watch.dart';

/// 前台轮询写心跳的最小间隔（避免每次轮询都写盘）。
const heartbeatWriteInterval = Duration(seconds: 15);

class ForegroundHeartbeat {
  DateTime? _last;

  /// 距上次写不足 [heartbeatWriteInterval] 时跳过。
  void stamp(SharedPreferences prefs) {
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) < heartbeatWriteInterval) {
      return;
    }
    _last = now;
    prefs.setInt(foregroundHeartbeatKey, now.millisecondsSinceEpoch);
  }
}
