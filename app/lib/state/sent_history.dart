/// 本地“已发送回复”历史：按 bridge/session/pane 隔离，供输入框回填。
///
/// 这是对 bridge journal 的补充：
/// - agent 有 journal 时，历史选择器会合并 journal 的 user 消息；
/// - shell 或没有 journal 的 agent，仍能回填本机发过的命令/回复。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings.dart';

const sentHistoryPrefsKey = 'sent_history_v1';
const sentHistoryLimit = 50;

/// family key：同一 paneId 在不同 bridge/session 下可能重复。
typedef SentHistoryKey = ({String bridgeId, String? session, String paneId});

String sentHistoryStorageKey(SentHistoryKey key) =>
    '${key.bridgeId}:${key.session ?? ''}:${key.paneId}';

Map<String, List<String>> _readAll(SharedPreferences prefs) {
  final raw = prefs.getString(sentHistoryPrefsKey);
  if (raw == null || raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    final out = <String, List<String>>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String || entry.value is! List) continue;
      out[entry.key as String] = (entry.value as List)
          .whereType<String>()
          .toList(growable: false);
    }
    return out;
  } catch (_) {
    return {};
  }
}

List<String> readSentHistory(SharedPreferences prefs, SentHistoryKey key) =>
    _readAll(prefs)[sentHistoryStorageKey(key)] ?? const [];

/// 新条目插到最前；相同文本先去重；最多保留 [sentHistoryLimit] 条。
List<String> updatedSentHistory(List<String> current, String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return current;
  return [
    trimmed,
    ...current.where((item) => item != trimmed),
  ].take(sentHistoryLimit).toList();
}

Future<void> writeSentHistory(
  SharedPreferences prefs,
  SentHistoryKey key,
  List<String> history,
) async {
  final all = _readAll(prefs);
  all[sentHistoryStorageKey(key)] = history;
  await prefs.setString(sentHistoryPrefsKey, jsonEncode(all));
}

class SentHistoryNotifier extends Notifier<List<String>> {
  SentHistoryNotifier(this.key);

  final SentHistoryKey key;

  @override
  List<String> build() => readSentHistory(ref.watch(sharedPrefsProvider), key);

  Future<void> add(String text) async {
    final next = updatedSentHistory(state, text);
    if (identical(next, state)) return;
    state = next;
    await writeSentHistory(ref.read(sharedPrefsProvider), key, next);
  }
}

final sentHistoryProvider =
    NotifierProvider.family<SentHistoryNotifier, List<String>, SentHistoryKey>(
      SentHistoryNotifier.new,
    );
