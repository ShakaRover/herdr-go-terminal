/// herdr-bridge（Rust，见仓库 `bridge/`）的 REST 响应模型。
///
/// bridge 的 API 仍在演进，因此这里全部做宽容解析：
/// 未知字段忽略，可选字段缺失时给默认值，类型不符时回退默认。
library;

// ---------------------------------------------------------------------------
// 解析小工具
// ---------------------------------------------------------------------------

String _s(Map<String, dynamic> j, String k, [String d = '']) =>
    j[k] is String ? j[k] as String : d;

String? _so(Map<String, dynamic> j, String k) =>
    j[k] is String ? j[k] as String : null;

int _i(Map<String, dynamic> j, String k, [int d = 0]) =>
    j[k] is num ? (j[k] as num).toInt() : d;

int? _io(Map<String, dynamic> j, String k) =>
    j[k] is num ? (j[k] as num).toInt() : null;

bool _b(Map<String, dynamic> j, String k, [bool d = false]) =>
    j[k] is bool ? j[k] as bool : d;

List<Map<String, dynamic>> _l(Map<String, dynamic> j, String k) => j[k] is List
    ? (j[k] as List).whereType<Map<String, dynamic>>().toList()
    : const [];

// ---------------------------------------------------------------------------
// Agent / pane
// ---------------------------------------------------------------------------

enum AgentStatus { idle, working, blocked, done, unknown }

AgentStatus parseAgentStatus(String raw) => switch (raw) {
      'idle' => AgentStatus.idle,
      'working' => AgentStatus.working,
      'blocked' => AgentStatus.blocked,
      'done' => AgentStatus.done,
      _ => AgentStatus.unknown,
    };

/// triage 排序权重：值越小越靠前（blocked 最紧急）。
int statusRank(AgentStatus s) => switch (s) {
      AgentStatus.blocked => 0,
      AgentStatus.working => 1,
      AgentStatus.unknown => 2,
      AgentStatus.idle => 3,
      AgentStatus.done => 4,
    };

/// 浏览器看到的 pane（collie `PaneWire`）。
class PaneInfo {
  const PaneInfo({
    required this.paneId,
    required this.workspaceId,
    required this.workspaceLabel,
    required this.workspaceNumber,
    required this.tabId,
    required this.agent,
    required this.status,
    required this.cwd,
    required this.focused,
    this.kind = 'agent',
    this.paneLabel,
    this.sessionName,
    this.readableLines,
    this.tabLabel,
    this.lastActiveAt,
    this.lastSeenAt,
    this.hasSession = false,
  });

  final String paneId;
  final String workspaceId;
  final String workspaceLabel;
  final int workspaceNumber;
  final String tabId;
  final String agent;
  final AgentStatus status;
  final String cwd;
  final bool focused;

  /// "agent" | "shell"。
  final String kind;
  final String? paneLabel;

  /// Claude 自己的 /rename 会话名（仅 claude，从 pane 文本提取）。
  final String? sessionName;
  final int? readableLines;
  final String? tabLabel;

  /// 最后一次状态跃迁（epoch ms）。
  final int? lastActiveAt;

  /// 最后一次通过客户端打开/操作（epoch ms）。
  final int? lastSeenAt;

  /// 该 pane 可能有对话历史（agent 命名了会话且有 journal 适配器）。
  final bool hasSession;

  /// 展示名优先级：paneLabel > sessionName > agent。
  String get displayName => paneLabel ?? sessionName ?? agent;

  bool get isShell => kind == 'shell';

  factory PaneInfo.fromJson(Map<String, dynamic> j) => PaneInfo(
        paneId: _s(j, 'paneId'),
        workspaceId: _s(j, 'workspaceId'),
        workspaceLabel: _s(j, 'workspaceLabel'),
        workspaceNumber: _i(j, 'workspaceNumber'),
        tabId: _s(j, 'tabId'),
        agent: _s(j, 'agent', '?'),
        status: parseAgentStatus(_s(j, 'status')),
        cwd: _s(j, 'cwd'),
        focused: _b(j, 'focused'),
        kind: _s(j, 'kind', 'agent'),
        paneLabel: _so(j, 'paneLabel'),
        sessionName: _so(j, 'sessionName'),
        readableLines: _io(j, 'readableLines'),
        tabLabel: _so(j, 'tabLabel'),
        lastActiveAt: _io(j, 'lastActiveAt'),
        lastSeenAt: _io(j, 'lastSeenAt'),
        hasSession: _b(j, 'hasSession'),
      );
}

// ---------------------------------------------------------------------------
// Workspace / tab / session
// ---------------------------------------------------------------------------

class WorkspaceInfo {
  const WorkspaceInfo({
    required this.workspaceId,
    required this.number,
    required this.label,
    required this.focused,
    required this.activeTabId,
    required this.tabCount,
    required this.paneCount,
  });

  final String workspaceId;
  final int number;
  final String label;
  final bool focused;
  final String activeTabId;
  final int tabCount;
  final int paneCount;

  factory WorkspaceInfo.fromJson(Map<String, dynamic> j) => WorkspaceInfo(
        workspaceId: _s(j, 'workspaceId'),
        number: _i(j, 'number'),
        label: _s(j, 'label'),
        focused: _b(j, 'focused'),
        activeTabId: _s(j, 'activeTabId'),
        tabCount: _i(j, 'tabCount'),
        paneCount: _i(j, 'paneCount'),
      );
}

class TabInfo {
  const TabInfo({
    required this.tabId,
    required this.workspaceId,
    required this.number,
    required this.label,
    required this.focused,
    required this.paneCount,
  });

  final String tabId;
  final String workspaceId;
  final int number;
  final String label;
  final bool focused;
  final int paneCount;

  factory TabInfo.fromJson(Map<String, dynamic> j) => TabInfo(
        tabId: _s(j, 'tabId'),
        workspaceId: _s(j, 'workspaceId'),
        number: _i(j, 'number'),
        label: _s(j, 'label'),
        focused: _b(j, 'focused'),
        paneCount: _i(j, 'paneCount'),
      );
}

class SessionSummary {
  const SessionSummary({
    required this.name,
    required this.isPrimary,
    required this.reachable,
    required this.agents,
    required this.working,
    required this.blocked,
  });

  final String name;
  final bool isPrimary;
  final bool reachable;
  final int agents;
  final int working;
  final int blocked;

  factory SessionSummary.fromJson(Map<String, dynamic> j) => SessionSummary(
        name: _s(j, 'name'),
        isPrimary: _b(j, 'isPrimary'),
        reachable: _b(j, 'reachable'),
        agents: _i(j, 'agents'),
        working: _i(j, 'working'),
        blocked: _i(j, 'blocked'),
      );
}

/// collie device gate 对当前请求者的判定。
class DeviceAuth {
  const DeviceAuth({
    required this.enforced,
    required this.device,
    required this.authorized,
  });

  final bool enforced;
  final String? device;
  final bool authorized;

  factory DeviceAuth.fromJson(Map<String, dynamic> j) => DeviceAuth(
        enforced: _b(j, 'enforced'),
        device: _so(j, 'device'),
        authorized: _b(j, 'authorized'),
      );
}

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

class Snapshot {
  const Snapshot({
    required this.bridgeConnected,
    this.device,
    required this.agents,
    required this.shellPanes,
    required this.workspaces,
    required this.tabs,
    required this.sessions,
    required this.ts,
  });

  final bool bridgeConnected;
  final DeviceAuth? device;
  final List<PaneInfo> agents;
  final List<PaneInfo> shellPanes;
  final List<WorkspaceInfo> workspaces;
  final List<TabInfo> tabs;
  final List<SessionSummary> sessions;
  final int ts;

  bool get readOnly => device != null && device!.enforced && !device!.authorized;

  factory Snapshot.fromJson(Map<String, dynamic> j) => Snapshot(
        bridgeConnected: _s(j, 'bridge', 'disconnected') == 'connected',
        device: j['device'] is Map<String, dynamic>
            ? DeviceAuth.fromJson(j['device'] as Map<String, dynamic>)
            : null,
        agents: _l(j, 'agents').map(PaneInfo.fromJson).toList(),
        shellPanes: _l(j, 'shellPanes').map(PaneInfo.fromJson).toList(),
        workspaces: _l(j, 'workspaces').map(WorkspaceInfo.fromJson).toList(),
        tabs: _l(j, 'tabs').map(TabInfo.fromJson).toList(),
        sessions: _l(j, 'sessions').map(SessionSummary.fromJson).toList(),
        ts: _i(j, 'ts'),
      );
}

// ---------------------------------------------------------------------------
// Pane read
// ---------------------------------------------------------------------------

class PaneRead {
  const PaneRead({
    required this.paneId,
    required this.text,
    required this.truncated,
    required this.revision,
    this.notModified = false,
  });

  final String paneId;

  /// 带 ANSI/SGR 的输出文本。
  final String text;
  final bool truncated;

  /// herdr 的单调 pane 修订号，用于 prompt-select 的竞态防护。
  final int revision;

  /// 本次为 ETag 304 命中，body 来自客户端缓存（见 api 层 ETag 策略）。
  final bool notModified;

  PaneRead copyAsNotModified() => PaneRead(
        paneId: paneId,
        text: text,
        truncated: truncated,
        revision: revision,
        notModified: true,
      );

  factory PaneRead.fromJson(Map<String, dynamic> j) => PaneRead(
        paneId: _s(j, 'paneId'),
        text: _s(j, 'text'),
        truncated: _b(j, 'truncated'),
        revision: _i(j, 'revision'),
      );
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

class BridgeConfig {
  const BridgeConfig({
    required this.push,
    required this.vapidPublicKey,
    this.build,
  });

  final bool push;
  final String vapidPublicKey;
  final String? build;

  factory BridgeConfig.fromJson(Map<String, dynamic> j) => BridgeConfig(
        push: _b(j, 'push'),
        vapidPublicKey: _s(j, 'vapidPublicKey'),
        build: _so(j, 'build'),
      );
}
