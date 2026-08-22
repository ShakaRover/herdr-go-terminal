import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/model/models.dart';
import 'package:herdr_web/state/pinned.dart';
import 'package:shared_preferences/shared_preferences.dart';

PaneInfo pane(String id, AgentStatus status, {int? lastActiveAt}) => PaneInfo(
      paneId: id,
      workspaceId: 'w1',
      workspaceLabel: 'ws',
      workspaceNumber: 1,
      tabId: 'w1:t1',
      agent: 'claude',
      status: status,
      cwd: '/repo',
      focused: false,
      lastActiveAt: lastActiveAt,
    );

void main() {
  group('pinKey / isPinned', () {
    test('primary session 为空串前缀；具名 session 带前缀', () {
      expect(pinKey(null, 'w9:p18'), ':w9:p18');
      expect(pinKey('main2', 'w9:p18'), 'main2:w9:p18');
      expect(isPinned({':w9:p18'}, null, 'w9:p18'), isTrue);
      // 同一 paneId 在别的 session 的置顶不匹配当前 session。
      expect(isPinned({'main2:w9:p18'}, null, 'w9:p18'), isFalse);
    });
  });

  group('togglePinned', () {
    test('不存在则加入，存在则移除；输入集合不被修改', () {
      const start = {':a'};
      final added = togglePinned(start, ':b');
      expect(added, {':a', ':b'});
      final removed = togglePinned(added, ':a');
      expect(removed, {':b'});
      expect(start, {':a'});
    });
  });

  group('置顶集合读写', () {
    test('round-trip；损坏数据回退空集合', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(readPinned(prefs), isEmpty);

      await writePinned(prefs, {':w9:p18', 'main2:w1:p1'});
      expect(readPinned(prefs), {':w9:p18', 'main2:w1:p1'});

      await prefs.setString(pinnedPanesPrefsKey, 'not-json{');
      expect(readPinned(prefs), isEmpty);

      await prefs.setString(pinnedPanesPrefsKey, '{"a":1}');
      expect(readPinned(prefs), isEmpty);
    });
  });

  group('splitPinned', () {
    test('置顶段保持 triage 顺序，其余段不含置顶项', () {
      final sorted = [
        pane('a', AgentStatus.blocked, lastActiveAt: 100),
        pane('b', AgentStatus.working, lastActiveAt: 200),
        pane('c', AgentStatus.idle, lastActiveAt: 300),
      ];
      final (pinned, rest) = splitPinned(sorted, {':c', ':a'}, null);
      expect(pinned.map((p) => p.paneId).toList(), ['a', 'c']);
      expect(rest.map((p) => p.paneId).toList(), ['b']);
    });

    test('别的 session 的置顶不参与当前 session', () {
      final sorted = [pane('a', AgentStatus.blocked)];
      final (pinned, rest) = splitPinned(sorted, {'main2:a'}, null);
      expect(pinned, isEmpty);
      expect(rest, hasLength(1));
    });

    test('置顶集合为空时两段原样', () {
      final sorted = [pane('a', AgentStatus.blocked)];
      final (pinned, rest) = splitPinned(sorted, const {}, null);
      expect(pinned, isEmpty);
      expect(rest, hasLength(1));
    });
  });
}
