import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/notify/blocked_watch.dart';
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
  group('newlyBlocked（seen key 带 bridgeId 维度）', () {
    test('没见过且 blocked → 命中；已见且无新活动 → 不命中', () {
      final snap = snapWith([
        pane('a', AgentStatus.blocked, lastActiveAt: 100),
        pane('b', AgentStatus.blocked, lastActiveAt: 200),
        pane('c', AgentStatus.working),
      ]);
      final fresh = newlyBlocked('b1', snap, {'b1:b': 200});
      expect(fresh.map((p) => p.paneId).toList(), ['a']);
    });

    test('同 paneId 不同 bridgeId 各自独立', () {
      final snap = snapWith([pane('w0', AgentStatus.blocked, lastActiveAt: 100)]);
      // b1 已见过，b2 没见过：同一份快照在两个 bridge 维度下结论不同。
      expect(newlyBlocked('b1', snap, {'b1:w0': 100}), isEmpty);
      expect(newlyBlocked('b2', snap, {'b1:w0': 100}), hasLength(1));
    });

    test('已见之后又变 blocked（lastActiveAt 更新）→ 再次命中', () {
      final snap = snapWith([pane('a', AgentStatus.blocked, lastActiveAt: 300)]);
      expect(newlyBlocked('b1', snap, {'b1:a': 100}), hasLength(1));
      expect(newlyBlocked('b1', snap, {'b1:a': 300}), isEmpty);
    });

    test('lastActiveAt 缺失的已见 pane 不重复通知', () {
      final snap = snapWith([pane('a', AgentStatus.blocked)]);
      expect(newlyBlocked('b1', snap, {'b1:a': 1}), isEmpty);
      expect(newlyBlocked('b1', snap, {}), hasLength(1));
    });
  });

  group('updateSeen', () {
    test('不再 blocked 的移除，新 blocked 的加入，仍 blocked 的保留', () {
      final seen = {'b1:gone': 100, 'b1:stay': 100};
      final snap = snapWith([
        pane('stay', AgentStatus.blocked, lastActiveAt: 100),
        pane('new', AgentStatus.blocked, lastActiveAt: 500),
        pane('gone', AgentStatus.working),
      ]);
      final next = updateSeen('b1', seen, snap, nowMs: 1000);
      expect(next.containsKey('b1:gone'), isFalse);
      expect(next['b1:stay'], 100);
      expect(next['b1:new'], 500);
    });

    test('只清理本 bridge 的 key，其他 bridge 的原样保留', () {
      final seen = {'b1:gone': 100, 'b2:stay': 100};
      final snap = snapWith([pane('new', AgentStatus.blocked, lastActiveAt: 500)]);
      final next = updateSeen('b1', seen, snap, nowMs: 1000);
      expect(next.containsKey('b1:gone'), isFalse);
      expect(next['b2:stay'], 100);
      expect(next['b1:new'], 500);
    });

    test('新 blocked 缺 lastActiveAt 时用 nowMs', () {
      final snap = snapWith([pane('a', AgentStatus.blocked)]);
      final next = updateSeen('b1', {}, snap, nowMs: 777);
      expect(next['b1:a'], 777);
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

      await writeSeen(prefs, {'b1:w1:p1': 123});
      expect(readSeen(prefs), {'b1:w1:p1': 123});

      await prefs.setString(blockedSeenKey, 'not-json{');
      expect(readSeen(prefs), isEmpty);
    });

    test('v1（blocked_seen_v1）键读取时一次性 remove，数据丢弃', () async {
      SharedPreferences.setMockInitialValues({'blocked_seen_v1': '{"a":1}'});
      final prefs = await SharedPreferences.getInstance();
      expect(readSeen(prefs), isEmpty);
      expect(prefs.getString('blocked_seen_v1'), isNull);
    });
  });
}
