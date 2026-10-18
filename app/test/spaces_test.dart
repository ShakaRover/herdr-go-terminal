/// spaces 拓扑派生测试：workspace → tab → pane 的归并、排序、状态汇总，
/// 以及 bridge 快照瞬时不一致时的占位处理。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/l10n/generated/app_localizations.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/model/spaces.dart';
import 'package:herdrgo/ui/spaces/space_screen.dart';

WorkspaceInfo _workspace(
  String id,
  int number, {
  String label = '',
  bool focused = false,
}) => WorkspaceInfo(
  workspaceId: id,
  number: number,
  label: label,
  focused: focused,
  activeTabId: '',
  tabCount: 0,
  paneCount: 0,
);

TabInfo _tab(
  String id,
  String workspaceId,
  int number, {
  String label = '',
  bool focused = false,
}) => TabInfo(
  tabId: id,
  workspaceId: workspaceId,
  number: number,
  label: label,
  focused: focused,
  paneCount: 0,
);

PaneInfo _pane(
  String id, {
  required String workspaceId,
  required String tabId,
  String workspaceLabel = '',
  int workspaceNumber = 0,
  String agent = 'claude',
  AgentStatus status = AgentStatus.idle,
  String cwd = '/repo',
  bool focused = false,
  String kind = 'agent',
  String? paneLabel,
  String? tabLabel,
}) => PaneInfo(
  paneId: id,
  workspaceId: workspaceId,
  workspaceLabel: workspaceLabel,
  workspaceNumber: workspaceNumber,
  tabId: tabId,
  agent: agent,
  status: status,
  cwd: cwd,
  focused: focused,
  kind: kind,
  paneLabel: paneLabel,
  tabLabel: tabLabel,
);

Snapshot _snapshot({
  List<WorkspaceInfo> workspaces = const [],
  List<TabInfo> tabs = const [],
  List<PaneInfo> agents = const [],
  List<PaneInfo> shellPanes = const [],
}) => Snapshot(
  bridgeConnected: true,
  agents: agents,
  shellPanes: shellPanes,
  workspaces: workspaces,
  tabs: tabs,
  sessions: const [],
  ts: 1,
);

void main() {
  test('按 workspace/tab 分组，agent 按 triage 状态排在 shell 前', () {
    final snapshot = _snapshot(
      workspaces: [
        _workspace('w2', 2, label: 'beta'),
        _workspace('w1', 1),
        _workspace('w3', 3, label: 'empty'),
      ],
      tabs: [
        _tab('w1:t2', 'w1', 2),
        _tab('w1:t1', 'w1', 1, label: 'agents'),
        _tab('w2:t1', 'w2', 1, label: 'logs'),
      ],
      agents: [
        _pane('p-idle', workspaceId: 'w1', tabId: 'w1:t2'),
        _pane(
          'p-blocked',
          workspaceId: 'w1',
          tabId: 'w1:t1',
          status: AgentStatus.blocked,
        ),
        _pane(
          'p-working',
          workspaceId: 'w2',
          tabId: 'w2:t1',
          status: AgentStatus.working,
        ),
      ],
      shellPanes: [
        _pane(
          's-w1',
          workspaceId: 'w1',
          tabId: 'w1:t1',
          agent: 'shell',
          kind: 'shell',
          cwd: '/work/shells',
        ),
        _pane(
          's-w2',
          workspaceId: 'w2',
          tabId: 'w2:t1',
          agent: 'shell',
          kind: 'shell',
        ),
      ],
    );

    final spaces = snapshot.spaces;
    expect(spaces.map((space) => space.workspace.workspaceId), [
      'w1',
      'w2',
      'w3',
    ]);

    final first = spaces[0];
    expect(first.tabCount, 2);
    expect(first.paneCount, 3);
    expect(first.agentCount, 2);
    expect(first.status, AgentStatus.blocked);
    expect(first.blockedCount, 1);
    expect(first.tabs[0].tab.tabId, 'w1:t1');
    // blocked agent 在 shell 前。
    expect(first.tabs[0].panes.map((pane) => pane.paneId), [
      'p-blocked',
      's-w1',
    ]);
    expect(first.tabs[1].panes.single.paneId, 'p-idle');

    expect(spaces[1].status, AgentStatus.working);
    expect(spaces[2].tabCount, 0);
    expect(spaces[2].paneCount, 0);
    expect(spaces[2].status, isNull);
  });

  test('pane/tab 指向快照里缺失的 workspace 时用 pane 自带标签占位', () {
    final snapshot = _snapshot(
      agents: [
        _pane(
          'orphan',
          workspaceId: 'w9',
          tabId: 'w9:t9',
          workspaceLabel: 'orphan-space',
          workspaceNumber: 9,
          tabLabel: 'agent',
        ),
      ],
      tabs: [_tab('w8:t1', 'w8', 1, label: 'floating')],
    );

    final spaces = snapshot.spaces;
    expect(spaces.map((space) => space.workspace.workspaceId), ['w8', 'w9']);
    expect(spaces[0].tabs.single.tab.label, 'floating');
    expect(spaces[0].panes, isEmpty);
    expect(spaces[1].workspace.label, 'orphan-space');
    expect(spaces[1].workspace.number, 9);
    expect(spaces[1].tabs.single.tab.label, 'agent');
    expect(spaces[1].panes.single.paneId, 'orphan');
  });

  test('重复 paneId 只保留第一条；paneById 覆盖 agent 与 shell', () {
    final blocked = _pane(
      'dup',
      workspaceId: 'w1',
      tabId: 'w1:t1',
      status: AgentStatus.blocked,
    );
    final shell = _pane(
      's1',
      workspaceId: 'w1',
      tabId: 'w1:t1',
      agent: 'shell',
      kind: 'shell',
      cwd: '/home/me/project',
    );
    final snapshot = _snapshot(
      workspaces: [_workspace('w1', 1)],
      tabs: [_tab('w1:t1', 'w1', 1)],
      agents: [blocked],
      shellPanes: [
        _pane('dup', workspaceId: 'w1', tabId: 'w1:t1'),
        shell,
      ],
    );

    final space = snapshot.spaces.single;
    expect(space.panes.map((pane) => pane.paneId), ['dup', 's1']);
    expect(space.panes.first.status, AgentStatus.blocked);
    expect(snapshot.paneById('s1'), same(shell));
    expect(snapshot.paneById('missing'), isNull);
    expect(shell.displayName, 'project');
  });

  test('纯数字 label 只是位置序号，标题回退到编号', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final space = SpaceInfo(
      workspace: _workspace('w1', 1, label: '1'),
      tabs: const [],
      panes: const [],
    );
    expect(spaceTitle(l10n, space), 'Space 1');

    final tab = _tab('w1:t1', 'w1', 1, label: '1');
    expect(spaceWindowTitle(l10n, tab), 'Tab 1');
    expect(
      spaceWindowTitle(l10n, _tab('w1:t2', 'w1', 2, label: 'logs')),
      'Tab 2 · logs',
    );
  });
}
