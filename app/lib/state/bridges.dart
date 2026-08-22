/// 多 bridge 连接的聚合层：bridgesProvider / apiProvider family /
/// focusedBridgeProvider / aggregateBridgePanes。
///
/// 全是 EasyTier 连接（无直连）：每条 enabled profile 一个连接，api 指向
/// 该 profile EasyTier 实例的本地转发口 `127.0.0.1:<localPort>`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/bridge_api.dart';
import '../model/models.dart';
import '../model/remote_profile.dart';
import 'easytier_runtime.dart';
import 'settings.dart';
import 'snapshot.dart';

/// 连接状态。
enum ConnStatus { connecting, ready, failed }

/// 一个 bridge 连接的运行态视图（bridgesProvider 的元素）。
class BridgeConn {
  const BridgeConn({
    required this.id, // profileId
    required this.label,
    this.api, // ready 时非空
    required this.status,
    this.error, // failed 时的错误（EasyTierFailed.message）
  });

  final String id;
  final String label;
  final BridgeApi? api;
  final ConnStatus status;
  final Object? error;
}

/// 每个 bridge 的 API 客户端（family 参数 = bridgeId）。
///
/// 全是 EasyTier：easytierRuntimeProvider(profileId) 为 Ready →
/// BridgeApi(`http://127.0.0.1:<localPort>`)；其余 → null。
/// 未知 bridgeId（不在 enabled 集合）→ null。
final apiProvider = Provider.family<BridgeApi?, String>((ref, bridgeId) {
  final profiles = ref.watch(enabledProfilesProvider);
  if (!profiles.any((p) => p.id == bridgeId)) return null;
  final runtime = ref.watch(easytierRuntimeProvider(bridgeId));
  return switch (runtime) {
    EasyTierReady(:final localPort) =>
      BridgeApi(baseUrl: 'http://127.0.0.1:$localPort'),
    _ => null,
  };
});

/// 当前焦点 bridge（dashboard tab 选中项；'' = 全部 tab）。
class FocusedBridgeNotifier extends Notifier<String> {
  @override
  String build() => '';

  void select(String bridgeId) => state = bridgeId;
}

final focusedBridgeProvider =
    NotifierProvider<FocusedBridgeNotifier, String>(FocusedBridgeNotifier.new);

/// 全部 enabled 连接的运行态列表（顺序 = profile 列表序）。
///
/// 副作用：驱动每条 enabled profile 的 EasyTier 实例 connect/disconnect
/// （沿用「状态驱动 connect 一次」的语义——仅在 Disconnected 时发起
/// connect，失败不自动重试，断线靠 tab 重进/重选触发）。
final bridgesProvider = Provider<List<BridgeConn>>((ref) {
  final profiles = ref.watch(enabledProfilesProvider);
  return [
    for (final p in profiles) _driveAndDerive(ref, p),
  ];
});

/// watch 本 profile 的 runtime、驱动 connect/disconnect，并把 runtime
/// 派生成 BridgeConn。
BridgeConn _driveAndDerive(Ref ref, RemoteProfile profile) {
  final runtime = ref.watch(easytierRuntimeProvider(profile.id));
  final notifier = ref.read(easytierRuntimeProvider(profile.id).notifier);
  switch (runtime) {
    case EasyTierDisconnected():
      // connect 是 async，不在 build 里 await；连接进度经 state 变化回到本
      // provider 重建。
      Future.microtask(() => notifier.connect(profile));
      return BridgeConn(
          id: profile.id, label: profile.label, status: ConnStatus.connecting);
    case EasyTierConnecting():
      return BridgeConn(
          id: profile.id, label: profile.label, status: ConnStatus.connecting);
    case EasyTierReady(:final localPort):
      return BridgeConn(
        id: profile.id,
        label: profile.label,
        status: ConnStatus.ready,
        api: BridgeApi(baseUrl: 'http://127.0.0.1:$localPort'),
      );
    case EasyTierFailed(:final message):
      return BridgeConn(
          id: profile.id,
          label: profile.label,
          status: ConnStatus.failed,
          error: message);
  }
}

/// 「全部」tab 聚合：跨 bridge 的 pane 包装（供排序与卡片宿主机标签）。
class BridgePane {
  const BridgePane({
    required this.bridgeId,
    required this.bridgeLabel,
    required this.pane,
  });

  final String bridgeId;
  final String bridgeLabel;
  final PaneInfo pane;
}

/// 聚合排序：statusRank 升序 → 宿主机 label 字典序 → lastActiveAt 新的在前。
/// 仅取 status == ready 的 bridge 的快照数据。
List<BridgePane> aggregateBridgePanes(
    List<BridgeConn> conns, Map<String, SnapshotState> snapshots) {
  final out = <BridgePane>[];
  for (final conn in conns) {
    if (conn.status != ConnStatus.ready) continue;
    final snap = snapshots[conn.id]?.data;
    if (snap == null) continue;
    for (final pane in snap.agents) {
      out.add(BridgePane(
          bridgeId: conn.id, bridgeLabel: conn.label, pane: pane));
    }
  }
  out.sort((a, b) {
    final r = statusRank(a.pane.status).compareTo(statusRank(b.pane.status));
    if (r != 0) return r;
    final byLabel = a.bridgeLabel.compareTo(b.bridgeLabel);
    if (byLabel != 0) return byLabel;
    return (b.pane.lastActiveAt ?? 0).compareTo(a.pane.lastActiveAt ?? 0);
  });
  return out;
}
