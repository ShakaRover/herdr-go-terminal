import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../model/models.dart';
import '../../state/bridges.dart';
import '../../state/easytier_runtime.dart';
import '../../state/pinned.dart';
import '../../state/snapshot.dart';
import '../../util/relative_time.dart';
import '../agent/agent_screen.dart';
import '../content_pane.dart';
import '../settings/settings_screen.dart';
import '../status_style.dart';
import 'agent_preview_sheet.dart';
import 'create_agent_sheet.dart';

/// triage 首页：顶部 tab 栏 = 「全部」（聚合各宿主机）+ 每个 enabled bridge
/// 一个 tab；分段结构不变（已置顶 / 需要你处理 / 工作中 / 其他）。
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  void _openSettings(BuildContext context) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final conns = ref.watch(bridgesProvider);
    final focused = ref.watch(focusedBridgeProvider);
    // focused 指向的 bridge 已不在列表（被删除/停用）时回落到「全部」。
    final focusedIndex = focused.isEmpty
        ? 0
        : conns.indexWhere((c) => c.id == focused) + 1;
    final safeIndex = focusedIndex < 0 ? 0 : focusedIndex;

    return DefaultTabController(
      length: 1 + conns.length,
      initialIndex: safeIndex,
      child: Builder(
        builder: (context) {
          final tabController = DefaultTabController.of(context);
          // tab 切换 → focusedBridgeProvider（post-frame 回写，避免 build
          // 期间改 provider）。
          if (!tabController.indexIsChanging &&
              tabController.index < 1 + conns.length) {
            final selected = tabController.index == 0
                ? ''
                : conns[tabController.index - 1].id;
            if (selected != focused) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ref.read(focusedBridgeProvider.notifier).select(selected);
              });
            }
          }

          return Scaffold(
            appBar: AppBar(
              title: const Text('HerdrGo'),
              bottom: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(text: l10n.allBridges),
                  for (final c in conns) _ConnTab(conn: c),
                ],
              ),
              actions: [
                // session 切换仅作用于单 bridge tab（全部 tab 直接用各
                // bridge 当前选择，不提供切换入口）。
                if (safeIndex > 0)
                  _SessionMenu(
                    conn: conns[safeIndex - 1],
                    state: ref.watch(bridgeSnapshotProvider(focused)),
                  ),
                if (conns.any(
                  (conn) => conn.status == ConnStatus.ready && conn.api != null,
                ))
                  IconButton(
                    tooltip: l10n.newAgent,
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      final index = tabController.index;
                      final initialBridgeId = index > 0 && index <= conns.length
                          ? conns[index - 1].id
                          : null;
                      _openCreateAgent(
                        context,
                        ref,
                        initialBridgeId: initialBridgeId,
                      );
                    },
                  ),
                IconButton(
                  tooltip: l10n.settingsTooltip,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => _openSettings(context),
                ),
              ],
            ),
            body: TabBarView(
              children: [
                if (conns.isEmpty)
                  _NoDevices(onAdd: () => _openSettings(context))
                else
                  _AllBridgeTab(conns: conns),
                for (final c in conns) _SingleBridgeTab(conn: c),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NoDevices extends StatelessWidget {
  const _NoDevices({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: contentPanePadding(context, const EdgeInsets.all(32)),
      children: [
        const SizedBox(height: 80),
        Icon(
          Icons.devices_other_outlined,
          size: 48,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(height: 16),
        Text(
          l10n.noDevicesTitle,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.noDevicesHelp,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          label: Text(l10n.addDevice),
        ),
      ],
    );
  }
}

Future<void> _openCreateAgent(
  BuildContext context,
  WidgetRef ref, {
  String? initialBridgeId,
}) async {
  final outcome = await showCreateAgentSheet(
    context,
    initialBridgeId: initialBridgeId,
  );
  if (outcome == null || !context.mounted) return;

  ref
      .read(sessionFilterProvider(outcome.bridgeId).notifier)
      .select(outcome.session);
  // 创建成功后立即进详情；快照刷新留在后台，避免额外等待一次网络往返。
  unawaited(
    ref.read(bridgeSnapshotProvider(outcome.bridgeId).notifier).refresh(),
  );

  final result = outcome.result;
  if (!result.success) {
    final open = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.agentCreatePartialTitle),
        content: Text(
          dialogContext.l10n.agentCreatePartialBody(
            result.paneId,
            result.error ?? dialogContext.l10n.unknownError,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.openTerminal),
          ),
        ],
      ),
    );
    if (open != true || !context.mounted) return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          AgentScreen(bridgeId: outcome.bridgeId, paneId: result.paneId),
    ),
  );
}

/// 单 bridge tab 的 label：状态点 + 连接名。
class _ConnTab extends StatelessWidget {
  const _ConnTab({required this.conn});

  final BridgeConn conn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dotColor = switch (conn.status) {
      ConnStatus.connecting => scheme.tertiary,
      ConnStatus.ready => scheme.primary,
      ConnStatus.failed => scheme.error,
    };
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: dotColor),
          const SizedBox(width: 6),
          Text(conn.label),
        ],
      ),
    );
  }
}

/// 单 bridge tab 的 session 切换菜单（沿用原 AppBar 下拉，数据源按
/// bridgeId 取快照与 sessionFilter family）。
class _SessionMenu extends ConsumerWidget {
  const _SessionMenu({required this.conn, required this.state});

  final BridgeConn conn;
  final SnapshotState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final snap = state.data;
    if (snap == null || snap.sessions.length <= 1) {
      return const SizedBox.shrink();
    }
    final session = ref.watch(sessionFilterProvider(conn.id));
    return PopupMenuButton<String?>(
      tooltip: l10n.switchSessionTooltip,
      icon: const Icon(Icons.layers_outlined),
      initialValue: session,
      onSelected: (v) =>
          ref.read(sessionFilterProvider(conn.id).notifier).select(v),
      itemBuilder: (_) => [
        for (final s in snap.sessions)
          PopupMenuItem(
            value: s.isPrimary ? null : s.name,
            child: Text(
              l10n.sessionSummary(
                s.isPrimary ? l10n.defaultSession : s.name,
                s.blocked,
                s.working,
              ),
            ),
          ),
      ],
    );
  }
}

/// 「全部」tab：跨 bridge 聚合视图，卡片带宿主机标签。
class _AllBridgeTab extends ConsumerWidget {
  const _AllBridgeTab({required this.conns});

  final List<BridgeConn> conns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshots = {
      for (final c in conns) c.id: ref.watch(bridgeSnapshotProvider(c.id)),
    };
    final bps = aggregateBridgePanes(conns, snapshots);
    final failed = conns.where((c) => c.status == ConnStatus.failed).toList();

    return Column(
      children: [
        if (failed.isNotEmpty)
          _Banner(
            color: Theme.of(context).colorScheme.errorContainer,
            text: context.l10n.connectionsInterrupted(failed.length),
            onTap: () {
              // 跳到首个 failed 的 tab（tab 索引 = conn 索引 + 1）。
              final i = conns.indexOf(failed.first) + 1;
              DefaultTabController.of(context).animateTo(i);
            },
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              for (final c in conns) {
                if (c.status == ConnStatus.ready) {
                  await ref
                      .read(bridgeSnapshotProvider(c.id).notifier)
                      .refresh();
                }
              }
            },
            // 连接尚未 ready（无 conn / 全部 connecting/failed）时聚合必
            // 为空，展示连接中占位，而不是「没有 agent」空态。
            child:
                conns.isEmpty || conns.any((c) => c.status == ConnStatus.ready)
                ? _BridgePaneList(
                    panes: bps,
                    pinned: ref.watch(pinnedPanesProvider),
                    showBridgeLabel: true,
                  )
                : const _LoadingOrEmpty(),
          ),
        ),
      ],
    );
  }
}

/// 单 bridge tab：原 dashboard 视图（四档断线横幅 + session 过滤后的列表）。
class _SingleBridgeTab extends ConsumerWidget {
  const _SingleBridgeTab({required this.conn});

  final BridgeConn conn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(bridgeSnapshotProvider(conn.id));
    final session = ref.watch(sessionFilterProvider(conn.id));
    final runtime = ref.watch(easytierRuntimeProvider(conn.id));
    final snap = state.data;

    final panes = snap == null
        ? const <BridgePane>[]
        : [
            for (final p in triageSorted(snap.agents))
              BridgePane(bridgeId: conn.id, bridgeLabel: conn.label, pane: p),
          ];

    return Column(
      children: [
        if (runtime is EasyTierConnecting)
          _Banner(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            text: l10n.easyTierConnecting,
          )
        else if (runtime is EasyTierFailed)
          _Banner(
            color: Theme.of(context).colorScheme.errorContainer,
            text: l10n.easyTierFailed(
              runtime.virtualIpTimeoutSeconds == null
                  ? runtime.message
                  : l10n.virtualIpTimeout(runtime.virtualIpTimeoutSeconds!),
            ),
          )
        else if (state.error != null)
          _Banner(
            color: Theme.of(context).colorScheme.errorContainer,
            text: l10n.connectionInterrupted('${state.error}'),
          )
        else if (snap != null && !snap.bridgeConnected)
          _Banner(
            color: Theme.of(context).colorScheme.errorContainer,
            text: l10n.herdrOffline,
          )
        else if (snap != null && snap.readOnly)
          _Banner(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            text: l10n.readOnlyMode,
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(bridgeSnapshotProvider(conn.id).notifier).refresh(),
            child: snap == null
                ? const _LoadingOrEmpty()
                : _BridgePaneList(
                    panes: panes,
                    pinned: ref.watch(pinnedPanesProvider),
                    showBridgeLabel: false,
                    session: session,
                  ),
          ),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.text, this.onTap});

  final Color color;
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
    return onTap == null ? body : InkWell(onTap: onTap, child: body);
  }
}

class _LoadingOrEmpty extends StatelessWidget {
  const _LoadingOrEmpty();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        const Center(child: CircularProgressIndicator()),
        const SizedBox(height: 16),
        Center(
          child: Text(
            context.l10n.bridgeConnecting,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

/// 四段分组列表（已置顶 / 需要你处理 / 工作中 / 其他），单 bridge 与聚合
/// 视图共用：入参已按目标序排好（单 bridge 为 triageSorted，聚合为
/// aggregateBridgePanes），pin 三段式按各自 bridgeId + session 判。
class _BridgePaneList extends StatelessWidget {
  const _BridgePaneList({
    required this.panes,
    required this.pinned,
    required this.showBridgeLabel,
    this.session,
  });

  final List<BridgePane> panes;
  final Set<String> pinned;

  /// 卡片 subtitle 是否带「<宿主机 label> · 」前缀（全部 tab 开）。
  final bool showBridgeLabel;

  /// 单 bridge tab 的 session（pin key 中段）；全部 tab 为 null（按 bp 逐条
  /// 读各自 bridge 当前 session，见 [isPanePinned]）。
  final String? session;

  @override
  Widget build(BuildContext context) {
    if (panes.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: contentPanePadding(context, const EdgeInsets.all(32)),
        children: [
          const SizedBox(height: 80),
          Icon(
            Icons.pest_control_rodent_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.noAgents,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      );
    }

    // 单 bridge：session 已确定，splitPinned 一次切两段；全部 tab 各 pane
    // 的 session 不同，逐条 isPinned 切。
    final List<BridgePane> pinnedPanes;
    final List<BridgePane> unpinned;
    if (session != null) {
      (pinnedPanes, unpinned) = splitPinned(
        panes,
        pinned,
        panes.first.bridgeId,
        session,
        (bp) => bp.pane.paneId,
      );
    } else {
      pinnedPanes = [];
      unpinned = [];
      for (final bp in panes) {
        (isPanePinned(context, bp) ? pinnedPanes : unpinned).add(bp);
      }
    }

    final needsYou = unpinned
        .where((p) => p.pane.status == AgentStatus.blocked)
        .toList();
    final working = unpinned
        .where((p) => p.pane.status == AgentStatus.working)
        .toList();
    final rest = unpinned
        .where(
          (p) =>
              p.pane.status != AgentStatus.blocked &&
              p.pane.status != AgentStatus.working,
        )
        .toList();

    Widget card(BridgePane bp) => _AgentCard(
      pane: bp.pane,
      pinned: isPanePinned(context, bp),
      bridgeId: bp.bridgeId,
      bridgeLabel: showBridgeLabel ? bp.bridgeLabel : null,
    );

    final children = <Widget>[
      if (pinnedPanes.isNotEmpty) ...[
        _SectionHeader(context.l10n.sectionPinned),
        for (final p in pinnedPanes) card(p),
      ],
      if (needsYou.isNotEmpty) ...[
        _SectionHeader(context.l10n.sectionNeedsAttention),
        for (final p in needsYou) card(p),
      ],
      if (working.isNotEmpty) ...[
        _SectionHeader(context.l10n.sectionWorking),
        for (final p in working) card(p),
      ],
      if (rest.isNotEmpty) ...[
        _SectionHeader(context.l10n.sectionOther),
        for (final p in rest) card(p),
      ],
      const SizedBox(height: 24),
    ];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: contentPanePadding(
        context,
        const EdgeInsets.symmetric(horizontal: 12),
      ),
      children: children,
    );
  }

  /// 该 pane 是否已置顶：session 固定时用列表字段；否则（全部 tab）读该
  /// pane 所属 bridge 的当前 session 选择。
  bool isPanePinned(BuildContext context, BridgePane bp) {
    final s = session ?? _readBridgeSession(context, bp.bridgeId);
    return isPinned(pinned, bp.bridgeId, s, bp.pane.paneId);
  }

  static String? _readBridgeSession(BuildContext context, String bridgeId) =>
      ProviderScope.containerOf(
        context,
        listen: false,
      ).read(sessionFilterProvider(bridgeId));
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

class _AgentCard extends ConsumerWidget {
  const _AgentCard({
    required this.pane,
    required this.pinned,
    required this.bridgeId,
    this.bridgeLabel,
  });

  final PaneInfo pane;
  final bool pinned;
  final String bridgeId;

  /// 宿主机标签；非空时 subtitle 首行前缀「<label> · 」（全部 tab 用）。
  final String? bridgeLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final time = relativeTime(pane.lastActiveAt, now, context.l10n);
    final location = [
      ?bridgeLabel,
      pane.workspaceLabel,
      if (pane.tabLabel != null) pane.tabLabel!,
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(
          Icons.circle,
          size: 12,
          color: statusColor(scheme, pane.status),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                pane.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (pinned) ...[
              const SizedBox(width: 4),
              Icon(Icons.push_pin, size: 16, color: scheme.outline),
            ],
          ],
        ),
        subtitle: Text(
          [
            location,
            pane.cwd,
            if (time.isNotEmpty) time,
          ].where((s) => s.isNotEmpty).join('\n'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: Chip(
          label: Text(statusLabel(context.l10n, pane.status)),
          visualDensity: VisualDensity.compact,
          side: BorderSide.none,
          backgroundColor: statusColor(
            scheme,
            pane.status,
          ).withValues(alpha: 0.15),
        ),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  AgentScreen(bridgeId: bridgeId, paneId: pane.paneId),
            ),
          );
        },
        onLongPress: () => AgentPreviewSheet.show(
          context,
          bridgeId: bridgeId,
          pane: pane,
          pinned: pinned,
        ),
      ),
    );
  }
}
