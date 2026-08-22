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

/// 模拟 dashboard（Task 10）的「带宿主机标签的 pane 包装类型」。
class HostPane {
  const HostPane(this.bridgeId, this.pane);

  final String bridgeId;
  final PaneInfo pane;
}

void main() {
  group('pinKey / isPinned', () {
    test('三段格式：bridgeId:session:paneId，primary session 为空串中段', () {
      expect(pinKey('b1', null, 'w9:p18'), 'b1::w9:p18');
      expect(pinKey('b1', 'main2', 'w9:p18'), 'b1:main2:w9:p18');
      expect(isPinned({'b1::w9:p18'}, 'b1', null, 'w9:p18'), isTrue);
      expect(isPinned({'b1:main2:w9:p18'}, 'b1', 'main2', 'w9:p18'), isTrue);
    });

    test('跨 bridge 不匹配：同 paneId 在别的 bridge 的置顶不算', () {
      expect(isPinned({'b2::w9:p18'}, 'b1', null, 'w9:p18'), isFalse);
      expect(
          isPinned({'b2:main2:w9:p18'}, 'b1', 'main2', 'w9:p18'), isFalse);
      // 同 bridge 下别的 session 的置顶也不匹配当前 session。
      expect(isPinned({'b1:main2:w9:p18'}, 'b1', null, 'w9:p18'), isFalse);
    });
  });

  group('togglePinned', () {
    test('不存在则加入，存在则移除；输入集合不被修改', () {
      const start = {'b1::a'};
      final added = togglePinned(start, 'b1::b');
      expect(added, {'b1::a', 'b1::b'});
      final removed = togglePinned(added, 'b1::a');
      expect(removed, {'b1::b'});
      expect(start, {'b1::a'});
    });
  });

  group('置顶集合读写', () {
    test('round-trip；损坏数据回退空集合', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(readPinned(prefs), isEmpty);

      await writePinned(prefs, {'b1::w9:p18', 'b1:main2:w1:p1'});
      expect(readPinned(prefs), {'b1::w9:p18', 'b1:main2:w1:p1'});

      await prefs.setString(pinnedPanesPrefsKey, 'not-json{');
      expect(readPinned(prefs), isEmpty);

      await prefs.setString(pinnedPanesPrefsKey, '{"a":1}');
      expect(readPinned(prefs), isEmpty);
    });

    test('发现 v1 键时返回空集合，且 v1 键被 remove', () async {
      SharedPreferences.setMockInitialValues({
        'pinned_panes_v1': '["w9:p18","main2:w1:p1"]',
      });
      final prefs = await SharedPreferences.getInstance();

      expect(readPinned(prefs), isEmpty);
      expect(prefs.getString('pinned_panes_v1'), isNull);
    });

    test('v1 与 v2 并存时读 v2、丢弃 v1', () async {
      SharedPreferences.setMockInitialValues({
        'pinned_panes_v1': '["w9:p18"]',
        pinnedPanesPrefsKey: '["b1::w2:p3"]',
      });
      final prefs = await SharedPreferences.getInstance();

      expect(readPinned(prefs), {'b1::w2:p3'});
      expect(prefs.getString('pinned_panes_v1'), isNull);
    });
  });

  group('splitPinned', () {
    test('置顶段保持 triage 顺序，其余段不含置顶项', () {
      final sorted = [
        pane('a', AgentStatus.blocked, lastActiveAt: 100),
        pane('b', AgentStatus.working, lastActiveAt: 200),
        pane('c', AgentStatus.idle, lastActiveAt: 300),
      ];
      final (pinned, rest) =
          splitPinned(sorted, {'b1::c', 'b1::a'}, 'b1', null, (p) => p.paneId);
      expect(pinned.map((p) => p.paneId).toList(), ['a', 'c']);
      expect(rest.map((p) => p.paneId).toList(), ['b']);
    });

    test('泛型版本：带宿主机标签的包装类型复用同一切分逻辑', () {
      final sorted = [
        HostPane('b1', pane('a', AgentStatus.blocked)),
        HostPane('b1', pane('b', AgentStatus.working)),
      ];
      final (pinned, rest) = splitPinned(
          sorted, {'b1::b'}, 'b1', null, (hp) => hp.pane.paneId);
      expect(pinned.map((hp) => hp.pane.paneId).toList(), ['b']);
      expect(rest.map((hp) => hp.pane.paneId).toList(), ['a']);
    });

    test('跨 bridge 的置顶不参与当前 bridge 的切分', () {
      final sorted = [pane('a', AgentStatus.blocked)];
      final (pinned, rest) =
          splitPinned(sorted, {'b2::a'}, 'b1', null, (p) => p.paneId);
      expect(pinned, isEmpty);
      expect(rest, hasLength(1));
    });

    test('同 bridge 下别的 session 的置顶不参与', () {
      final sorted = [pane('a', AgentStatus.blocked)];
      final (pinned, rest) =
          splitPinned(sorted, {'b1:main2:a'}, 'b1', null, (p) => p.paneId);
      expect(pinned, isEmpty);
      expect(rest, hasLength(1));
    });

    test('置顶集合为空时两段原样', () {
      final sorted = [pane('a', AgentStatus.blocked)];
      final (pinned, rest) =
          splitPinned(sorted, const {}, 'b1', null, (p) => p.paneId);
      expect(pinned, isEmpty);
      expect(rest, hasLength(1));
    });
  });
}
