/// snapshot 轮询与 triage 排序（per bridge）。
///
/// 对齐 collie web 的拉取模型：定时轮询 `/api/snapshot`，失败保留旧数据
/// 并在 UI 顶部露错误条，下一次成功自愈。app 退到后台时暂停轮询。
/// 多 bridge 下每个 bridgeId 一条独立的 3s 轮询回路（family）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/models.dart';
import 'bridges.dart';

/// 多 session 部署下当前选中的 herdr session（null = primary），per bridge。
class SessionFilterNotifier extends Notifier<String?> {
  /// family 参数：bridgeId。
  SessionFilterNotifier(this.bridgeId);

  final String bridgeId;

  @override
  String? build() => null;

  void select(String? name) => state = name;
}

final sessionFilterProvider =
    NotifierProvider.family<SessionFilterNotifier, String?, String>(
        SessionFilterNotifier.new);

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
  /// family 参数：bridgeId。
  SnapshotNotifier(this.bridgeId);

  static const _interval = Duration(seconds: 3);

  final String bridgeId;
  Timer? _timer;
  bool _inFlight = false;

  @override
  SnapshotState build() {
    final api = ref.watch(apiProvider(bridgeId));
    // session 切换也触发重建（重新拉对应会话的数据）。
    ref.watch(sessionFilterProvider(bridgeId));
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
    final api = ref.read(apiProvider(bridgeId));
    if (api == null || _inFlight) return;
    _inFlight = true;
    try {
      final snap = await api.getSnapshot(
          session: ref.read(sessionFilterProvider(bridgeId)));
      // await 后 provider 可能已随 bridgesProvider 重建被销毁。
      if (!ref.mounted) return;
      state = SnapshotState(data: snap, lastOk: DateTime.now());
    } catch (e) {
      if (!ref.mounted) return;
      state = SnapshotState(data: state.data, error: e, lastOk: state.lastOk);
    } finally {
      _inFlight = false;
    }
  }
}

/// 单 bridge 的 snapshot 轮询（3s、stale-while-error）。
/// 前台心跳与 blocked 通知副作用在 bridgesProvider（state/bridges.dart）。
final bridgeSnapshotProvider =
    NotifierProvider.family<SnapshotNotifier, SnapshotState, String>(
        SnapshotNotifier.new);

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
