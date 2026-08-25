import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../ansi/ansi.dart';
import '../../api/bridge_api.dart';
import '../../blocks/prompt_action.dart';
import '../../blocks/prompt_model.dart';
import '../../blocks/prompt_select.dart';
import '../../l10n/l10n.dart';
import '../../state/bridges.dart';
import '../../state/pane_read.dart';
import '../../state/settings.dart';
import '../../state/snapshot.dart';
import '../history/history_screen.dart';
import '../status_style.dart';
import 'ansi_span.dart';
import 'rename_pane_dialog.dart';

typedef _TerminalGridSize = ({int cols, int rows});

const _mirrorPadding = EdgeInsets.fromLTRB(12, 12, 12, 16);

_TerminalGridSize _terminalGridSize(
  BuildContext context,
  BoxConstraints constraints,
) {
  final painter = TextPainter(
    text: TextSpan(
      text: 'M',
      style: segmentStyle(const AnsiSegment(text: 'M')),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final usableWidth = constraints.maxWidth - _mirrorPadding.horizontal;
  final usableHeight = constraints.maxHeight - _mirrorPadding.vertical;
  final cols = (usableWidth / painter.width).floor().clamp(20, 300).toInt();
  final rows = (usableHeight / painter.preferredLineHeight)
      .floor()
      .clamp(5, 200)
      .toInt();
  return (cols: cols, rows: rows);
}

/// agent 详情：输出镜像 + 回复框 + 特殊按键条。
class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key, required this.bridgeId, required this.paneId});

  final String bridgeId;
  final String paneId;

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _scrollController = ScrollController();
  final _replyController = TextEditingController();

  /// 用户停留在底部时，新内容到达自动跟随；上翻后不再抢滚动条。
  bool _stickToBottom = true;
  bool _sending = false;
  bool _resizeInFlight = false;
  int? _lastResizeCols;
  _TerminalGridSize? _pendingResize;

  /// 最近一次 build 时识别到的尾部对话框（供回复发送前的误批准拦截）。
  PromptRegion? _lastPromptRegion;

  static const _keys = [
    (label: 'Esc', keys: ['Escape']),
    (label: 'Ctrl+C', keys: ['ctrl+c']),
    (label: '↑', keys: ['Up']),
    (label: '↓', keys: ['Down']),
    (label: '←', keys: ['Left']),
    (label: '→', keys: ['Right']),
    (label: 'Tab', keys: ['Tab']),
    (label: '⇧Tab', keys: ['shift+tab']),
    (label: 'Enter', keys: ['Enter']),
  ];

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      final atBottom = pos.maxScrollExtent - pos.pixels < 48;
      if (atBottom != _stickToBottom) {
        _stickToBottom = atBottom;
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _replyController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _scheduleTerminalResize(
    BuildContext context,
    BoxConstraints constraints, {
    required bool enabled,
  }) {
    if (!enabled) {
      _pendingResize = null;
      _lastResizeCols = null;
      return;
    }
    final size = _terminalGridSize(context, constraints);
    if (_lastResizeCols == size.cols || _pendingResize?.cols == size.cols) {
      return;
    }
    _pendingResize = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyPendingResize());
  }

  Future<void> _applyPendingResize() async {
    if (!mounted || _resizeInFlight) return;
    if (!ref.read(terminalAutoResizeProvider)) {
      _pendingResize = null;
      return;
    }
    final size = _pendingResize;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (size == null) return;
    if (api == null) {
      _pendingResize = null;
      return;
    }
    _pendingResize = null;
    _lastResizeCols = size.cols;
    _resizeInFlight = true;
    try {
      await api.resizePane(
        widget.paneId,
        cols: size.cols,
        rows: size.rows,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (mounted) {
        await ref
            .read(
              paneReadProvider((
                bridgeId: widget.bridgeId,
                paneId: widget.paneId,
              )).notifier,
            )
            .refresh();
      }
    } on ApiException {
      // Automatic sizing is best-effort; the original-width mirror remains usable.
    } finally {
      _resizeInFlight = false;
      if (_pendingResize != null) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _applyPendingResize(),
        );
      }
    }
  }

  Future<void> _sendReply() async {
    final l10n = context.l10n;
    // 发送前 trim（对齐 collie composer）：尾随换行会变成额外的 Enter 打进 PTY。
    final text = _replyController.text.trim();
    if (text.isEmpty || _sending) return;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null) return;
    // 屏幕上有对话框时，reply 路径是「打字 + 盲发 Enter」——回车可能批准
    // 对话框高亮的默认选项（collie issue #34 类事故）。先确认；
    // 自由文本逃生行（"Type something."）仍可经「仍发送」打字回答。
    if (_lastPromptRegion != null && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.pendingDialogTitle),
          content: Text(ctx.l10n.pendingDialogBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.sendAnyway),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
    setState(() => _sending = true);
    try {
      final res = await api.sendReply(
        widget.paneId,
        text,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (res.success) {
        _replyController.clear();
        _toast(l10n.sent);
      } else if (res.promptChanged) {
        _toast(l10n.screenChangedRetry);
      } else if (res.textDelivered) {
        _toast(l10n.textDeliveredWarning);
      } else {
        _toast(l10n.sendFailed(res.error ?? l10n.unknownError));
      }
      await _refreshAll();
    } on ApiException catch (e) {
      _toast(l10n.sendFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendKeys(List<String> keys) async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _sending) return;
    setState(() => _sending = true);
    try {
      final res = await api.sendKeys(
        widget.paneId,
        keys,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (!res.success) {
        _toast(
          res.promptChanged
              ? l10n.screenChangedShort
              : l10n.keyFailed(res.error ?? l10n.unknownError),
        );
      }
      await _refreshAll();
    } on ApiException catch (e) {
      _toast(l10n.keyFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 点按对话框按钮走共用防护链 helper（对齐 collie dialog-guard 的
  /// prompt-select 路径）：新鲜读取 → 重新派生模型 → 结构相等校验 →
  /// 带 expectedPrompt 发键。这里只把结果映射成 toast 并触发刷新。
  Future<void> _tapPromptOption(PromptModel tapped, PromptOption opt) async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _sending) return;
    final session = ref.read(sessionFilterProvider(widget.bridgeId));
    setState(() => _sending = true);
    try {
      final result = await tapPromptOption(
        api: api,
        paneId: widget.paneId,
        session: session,
        tapped: tapped,
        opt: opt,
      );
      if (!mounted) return;
      switch (result.outcome) {
        case PromptTapOutcome.sent:
          _toast(l10n.sent);
        case PromptTapOutcome.changed:
          _toast(l10n.screenChangedRetry);
        case PromptTapOutcome.failed:
          _toast(l10n.sendFailed(result.error ?? l10n.unknownError));
      }
      // failed（含 readPane 抛 ApiException）不刷新，与现状一致。
      if (result.outcome != PromptTapOutcome.failed) {
        await _refreshAll();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _refreshAll() async {
    await ref
        .read(
          paneReadProvider((bridgeId: widget.bridgeId, paneId: widget.paneId))
              .notifier,
        )
        .refresh();
    await ref.read(bridgeSnapshotProvider(widget.bridgeId).notifier).refresh();
  }

  /// 相册选图 → 上传到宿主机 → 返回的路径插进回复框（agent 按路径读图）。
  Future<void> _pickAndUpload() async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _sending) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
    );
    if (picked == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final res = await api.uploadImage(
        widget.paneId,
        picked.path,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (res.success && res.path != null) {
        final current = _replyController.text;
        final path = res.path!;
        _replyController.text = current.isEmpty ? path : '$current $path';
        _toast(l10n.imageUploaded);
      } else {
        _toast(l10n.uploadFailed(res.error ?? l10n.unknownError));
      }
    } on ApiException catch (e) {
      _toast(l10n.uploadFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 重命名 agent：调 herdr pane.rename，AppBar 标题随下一次快照轮询刷新。
  Future<void> _rename() async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    final pane = ref
        .read(bridgeSnapshotProvider(widget.bridgeId))
        .data
        ?.agents
        .where((p) => p.paneId == widget.paneId)
        .firstOrNull;
    if (api == null || pane == null || _sending) return;
    final label = await showRenamePaneDialog(context, pane);
    if (label == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final res = await api.renamePane(
        widget.paneId,
        label,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      _toast(
        res.success
            ? (label.isEmpty ? l10n.aliasCleared : l10n.renamed)
            : (res.error ?? l10n.renameFailedShort),
      );
      if (res.success) await _refreshAll();
    } on ApiException catch (e) {
      _toast(l10n.renameFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final paneKey = (bridgeId: widget.bridgeId, paneId: widget.paneId);
    final readState = ref.watch(paneReadProvider(paneKey));
    final snapshotState = ref.watch(bridgeSnapshotProvider(widget.bridgeId));
    final snap = snapshotState.data;
    final pane = snap?.agents
        .where((p) => p.paneId == widget.paneId)
        .firstOrNull;
    final readOnly = snap?.readOnly ?? false;
    final terminalAutoResize = ref.watch(terminalAutoResizeProvider);

    // 新内容到达且用户在底部 → 跟随。
    ref.listen(paneReadProvider(paneKey), (prev, next) {
      if (_stickToBottom && next.data != prev?.data) _scrollToBottom();
    });

    final text = readState.data?.text ?? '';
    final lines = splitLines(parseAnsi(text));
    // 尾部对话框识别：命中则菜单区域换成原生按钮（问题与前言保持原文）。
    final promptRegion = text.isEmpty ? null : detectPromptSelectRegion(lines);
    _lastPromptRegion = promptRegion;
    final mirrorLines = promptRegion != null
        ? trimTrailingBlank(lines.sublist(0, promptRegion.startLine))
        : trimTrailingBlank(lines);

    return Scaffold(
      backgroundColor: mirrorBackground,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pane?.displayName ?? widget.paneId,
              style: const TextStyle(fontSize: 16),
            ),
            if (pane != null)
              Text(
                '${pane.workspaceLabel} · ${pane.agent}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          if (pane != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                label: Text(statusLabel(l10n, pane.status)),
                visualDensity: VisualDensity.compact,
                side: BorderSide.none,
                backgroundColor: statusColor(
                  Theme.of(context).colorScheme,
                  pane.status,
                ).withValues(alpha: 0.15),
              ),
            ),
          IconButton(
            tooltip: l10n.refreshTooltip,
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAll,
          ),
          if (pane != null && !readOnly)
            IconButton(
              tooltip: l10n.renameTooltip,
              icon: const Icon(Icons.edit_outlined),
              onPressed: _sending ? null : _rename,
            ),
          if (pane?.hasSession == true)
            IconButton(
              tooltip: l10n.historyTooltip,
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => HistoryScreen(
                    bridgeId: widget.bridgeId,
                    paneId: widget.paneId,
                    title: pane?.displayName ?? widget.paneId,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (readOnly)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                l10n.readOnlyMode,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (readState.error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                l10n.outputRefreshFailed('${readState.error}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                _scheduleTerminalResize(
                  context,
                  constraints,
                  enabled: terminalAutoResize && pane != null && !readOnly,
                );
                return text.isEmpty && readState.error == null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              l10n.readingOutput,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      )
                    : SingleChildScrollView(
                        controller: _scrollController,
                        padding: _mirrorPadding,
                        child: SizedBox(
                          width: double.infinity,
                          child: SelectableText.rich(
                            TextSpan(children: [linesToSpan(mirrorLines)]),
                          ),
                        ),
                      );
              },
            ),
          ),
          if (!readOnly && promptRegion != null)
            _PromptCard(
              model: promptRegion.model,
              enabled: !_sending,
              onTap: (opt) => _tapPromptOption(promptRegion.model, opt),
            ),
          if (!readOnly) ...[const Divider(height: 1), _buildComposer(context)],
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              // 不加纵向 padding：水平 ListView 会把交叉轴紧约束传给子项，
              // padding 会把 chip 的 48dp 触摸目标钳小。
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _keys.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final k = _keys[i];
                return ActionChip(
                  label: Text(k.label),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onPressed: _sending ? null : () => _sendKeys(k.keys),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: context.l10n.sendImageTooltip,
                  icon: const Icon(Icons.image_outlined),
                  onPressed: _sending ? null : _pickAndUpload,
                ),
                Expanded(
                  child: TextField(
                    controller: _replyController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: context.l10n.replyHint,
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _sendReply,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 识别出的单选对话框卡片：选项按钮。问题与前言保留在上方镜像区原文，
/// 卡片不再重复显示问题文本。
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.model,
    required this.enabled,
    required this.onTap,
  });

  final PromptModel model;
  final bool enabled;
  final ValueChanged<PromptOption> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final opt in model.options)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: enabled ? () => onTap(opt) : null,
                  style: FilledButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(opt.label),
                      if (opt.description != null)
                        Text(
                          opt.description!,
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
