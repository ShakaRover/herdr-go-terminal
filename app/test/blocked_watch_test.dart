import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/model/models.dart';
import 'package:herdr_web/notify/blocked_watch.dart';
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

Snapshot snapWith(List<PaneInfo> agents) => Snapshot(
      bridgeConnected: true,
      agents: agents,
      shellPanes: const [],
      workspaces: const [],
      tabs: const [],
      sessions: const [],
      ts: 0,
    );

void main() {
  group('newlyBlocked', () {
    test('没见过且 blocked → 命中；已见且无新活动 → 不命中', () {
      final snap = snapWith([
        pane('a', AgentStatus.blocked, lastActiveAt: 100),
        pane('b', AgentStatus.blocked, lastActiveAt: 200),
        pane('c', AgentStatus.working),
      ]);
      final fresh = newlyBlocked(snap, {'b': 200});
      expect(fresh.map((p) => p.paneId).toList(), ['a']);
    });

    test('已见之后又变 blocked（lastActiveAt 更新）→ 再次命中', () {
      final snap = snapWith([pane('a', AgentStatus.blocked, lastActiveAt: 300)]);
      expect(newlyBlocked(snap, {'a': 100}), hasLength(1));
      expect(newlyBlocked(snap, {'a': 300}), isEmpty);
    });

    test('lastActiveAt 缺失的已见 pane 不重复通知', () {
      final snap = snapWith([pane('a', AgentStatus.blocked)]);
      expect(newlyBlocked(snap, {'a': 1}), isEmpty);
      expect(newlyBlocked(snap, {}), hasLength(1));
    });
  });

  group('updateSeen', () {
    test('不再 blocked 的移除，新 blocked 的加入，仍 blocked 的保留', () {
      final seen = {'gone': 100, 'stay': 100};
      final snap = snapWith([
        pane('stay', AgentStatus.blocked, lastActiveAt: 100),
        pane('new', AgentStatus.blocked, lastActiveAt: 500),
        pane('gone', AgentStatus.working),
      ]);
      final next = updateSeen(seen, snap, nowMs: 1000);
      expect(next.containsKey('gone'), isFalse);
      expect(next['stay'], 100);
      expect(next['new'], 500);
    });

    test('新 blocked 缺 lastActiveAt 时用 nowMs', () {
      final snap = snapWith([pane('a', AgentStatus.blocked)]);
      final next = updateSeen({}, snap, nowMs: 777);
      expect(next['a'], 777);
    });
  });

  group('前台心跳抑制', () {
    test('心跳新鲜 → 抑制；过旧/缺失 → 不抑制', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(shouldSuppress(prefs, nowMs: now), isFalse);

      await prefs.setInt(foregroundHeartbeatKey, now - 10 * 1000);
      expect(shouldSuppress(prefs, nowMs: now), isTrue);

      await prefs.setInt(foregroundHeartbeatKey, now - 120 * 1000);
      expect(shouldSuppress(prefs, nowMs: now), isFalse);
    });
  });

  group('已见集合读写', () {
    test('round-trip；损坏数据回退空集合', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(readSeen(prefs), isEmpty);

      await writeSeen(prefs, {'w1:p1': 123});
      expect(readSeen(prefs), {'w1:p1': 123});

      await prefs.setString(blockedSeenKey, 'not-json{');
      expect(readSeen(prefs), isEmpty);
    });
  });
}
