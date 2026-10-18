/// herdr workspace（app 里叫 space）的只读拓扑：workspace → tab（窗口）→ pane。
///
/// bridge 的 snapshot 已经把 `workspaces` / `tabs` / `agents` / `shellPanes`
/// 分开返回，这里只做纯函数归并，不改协议。app 的「Spaces」列表和空间详情
/// 都从同一份快照派生，避免维护第二套状态。
library;

import 'models.dart';

/// 一个窗口（herdr tab）及其窗格。
class SpaceTab {
  const SpaceTab({required this.tab, required this.panes});

  final TabInfo tab;
  final List<PaneInfo> panes;
}

/// 一个 space（herdr workspace）及其窗口/窗格。
class SpaceInfo {
  const SpaceInfo({
    required this.workspace,
    required this.tabs,
    required this.panes,
  });

  final WorkspaceInfo workspace;
  final List<SpaceTab> tabs;

  /// 按窗口顺序展开的全部 pane（agent + shell）。
  final List<PaneInfo> panes;

  int get tabCount => tabs.length;
  int get paneCount => panes.length;

  int get agentCount {
    var count = 0;
    for (final pane in panes) {
      if (!pane.isShell) count++;
    }
    return count;
  }

  /// space 内 agent 的最紧急状态；没有 agent 时为 null。
  AgentStatus? get status {
    AgentStatus? worst;
    for (final pane in panes) {
      if (pane.isShell) continue;
      if (worst == null || statusRank(pane.status) < statusRank(worst)) {
        worst = pane.status;
      }
    }
    return worst;
  }

  int get blockedCount {
    var count = 0;
    for (final pane in panes) {
      if (!pane.isShell && pane.status == AgentStatus.blocked) count++;
    }
    return count;
  }

  int get workingCount {
    var count = 0;
    for (final pane in panes) {
      if (!pane.isShell && pane.status == AgentStatus.working) count++;
    }
    return count;
  }

  bool get focused => workspace.focused || panes.any((pane) => pane.focused);

  /// 卡片副标题用：优先焦点 pane 的 cwd，否则第一个有 cwd 的 pane。
  String? get cwd {
    for (final pane in panes) {
      if (pane.focused && pane.cwd.trim().isNotEmpty) return pane.cwd;
    }
    for (final pane in panes) {
      if (pane.cwd.trim().isNotEmpty) return pane.cwd;
    }
    return null;
  }
}

/// 快照 → spaces 拓扑的便捷入口。
extension SnapshotSpaces on Snapshot {
  List<SpaceInfo> get spaces => buildSpaces(this);
}

/// 从快照派生 spaces：按 workspace 分组，再按 tab 分组。
///
/// 宽容处理 bridge/herdr 的瞬时不一致：
/// - pane 指向的 workspace/tab 暂时不在 `workspaces`/`tabs` 里时，用 pane 上
///   自带的 label/number 造一个占位；
/// - 只有 workspace/tab、没有 pane 也保留（空空间/空窗口是合法状态）；
/// - 重复 paneId 只保留第一条。
List<SpaceInfo> buildSpaces(Snapshot snapshot) {
  final workspaces = <String, WorkspaceInfo>{
    for (final workspace in snapshot.workspaces)
      workspace.workspaceId: workspace,
  };
  final tabsByWorkspace = <String, Map<String, TabInfo>>{};
  for (final tab in snapshot.tabs) {
    tabsByWorkspace.putIfAbsent(tab.workspaceId, () => {})[tab.tabId] = tab;
  }
  final panesByTab = <String, List<PaneInfo>>{};
  final seenPaneIds = <String>{};

  for (final pane in snapshot.allPanes) {
    if (!seenPaneIds.add(pane.paneId)) continue;
    panesByTab.putIfAbsent(pane.tabId, () => []).add(pane);
    workspaces.putIfAbsent(pane.workspaceId, () => _workspaceFromPane(pane));
    tabsByWorkspace
        .putIfAbsent(pane.workspaceId, () => {})
        .putIfAbsent(pane.tabId, () => _tabFromPane(pane));
  }
  // tab 指向的 workspace 暂时不在快照 workspaces 里：保留窗口。
  for (final entry in tabsByWorkspace.entries) {
    workspaces.putIfAbsent(entry.key, () => _workspaceFromTabs(entry.key));
  }

  final orderedIds = workspaces.keys.toList()
    ..sort((a, b) {
      final left = workspaces[a]!;
      final right = workspaces[b]!;
      final byNumber = left.number.compareTo(right.number);
      return byNumber != 0 ? byNumber : a.compareTo(b);
    });

  final spaces = <SpaceInfo>[];
  for (final workspaceId in orderedIds) {
    final workspace = workspaces[workspaceId]!;
    final tabs = (tabsByWorkspace[workspaceId]?.values.toList() ?? <TabInfo>[])
      ..sort(_compareTabs);
    final spaceTabs = <SpaceTab>[];
    final panes = <PaneInfo>[];
    for (final tab in tabs) {
      final tabPanes = [...?panesByTab[tab.tabId]]..sort(_comparePanes);
      spaceTabs.add(SpaceTab(tab: tab, panes: tabPanes));
      panes.addAll(tabPanes);
    }
    spaces.add(SpaceInfo(workspace: workspace, tabs: spaceTabs, panes: panes));
  }
  return spaces;
}

int _compareTabs(TabInfo a, TabInfo b) {
  final byNumber = a.number.compareTo(b.number);
  if (byNumber != 0) return byNumber;
  final byLabel = a.label.compareTo(b.label);
  return byLabel != 0 ? byLabel : a.tabId.compareTo(b.tabId);
}

/// 同一窗口内 agent 按 triage 状态排，shell 沉底；同级按 paneId 稳定排序。
int _comparePanes(PaneInfo a, PaneInfo b) {
  if (a.isShell != b.isShell) return a.isShell ? 1 : -1;
  if (!a.isShell) {
    final byStatus = statusRank(a.status).compareTo(statusRank(b.status));
    if (byStatus != 0) return byStatus;
  }
  return a.paneId.compareTo(b.paneId);
}

WorkspaceInfo _workspaceFromPane(PaneInfo pane) => WorkspaceInfo(
  workspaceId: pane.workspaceId,
  number: pane.workspaceNumber,
  label: pane.workspaceLabel,
  focused: false,
  activeTabId: '',
  tabCount: 0,
  paneCount: 0,
);

WorkspaceInfo _workspaceFromTabs(String workspaceId) => WorkspaceInfo(
  workspaceId: workspaceId,
  number: 0,
  label: '',
  focused: false,
  activeTabId: '',
  tabCount: 0,
  paneCount: 0,
);

TabInfo _tabFromPane(PaneInfo pane) => TabInfo(
  tabId: pane.tabId,
  workspaceId: pane.workspaceId,
  number: 0,
  label: pane.tabLabel ?? '',
  focused: false,
  paneCount: 0,
);
