/// 长按弹出的 agent 预览卡：最近一屏 ANSI + 状态 + 上下文按钮/通用动作 +
/// pin + 打开详情。底部操作区对同一份 lines 跑 `detectPromptSelect`：
/// 识别出对话框则渲染选项按钮（走 Task 1 的防护链发键），否则给通用动作。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ansi/ansi.dart';
import '../../api/bridge_api.dart';
import '../../blocks/prompt_action.dart';
import '../../blocks/prompt_model.dart';
import '../../blocks/prompt_select.dart';
import '../../l10n/l10n.dart';
import '../../model/models.dart';
import '../../state/bridges.dart';
import '../../state/pinned.dart';
import '../../state/snapshot.dart';
import '../agent/agent_screen.dart';
import '../agent/ansi_span.dart';
import '../agent/rename_pane_dialog.dart';
import '../status_style.dart';

/// 长按弹出的预览卡：最近一屏 ANSI + 状态 + 上下文按钮/通用动作 + pin +
/// 打开详情。
class AgentPreviewSheet extends ConsumerStatefulWidget {
  const AgentPreviewSheet({
    super.key,
    required this.bridgeId,
    required this.pane,
    required this.pinned,
  });

  final String bridgeId;
  final PaneInfo pane;

  /// 弹出时是否已置顶（pin 图标与 SnackBar 文案据此取反）。
  final bool pinned;

  /// 便捷静态方法：showModalBottomSheet 弹出。
  static Future<void> show(
    BuildContext context, {
    required String bridgeId,
    required PaneInfo pane,
    required bool pinned,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        AgentPreviewSheet(bridgeId: bridgeId, pane: pane, pinned: pinned),
  );

  @override
  ConsumerState<AgentPreviewSheet> createState() => _AgentPreviewSheetState();
}

class _AgentPreviewSheetState extends ConsumerState<AgentPreviewSheet> {
  /// 当前展示的最近 30 行；changed 后重新拉取时换掉 future。
  Future<List<StyledLine>>? _future;
  final _scrollController = ScrollController();
  bool _scrollPending = false;
  bool _initialized = false;

  /// 识别出的对话框（null = 未识别 → 通用动作行）。
  PromptModel? _model;

  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _reload();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottomAfterBuild() {
    if (!_scrollPending) return;
    _scrollPending = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _reload() {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    final session = ref.read(sessionFilterProvider(widget.bridgeId));
    setState(() {
      _scrollPending = true;
      _future = api == null
          ? Future.error(ApiException(l10n.bridgeNotConfigured))
          : api.readPane(widget.pane.paneId, lines: 30, session: session).then((
              read,
            ) {
              final lines = splitLines(parseAnsi(read.text));
              _model = detectPromptSelect(lines);
              return lines;
            });
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 上下文按钮：点选项走防护链（新鲜读取 → 结构相等 → 带 expectedPrompt 发键）。
  Future<void> _tapOption(PromptOption opt) async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    final model = _model;
    if (api == null || model == null || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await tapPromptOption(
        api: api,
        paneId: widget.pane.paneId,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
        tapped: model,
        opt: opt,
      );
      if (!mounted) return;
      switch (res.outcome) {
        case PromptTapOutcome.sent:
          Navigator.of(context).pop();
          _toast(l10n.sent);
        case PromptTapOutcome.changed:
          _toast(l10n.screenChangedOpenDetails);
          _reload();
        case PromptTapOutcome.failed:
          _toast(res.error ?? l10n.sendFailed(l10n.unknownError));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 通用动作：盲发按键（不带 expectedPrompt），成功关卡。
  Future<void> _tapGeneric(List<String> keys) async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await api.sendKeys(
        widget.pane.paneId,
        keys,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (res.success) {
        Navigator.of(context).pop();
      } else {
        _toast(res.error ?? l10n.sendFailed(l10n.unknownError));
      }
    } on ApiException catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openDetail() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            AgentScreen(bridgeId: widget.bridgeId, paneId: widget.pane.paneId),
      ),
    );
  }

  /// 对齐 dashboard 的 _togglePinned：toggle + SnackBar。
  Future<void> _togglePinned() async {
    final l10n = context.l10n;
    final session = ref.read(sessionFilterProvider(widget.bridgeId));
    await ref
        .read(pinnedPanesProvider.notifier)
        .toggle(widget.bridgeId, session, widget.pane.paneId);
    if (mounted) _toast(widget.pinned ? l10n.unpinned : l10n.pinned);
  }

  /// 重命名 agent：调 herdr pane.rename，显示名随下一次快照轮询刷新。
  Future<void> _rename() async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _busy) return;
    final label = await showRenamePaneDialog(context, widget.pane);
    if (label == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final res = await api.renamePane(
        widget.pane.paneId,
        label,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (res.success) {
        _toast(label.isEmpty ? l10n.aliasCleared : l10n.renamed);
      } else {
        _toast(res.error ?? l10n.renameFailedShort);
      }
    } on ApiException catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final pane = widget.pane;
    final readOnly =
        ref.watch(
          bridgeSnapshotProvider(widget.bridgeId)
              .select((s) => s.data?.readOnly),
        ) ??
        false;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 12,
                  color: statusColor(scheme, pane.status),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    pane.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text(statusLabel(l10n, pane.status)),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                  backgroundColor: statusColor(
                    scheme,
                    pane.status,
                  ).withValues(alpha: 0.15),
                ),
                IconButton(
                  tooltip: widget.pinned ? l10n.unpinTooltip : l10n.pinTooltip,
                  icon: Icon(
                    widget.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                  onPressed: _togglePinned,
                ),
                IconButton(
                  tooltip: readOnly
                      ? l10n.readOnlyCannotRename
                      : l10n.renameTooltip,
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: readOnly || _busy ? null : _rename,
                ),
                TextButton(
                  onPressed: _openDetail,
                  child: Text(l10n.openDetails),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: FutureBuilder<List<StyledLine>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(
                        child: Text(l10n.readFailed('${snap.error}')),
                      );
                    }
                    if (!snap.hasData) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(32),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    _scrollToBottomAfterBuild();
                    return Container(
                      width: double.infinity,
                      color: mirrorBackground,
                      padding: const EdgeInsets.all(8),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: AnsiSpan(lines: snap.data!),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_future != null)
              FutureBuilder<List<StyledLine>>(
                future: _future,
                builder: (context, snap) {
                  if (!snap.hasData || _model == null) {
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final a in [
                          (label: l10n.continueEnter, keys: ['Enter']),
                          (label: 'Ctrl+C', keys: ['ctrl+c']),
                          (label: '↑', keys: ['Up']),
                          (label: '↓', keys: ['Down']),
                        ])
                          OutlinedButton(
                            onPressed: snap.hasData && !_busy
                                ? () => _tapGeneric(a.keys)
                                : null,
                            child: Text(a.label),
                          ),
                      ],
                    );
                  }
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final opt in _model!.options)
                        ElevatedButton(
                          onPressed: _busy ? null : () => _tapOption(opt),
                          child: Text(opt.label),
                        ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
