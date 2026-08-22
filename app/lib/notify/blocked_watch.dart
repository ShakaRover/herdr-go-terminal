/// blocked 监视的纯逻辑部分（可测试）：从快照算出「新 blocked」集合并
/// 维护已见集合。前台心跳抑制也在这里，后台任务只做编排。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../model/models.dart';

/// shared_preferences 键：已见 blocked 集合 {paneId: lastActiveAt}。
const blockedSeenKey = 'blocked_seen_v1';

/// shared_preferences 键：前台心跳（epoch ms）。app 前台轮询成功时更新；
/// 后台任务看到心跳很新就跳过通知（用户正盯着屏幕，不用打扰）。
const foregroundHeartbeatKey = 'fg_heartbeat_v1';

/// 心跳在这个窗口内视为「用户正在看」。
const foregroundFreshWindow = Duration(seconds: 60);

/// 前台轮询写心跳的最小间隔（避免每次轮询都写盘）。
const heartbeatWriteInterval = Duration(seconds: 15);

Map<String, int> readSeen(SharedPreferences prefs) {
  final raw = prefs.getString(blockedSeenKey);
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    }
  } catch (_) {
    // 损坏按空集合处理。
  }
  return {};
}

Future<void> writeSeen(SharedPreferences prefs, Map<String, int> seen) =>
    prefs.setString(blockedSeenKey, jsonEncode(seen));

/// 当前处于 blocked 且「没见过」或「见过之后又有新活动」的 pane。
List<PaneInfo> newlyBlocked(Snapshot snap, Map<String, int> seen) {
  return snap.agents.where((p) {
    if (p.status != AgentStatus.blocked) return false;
    final seenAt = seen[p.paneId];
    if (seenAt == null) return true;
    // lastActiveAt 缺失时无法判断新旧，保守不重复通知。
    final active = p.lastActiveAt;
    return active != null && active > seenAt;
  }).toList();
}

/// 更新已见集合：仍 blocked 的保留/刷新时间戳，不再 blocked 的移除，
/// 新 blocked 的加入。
Map<String, int> updateSeen(
  Map<String, int> seen,
  Snapshot snap, {
  required int nowMs,
}) {
  final blockedIds = snap.agents
      .where((p) => p.status == AgentStatus.blocked)
      .map((p) => p.paneId)
      .toSet();
  final next = <String, int>{
    for (final e in seen.entries)
      if (blockedIds.contains(e.key)) e.key: e.value,
  };
  for (final p in newlyBlocked(snap, seen)) {
    next[p.paneId] = p.lastActiveAt ?? nowMs;
  }
  return next;
}

/// 后台任务此刻该不该发通知（心跳新鲜 = 用户正在前台看，跳过）。
bool shouldSuppress(SharedPreferences prefs, {required int nowMs}) {
  final hb = prefs.getInt(foregroundHeartbeatKey);
  if (hb == null) return false;
  return nowMs - hb < foregroundFreshWindow.inMilliseconds;
}
