/// agent 置顶：本地持久化的置顶集合 + provider。
///
/// 纯本地 UI 状态（对齐 blocked_watch.dart 的纯函数 + prefs 模式）：
/// 不写 bridge、不跨设备同步、只读模式下可用。key 带 bridgeId + session
/// 前缀——多宿主机之间 paneId 会撞号，同一宿主机上多 herdr session 的
/// paneId 也可能撞号（各自从 w0 编起）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings.dart';

/// shared_preferences 键（v2：key 加 bridgeId 前缀；v1 残留直接删除丢弃）。
const pinnedPanesPrefsKey = 'pinned_panes_v2';

/// 仅清除用：v1 键（无 bridgeId 维度）。数据量小，按 spec 直接丢弃不迁移。
const _legacyPinnedPanesPrefsKey = 'pinned_panes_v1';

/// pin key：`'$bridgeId:$session:$paneId'`；primary session 为空串中段。
String pinKey(String bridgeId, String? session, String paneId) =>
    '$bridgeId:${session ?? ''}:$paneId';

bool isPinned(Set<String> pinned, String bridgeId, String? session,
        String paneId) =>
    pinned.contains(pinKey(bridgeId, session, paneId));

Set<String> readPinned(SharedPreferences prefs) {
  // 顺带删除 v1 残留（一次性丢弃，不迁移）。
  prefs.remove(_legacyPinnedPanesPrefsKey);
  final raw = prefs.getString(pinnedPanesPrefsKey);
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.whereType<String>().toSet();
    }
  } catch (_) {
    // 损坏按空集合处理。
  }
  return {};
}

Future<void> writePinned(SharedPreferences prefs, Set<String> pinned) =>
    prefs.setString(pinnedPanesPrefsKey, jsonEncode(pinned.toList()));

/// 不可变更新：key 存在则移除，否则加入。
Set<String> togglePinned(Set<String> pinned, String key) {
  final next = {...pinned};
  if (next.contains(key)) {
    next.remove(key);
  } else {
    next.add(key);
  }
  return next;
}

/// 把 triageSorted 的输出切成（置顶, 未置顶）两段，各自保持原顺序。
/// 泛型化 + [paneIdOf] 回调：dashboard 的宿主机包装类型也复用本函数。
(List<T>, List<T>) splitPinned<T>(List<T> sorted, Set<String> pinned,
    String bridgeId, String? session, String Function(T) paneIdOf) {
  final yes = <T>[];
  final no = <T>[];
  for (final p in sorted) {
    (isPinned(pinned, bridgeId, session, paneIdOf(p)) ? yes : no).add(p);
  }
  return (yes, no);
}

class PinnedPanesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => readPinned(ref.watch(sharedPrefsProvider));

  Future<void> toggle(String bridgeId, String? session, String paneId) async {
    state = togglePinned(state, pinKey(bridgeId, session, paneId));
    await writePinned(ref.read(sharedPrefsProvider), state);
  }
}

final pinnedPanesProvider =
    NotifierProvider<PinnedPanesNotifier, Set<String>>(PinnedPanesNotifier.new);
