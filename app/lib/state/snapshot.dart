/// snapshot 轮询与 triage 排序（per bridge）。
///
/// 对齐 collie web 的拉取模型：定时轮询 `/api/snapshot`，失败保留旧数据
/// 并在 UI 顶部露错误条，下一次成功自愈。app 退到后台时暂停轮询。
/// 多 bridge 下每个 bridgeId 一条独立的 3s 轮询回路（family）。
library;

import 'dart:async';

import 'package:dio/dio.dart';
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

  /// 轮询间隔（测试可覆盖；对齐 EasyTierRuntimeNotifier.pollInterval 的玩法）。
  static Duration pollInterval = const Duration(seconds: 3);
  static Duration retryInterval = const Duration(milliseconds: 500);

  final String bridgeId;
  Timer? _timer;
  Timer? _retryTimer;
  CancelToken? _cancelToken;
  int _refreshGeneration = 0;
  bool _inFlight = false;
  bool _paused = false;

  @override
  SnapshotState build() {
    final api = ref.watch(apiProvider(bridgeId));
    // session 切换也触发重建（重新拉对应会话的数据）。
    ref.watch(sessionFilterProvider(bridgeId));
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _cancelRefresh();
    ref.onDispose(() {
      _timer?.cancel();
      _retryTimer?.cancel();
      _cancelRefresh();
    });
    if (api == null || _paused) return const SnapshotState();
    _timer = Timer.periodic(pollInterval, (_) => refresh());
    // build 期间不允许写 state，推迟到微任务。
    Future.microtask(refresh);
    return const SnapshotState();
  }

  void setPaused(bool paused) {
    if (paused) {
      _paused = true;
      _timer?.cancel();
      _timer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      _cancelRefresh();
    } else {
      _paused = false;
      if (_timer != null) return;
      _timer = Timer.periodic(pollInterval, (_) => refresh());
      Future.microtask(refresh);
    }
  }

  Future<void> refresh() async {
    final api = ref.read(apiProvider(bridgeId));
    if (api == null || _inFlight || _paused) return;
    final generation = _refreshGeneration;
    final cancelToken = CancelToken();
    _cancelToken = cancelToken;
    _inFlight = true;
    try {
      final snap = await api.getSnapshot(
          session: ref.read(sessionFilterProvider(bridgeId)),
          cancelToken: cancelToken);
      // await 后 provider 可能已随 bridgesProvider 重建被销毁。
      if (!ref.mounted || generation != _refreshGeneration) return;
      _retryTimer?.cancel();
      _retryTimer = null;
      state = SnapshotState(data: snap, lastOk: DateTime.now());
    } catch (e) {
      if (!ref.mounted || generation != _refreshGeneration) return;
      state = SnapshotState(data: state.data, error: e, lastOk: state.lastOk);
      if (!_paused) {
        _retryTimer?.cancel();
        _retryTimer = Timer(retryInterval, refresh);
      }
    } finally {
      if (generation == _refreshGeneration) {
        if (identical(_cancelToken, cancelToken)) _cancelToken = null;
        _inFlight = false;
      }
    }
  }

  void _cancelRefresh() {
    _refreshGeneration++;
    _cancelToken?.cancel();
    _cancelToken = null;
    _inFlight = false;
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
