import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/models.dart';
import '../../state/easytier_runtime.dart';
import '../../state/pinned.dart';
import '../../state/snapshot.dart';
import '../../util/relative_time.dart';
import '../agent/agent_screen.dart';
import '../settings/settings_screen.dart';
import 'agent_preview_sheet.dart';

/// triage 首页：「已置顶」分组最顶，随后 blocked（需要你处理）、working、idle/done。
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(snapshotProvider);
    final session = ref.watch(sessionFilterProvider);
    final pinned = ref.watch(pinnedPanesProvider);
    final runtime = ref.watch(easytierRuntimeProvider);
    final snap = state.data;

    return Scaffold(
      appBar: AppBar(
        title: const Text('herdr'),
        actions: [
          if (snap != null && snap.sessions.length > 1)
            PopupMenuButton<String?>(
              tooltip: '切换 session',
              icon: const Icon(Icons.layers_outlined),
              initialValue: session,
              onSelected: (v) =>
                  ref.read(sessionFilterProvider.notifier).select(v),
              itemBuilder: (_) => [
                for (final s in snap.sessions)
                  PopupMenuItem(
                    value: s.isPrimary ? null : s.name,
                    child: Text(
                      '${s.isPrimary ? '默认' : s.name}'
                      '（${s.blocked} 待处理 / ${s.working} 工作中）',
                    ),
                  ),
              ],
            ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (runtime is EasyTierConnecting)
            _Banner(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              text: '正在连接 EasyTier 网络…',
            )
          else if (runtime is EasyTierFailed)
            _Banner(
              color: Theme.of(context).colorScheme.errorContainer,
              text: 'EasyTier 连接失败（${runtime.message}）',
            )
          else if (state.error != null)
            _Banner(
              color: Theme.of(context).colorScheme.errorContainer,
              text: '连接中断，展示的是上次数据（${state.error}）',
            )
          else if (snap != null && !snap.bridgeConnected)
            _Banner(
              color: Theme.of(context).colorScheme.errorContainer,
              text: 'herdr 离线（bridge 连不上 herdr server）',
            )
          else if (snap != null && snap.readOnly)
            _Banner(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              text: '当前设备未授权写操作（只读模式）',
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => ref.read(snapshotProvider.notifier).refresh(),
              child: snap == null
                  ? const _LoadingOrEmpty()
                  : _AgentList(
                      snapshot: snap, pinned: pinned, session: session),
            ),
          ),
        ],
      ),
    );
  }

}

class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.text});

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
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
          child: Text('正在连接 bridge…',
              style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

class _AgentList extends StatelessWidget {
  const _AgentList({
    required this.snapshot,
    required this.pinned,
    required this.session,
  });

  final Snapshot snapshot;
  final Set<String> pinned;
  final String? session;

  @override
  Widget build(BuildContext context) {
    final sorted = triageSorted(snapshot.agents);
    if (sorted.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        children: [
          const SizedBox(height: 80),
          Icon(Icons.pest_control_rodent_outlined,
              size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 16),
          Text(
            '没有检测到 agent\n在电脑上的 herdr 里启动一个，这里就会出现',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      );
    }

    final (pinnedAgents, unpinned) = splitPinned(sorted, pinned, session);
    final needsYou =
        unpinned.where((p) => p.status == AgentStatus.blocked).toList();
    final working =
        unpinned.where((p) => p.status == AgentStatus.working).toList();
    final rest = unpinned
        .where((p) =>
            p.status != AgentStatus.blocked && p.status != AgentStatus.working)
        .toList();

    final children = <Widget>[
      if (pinnedAgents.isNotEmpty) ...[
        const _SectionHeader('已置顶'),
        for (final p in pinnedAgents) _AgentCard(pane: p, pinned: true),
      ],
      if (needsYou.isNotEmpty) ...[
        const _SectionHeader('需要你处理'),
        for (final p in needsYou) _AgentCard(pane: p, pinned: false),
      ],
      if (working.isNotEmpty) ...[
        const _SectionHeader('工作中'),
        for (final p in working) _AgentCard(pane: p, pinned: false),
      ],
      if (rest.isNotEmpty) ...[
        const _SectionHeader('其他'),
        for (final p in rest) _AgentCard(pane: p, pinned: false),
      ],
      const SizedBox(height: 24),
    ];

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: children,
    );
  }
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
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.outline),
      ),
    );
  }
}

Color statusColor(ColorScheme scheme, AgentStatus status) => switch (status) {
      AgentStatus.blocked => Colors.amber,
      AgentStatus.working => Colors.lightBlue,
      AgentStatus.done => Colors.green,
      AgentStatus.idle => scheme.outline,
      AgentStatus.unknown => scheme.outline,
    };

String statusLabel(AgentStatus status) => switch (status) {
      AgentStatus.blocked => '待处理',
      AgentStatus.working => '工作中',
      AgentStatus.done => '已完成',
      AgentStatus.idle => '空闲',
      AgentStatus.unknown => '未知',
    };

class _AgentCard extends ConsumerWidget {
  const _AgentCard({required this.pane, required this.pinned});

  final PaneInfo pane;
  final bool pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final time = relativeTime(pane.lastActiveAt, now);
    final location = [
      pane.workspaceLabel,
      if (pane.tabLabel != null) pane.tabLabel!,
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Icon(Icons.circle,
            size: 12, color: statusColor(scheme, pane.status)),
        title: Row(
          children: [
            Flexible(
              child: Text(pane.displayName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (pinned) ...[
              const SizedBox(width: 4),
              Icon(Icons.push_pin, size: 16, color: scheme.outline),
            ],
          ],
        ),
        subtitle: Text(
          [location, pane.cwd, if (time.isNotEmpty) time]
              .where((s) => s.isNotEmpty)
              .join('\n'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        isThreeLine: true,
        trailing: Chip(
          label: Text(statusLabel(pane.status)),
          visualDensity: VisualDensity.compact,
          side: BorderSide.none,
          backgroundColor:
              statusColor(scheme, pane.status).withValues(alpha: 0.15),
        ),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => AgentScreen(paneId: pane.paneId)),
          );
        },
        onLongPress: () =>
            AgentPreviewSheet.show(context, pane: pane, pinned: pinned),
      ),
    );
  }
}
