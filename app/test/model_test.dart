import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/model/models.dart';

void main() {
  group('Snapshot.fromJson', () {
    test('解析完整快照', () {
      final snap = Snapshot.fromJson({
        'bridge': 'connected',
        'device': {'enforced': true, 'device': 'my-phone', 'authorized': true},
        'agents': [
          {
            'paneId': 'w1:p1',
            'workspaceId': 'w1',
            'workspaceLabel': 'api',
            'workspaceNumber': 1,
            'tabId': 'w1:t1',
            'agent': 'claude',
            'status': 'blocked',
            'cwd': '/repo',
            'focused': true,
            'kind': 'agent',
            'paneLabel': 'reviewer',
            'lastActiveAt': 1780000000000,
            'hasSession': true,
            'agentSession': {'value': '/should/be/stripped'}, // 不在 wire 模型里
          },
        ],
        'shellPanes': [],
        'workspaces': [
          {
            'workspaceId': 'w1',
            'number': 1,
            'label': 'api',
            'focused': true,
            'activeTabId': 'w1:t1',
            'tabCount': 1,
            'paneCount': 2,
          },
        ],
        'tabs': [
          {
            'tabId': 'w1:t1',
            'workspaceId': 'w1',
            'number': 1,
            'label': 'agents',
            'focused': true,
            'paneCount': 2,
          },
        ],
        'sessions': [
          {
            'name': 'default',
            'isPrimary': true,
            'reachable': true,
            'agents': 1,
            'working': 0,
            'blocked': 1,
          },
        ],
        'ts': 1780000000123,
      });

      expect(snap.bridgeConnected, isTrue);
      expect(snap.device!.authorized, isTrue);
      expect(snap.agents, hasLength(1));
      final pane = snap.agents.single;
      expect(pane.paneId, 'w1:p1');
      expect(pane.status, AgentStatus.blocked);
      expect(pane.displayName, 'reviewer'); // paneLabel 优先
      expect(pane.hasSession, isTrue);
      expect(snap.workspaces.single.label, 'api');
      expect(snap.sessions.single.isPrimary, isTrue);
      expect(snap.readOnly, isFalse);
    });

    test('宽容解析：缺字段、未知字段、类型不符都不炸', () {
      final snap = Snapshot.fromJson({
        'bridge': 'disconnected',
        'agents': [
          {'paneId': 'w1:p9', 'status': 'some-future-status', 'focused': 'yes'},
        ],
        'shellPanes': 'oops',
        'unknownFutureField': {'nested': true},
      });

      expect(snap.bridgeConnected, isFalse);
      expect(snap.agents, hasLength(1));
      expect(snap.agents.single.status, AgentStatus.unknown);
      expect(snap.agents.single.focused, isFalse); // 类型不符回退默认
      expect(snap.shellPanes, isEmpty);
      expect(snap.device, isNull);
      expect(snap.readOnly, isFalse);
    });

    test('device gate 未授权 → readOnly', () {
      final snap = Snapshot.fromJson({
        'bridge': 'connected',
        'device': {'enforced': true, 'device': null, 'authorized': false},
      });
      expect(snap.readOnly, isTrue);
    });
  });

  group('PaneRead.fromJson', () {
    test('基本字段 + notModified 默认 false', () {
      final read = PaneRead.fromJson({
        'paneId': 'w1:p1',
        'text': 'hello\u001b[31mworld',
        'truncated': false,
        'revision': 42,
      });
      expect(read.revision, 42);
      expect(read.notModified, isFalse);
      expect(read.copyAsNotModified().notModified, isTrue);
      expect(read.copyAsNotModified().text, read.text);
    });
  });

  group('statusRank', () {
    test('blocked 最紧急，done 最后', () {
      expect(statusRank(AgentStatus.blocked), lessThan(statusRank(AgentStatus.working)));
      expect(statusRank(AgentStatus.working), lessThan(statusRank(AgentStatus.unknown)));
      expect(statusRank(AgentStatus.unknown), lessThan(statusRank(AgentStatus.idle)));
      expect(statusRank(AgentStatus.idle), lessThan(statusRank(AgentStatus.done)));
    });
  });
}
