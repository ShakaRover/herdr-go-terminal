/// snapshot 轮询与 triage 排序。
///
/// 对齐 collie web 的拉取模型：定时轮询 `/api/snapshot`，失败保留旧数据
/// 并在 UI 顶部露错误条，下一次成功自愈。app 退到后台时暂停轮询。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/models.dart';
import '../notify/blocked_watch.dart';
import 'settings.dart';

/// 多 session 部署下当前选中的 herdr session（null = primary）。
class SessionFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? name) => state = name;
}

final sessionFilterProvider =
    NotifierProvider<SessionFilterNotifier, String?>(SessionFilterNotifier.new);

class SnapshotState {
  const SnapshotState({this.data, this.error, this.lastOk});

  /// 最近一次成功的快照；失败后保留（stale-while-error）。
  final Snapshot? data;

  /// 最近一次刷新的错误；成功后清空。
  final Object? error;
  final DateTime? lastOk;

  bool get hasData => data != null;
}

class SnapshotNotifier extends Notifier<SnapshotState> {
  static const _interval = Duration(seconds: 3);

  Timer? _timer;
  bool _inFlight = false;
  DateTime? _lastHeartbeat;

  @override
  SnapshotState build() {
    final api = ref.watch(apiProvider);
    // session 切换也触发重建（重新拉对应会话的数据）。
    ref.watch(sessionFilterProvider);
    ref.onDispose(() => _timer?.cancel());
    if (api == null) return const SnapshotState();
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => refresh());
    // build 期间不允许写 state，推迟到微任务。
    Future.microtask(refresh);
    return const SnapshotState();
  }

  void setPaused(bool paused) {
    if (paused) {
      _timer?.cancel();
      _timer = null;
    } else if (_timer == null) {
      _timer = Timer.periodic(_interval, (_) => refresh());
      Future.microtask(refresh);
    }
  }

  Future<void> refresh() async {
    final api = ref.read(apiProvider);
    if (api == null || _inFlight) return;
    _inFlight = true;
    try {
      final snap =
          await api.getSnapshot(session: ref.read(sessionFilterProvider));
      state = SnapshotState(data: snap, lastOk: DateTime.now());
      _stampForegroundHeartbeat();
    } catch (e) {
      state = SnapshotState(data: state.data, error: e, lastOk: state.lastOk);
    } finally {
      _inFlight = false;
    }
  }

  /// 前台轮询成功 → 节流写心跳，后台任务据此判断「用户正在看」而不发通知。
  void _stampForegroundHeartbeat() {
    final now = DateTime.now();
    if (_lastHeartbeat != null &&
        now.difference(_lastHeartbeat!) < heartbeatWriteInterval) {
      return;
    }
    _lastHeartbeat = now;
    ref
        .read(sharedPrefsProvider)
        .setInt(foregroundHeartbeatKey, now.millisecondsSinceEpoch);
  }
}

final snapshotProvider =
    NotifierProvider<SnapshotNotifier, SnapshotState>(SnapshotNotifier.new);

// ---------------------------------------------------------------------------
// triage 排序（纯函数，便于测试）
// ---------------------------------------------------------------------------

/// 按 collie 的 STATUS_RANK 排序：blocked > working > unknown > idle > done；
/// 同级按 lastActiveAt 新的在前（缺失视为最旧）。
List<PaneInfo> triageSorted(List<PaneInfo> panes) {
  final sorted = [...panes];
  sorted.sort((a, b) {
    final r = statusRank(a.status).compareTo(statusRank(b.status));
    if (r != 0) return r;
    return (b.lastActiveAt ?? 0).compareTo(a.lastActiveAt ?? 0);
  });
  return sorted;
}
