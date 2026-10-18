/// 单个 space（herdr workspace）的详情：按窗口（tab）列出全部窗格（pane）。
///
/// 手机屏幕不适合复刻 PC 的左右分栏，因此这里用「窗口标题 + 窗格卡片」的
/// 纵向结构：一个 space 的多个窗口、一个窗口的多个分屏都能直接看到；点任一
/// 窗格进入与 agent 相同的终端页，由 AgentScreen 负责终端接管（resize lease）、
/// 发键和回复。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../l10n/l10n.dart';
import '../../model/models.dart';
import '../../model/spaces.dart';
import '../../state/snapshot.dart';
import '../agent/agent_screen.dart';
import '../content_pane.dart';
import '../status_style.dart';

/// herdr 里纯数字的 label 只是位置序号（如 "1"），不应覆盖更有意义的标题。
String? _meaningfulLabel(String value) {
  final label = value.trim();
  if (label.isEmpty) return null;
  if (label.codeUnits.every((unit) => unit >= 0x30 && unit <= 0x39)) {
    return null;
  }
  return label;
}

/// space 展示名：workspace label >「Space N」> workspaceId。
String spaceTitle(AppLocalizations l10n, SpaceInfo space) {
  final label = _meaningfulLabel(space.workspace.label);
  if (label != null) return label;
  if (space.workspace.number > 0) {
    return l10n.spaceNumber(space.workspace.number);
  }
  return space.workspace.workspaceId;
}

/// 窗口展示名：「Tab N · label」，无编号时退回 label /「Tab」。
String spaceWindowTitle(AppLocalizations l10n, TabInfo tab) {
  final label = _meaningfulLabel(tab.label);
  if (tab.number > 0) {
    final base = l10n.spaceWindowNumber(tab.number);
    return label == null ? base : '$base · $label';
  }
  return label ?? l10n.spaceWindowUnnamed;
}

class SpaceScreen extends ConsumerWidget {
  const SpaceScreen({
    super.key,
    required this.bridgeId,
    required this.workspaceId,
    this.initialTitle,
  });

  final String bridgeId;
  final String workspaceId;

  /// 从列表点进来时先显示已有标题，避免快照首帧到达前闪「加载中」。
  final String? initialTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(bridgeSnapshotProvider(bridgeId));
    final snapshot = state.data;
    final space = snapshot?.spaces
        .where((item) => item.workspace.workspaceId == workspaceId)
        .firstOrNull;

    final title = space == null
        ? (initialTitle ?? l10n.loading)
        : spaceTitle(l10n, space);
    final subtitle = space == null
        ? null
        : l10n.spaceSummary(space.tabCount, space.paneCount, space.agentCount);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 16)),
            if (subtitle != null)
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          IconButton(
            tooltip: l10n.refreshTooltip,
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                ref.read(bridgeSnapshotProvider(bridgeId).notifier).refresh(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (snapshot != null && snapshot.readOnly)
            _Notice(text: l10n.readOnlyMode),
          if (state.error != null)
            _Notice(
              text: l10n.connectionInterrupted('${state.error}'),
              error: true,
            )
          else if (snapshot != null && !snapshot.bridgeConnected)
            _Notice(text: l10n.herdrOffline, error: true),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(bridgeSnapshotProvider(bridgeId).notifier).refresh(),
              child: snapshot == null
                  ? const _ScrollableMessage(
                      icon: null,
                      text: null,
                      loading: true,
                    )
                  : space == null
                  ? _ScrollableMessage(
                      icon: Icons.space_dashboard_outlined,
                      text: l10n.spaceUnavailable,
                    )
                  : space.tabs.isEmpty
                  ? _ScrollableMessage(
                      icon: Icons.space_dashboard_outlined,
                      text: l10n.spaceEmpty,
                    )
                  : ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: contentPanePadding(
                        context,
                        const EdgeInsets.fromLTRB(12, 8, 12, 24),
                      ),
                      children: [
                        for (final tab in space.tabs)
                          _WindowSection(bridgeId: bridgeId, spaceTab: tab),
                        const SizedBox(height: 8),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowSection extends StatelessWidget {
  const _WindowSection({required this.bridgeId, required this.spaceTab});

  final String bridgeId;
  final SpaceTab spaceTab;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
            child: Row(
              children: [
                Icon(Icons.tab_unselected, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    spaceWindowTitle(l10n, spaceTab.tab),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                if (spaceTab.tab.focused) ...[
                  const SizedBox(width: 8),
                  _Badge(label: l10n.spaceFocused, color: scheme.primary),
                ],
                const Spacer(),
                Text(
                  l10n.spaceWindowPaneCount(spaceTab.panes.length),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
          if (spaceTab.panes.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                l10n.spaceNoPanes,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            )
          else
            for (final pane in spaceTab.panes)
              _PaneCard(bridgeId: bridgeId, pane: pane),
        ],
      ),
    );
  }
}

class _PaneCard extends StatelessWidget {
  const _PaneCard({required this.bridgeId, required this.pane});

  final String bridgeId;
  final PaneInfo pane;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final shell = pane.isShell;
    final location = [
      if (pane.cwd.trim().isNotEmpty) pane.cwd,
      shell ? l10n.shellPane : pane.agent,
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: shell
            ? Icon(Icons.terminal, size: 18, color: scheme.outline)
            : Icon(
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
            if (pane.focused) ...[
              const SizedBox(width: 4),
              Icon(Icons.my_location, size: 14, color: scheme.primary),
            ],
          ],
        ),
        subtitle: Text(location, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: shell
            ? _Badge(label: l10n.shellPane, color: scheme.outline)
            : _Badge(
                label: statusLabel(l10n, pane.status),
                color: statusColor(scheme, pane.status),
              ),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) =>
                  AgentScreen(bridgeId: bridgeId, paneId: pane.paneId),
            ),
          );
        },
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: error ? scheme.errorContainer : scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

class _ScrollableMessage extends StatelessWidget {
  const _ScrollableMessage({
    required this.icon,
    required this.text,
    this.loading = false,
  });

  final IconData? icon;
  final String? text;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: contentPanePadding(context, const EdgeInsets.all(32)),
      children: [
        const SizedBox(height: 96),
        if (loading)
          const Center(child: CircularProgressIndicator())
        else if (icon != null)
          Icon(icon, size: 48, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        if (text != null)
          Text(
            text!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
      ],
    );
  }
}
