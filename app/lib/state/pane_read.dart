/// 单 pane 输出的轮询：agent 详情页的数据源（per bridge）。
///
/// ETag 缓存在 api 层，未变化的轮询返回缓存 body，代价一次条件请求。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../model/models.dart';
import 'bridges.dart';
import 'snapshot.dart';

/// pane 输出轮询的 family key。
typedef PaneReadKey = ({String bridgeId, String paneId});

class PaneReadState {
  const PaneReadState({this.data, this.error});

  final PaneRead? data;
  final Object? error;
}

class PaneReadNotifier extends Notifier<PaneReadState> {
  PaneReadNotifier(this.paneKey);

  static const _interval = Duration(milliseconds: 2500);

  final PaneReadKey paneKey;
  Timer? _timer;
  bool _inFlight = false;

  @override
  PaneReadState build() {
    ref.watch(sessionFilterProvider(paneKey.bridgeId));
    ref.onDispose(() => _timer?.cancel());
    _timer = Timer.periodic(_interval, (_) => refresh());
    Future.microtask(refresh);
    return const PaneReadState();
  }

  Future<void> refresh() async {
    final api = ref.read(apiProvider(paneKey.bridgeId));
    if (api == null || _inFlight) return;
    _inFlight = true;
    try {
      final read = await api.readPane(paneKey.paneId,
          lines: 200,
          session: ref.read(sessionFilterProvider(paneKey.bridgeId)));
      state = PaneReadState(data: read);
    } catch (e) {
      state = PaneReadState(data: state.data, error: e);
    } finally {
      _inFlight = false;
    }
  }
}

final paneReadProvider =
    NotifierProvider.family<PaneReadNotifier, PaneReadState, PaneReadKey>(
  PaneReadNotifier.new,
  // 离开详情页即销毁：否则每个访问过的 pane 留下一条永久轮询回路，
  // 且其 x-bridge-seen 会持续刷新 bridge 端的 lastSeenAt，破坏
  // collie PWA 的 unseen 判定（最终审查 M1）。
  isAutoDispose: true,
);
