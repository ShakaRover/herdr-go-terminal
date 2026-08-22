/// agent 置顶：本地持久化的置顶集合 + provider。
///
/// 纯本地 UI 状态（对齐 blocked_watch.dart 的纯函数 + prefs 模式）：
/// 不写 bridge、不跨设备同步、只读模式下可用。key 带 session 前缀——
/// 多 herdr session 的 paneId 可能撞号（各自从 w0 编起）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/models.dart';
import 'settings.dart';

/// shared_preferences 键：置顶集合（JSON 字符串数组，元素 session:paneId）。
const pinnedPanesPrefsKey = 'pinned_panes_v1';

/// pin key：`'$session:$paneId'`；primary session（null）为空串前缀。
String pinKey(String? session, String paneId) => '${session ?? ''}:$paneId';

bool isPinned(Set<String> pinned, String? session, String paneId) =>
    pinned.contains(pinKey(session, paneId));

Set<String> readPinned(SharedPreferences prefs) {
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
(List<PaneInfo>, List<PaneInfo>) splitPinned(
    List<PaneInfo> sorted, Set<String> pinned, String? session) {
  final yes = <PaneInfo>[];
  final no = <PaneInfo>[];
  for (final p in sorted) {
    (isPinned(pinned, session, p.paneId) ? yes : no).add(p);
  }
  return (yes, no);
}

class PinnedPanesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => readPinned(ref.watch(sharedPrefsProvider));

  Future<void> toggle(String? session, String paneId) async {
    state = togglePinned(state, pinKey(session, paneId));
    await writePinned(ref.read(sharedPrefsProvider), state);
  }
}

final pinnedPanesProvider =
    NotifierProvider<PinnedPanesNotifier, Set<String>>(PinnedPanesNotifier.new);
