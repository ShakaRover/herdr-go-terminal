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
import '../../model/models.dart';
import '../../state/pinned.dart';
import '../../state/settings.dart';
import '../../state/snapshot.dart';
import '../agent/agent_screen.dart';
import '../agent/ansi_span.dart';
import 'dashboard_screen.dart';

/// 长按弹出的预览卡：最近一屏 ANSI + 状态 + 上下文按钮/通用动作 + pin +
/// 打开详情。
class AgentPreviewSheet extends ConsumerStatefulWidget {
  const AgentPreviewSheet({super.key, required this.pane, required this.pinned});

  final PaneInfo pane;

  /// 弹出时是否已置顶（pin 图标与 SnackBar 文案据此取反）。
  final bool pinned;

  /// 便捷静态方法：showModalBottomSheet 弹出。
  static Future<void> show(
    BuildContext context, {
    required PaneInfo pane,
    required bool pinned,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => AgentPreviewSheet(pane: pane, pinned: pinned),
      );

  @override
  ConsumerState<AgentPreviewSheet> createState() => _AgentPreviewSheetState();
}

class _AgentPreviewSheetState extends ConsumerState<AgentPreviewSheet> {
  /// 当前展示的最近 30 行；changed 后重新拉取时换掉 future。
  Future<List<StyledLine>>? _future;

  /// 识别出的对话框（null = 未识别 → 通用动作行）。
  PromptModel? _model;

  bool _busy = false;

  static const _genericActions = [
    (label: '继续 (Enter)', keys: ['Enter']),
    (label: 'Ctrl+C', keys: ['ctrl+c']),
    (label: '↑', keys: ['Up']),
    (label: '↓', keys: ['Down']),
  ];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    final api = ref.read(apiProvider);
    final session = ref.read(sessionFilterProvider);
    setState(() {
      _future = api == null
          ? Future.error(const ApiException('未配置 bridge 连接'))
          : api
              .readPane(widget.pane.paneId, lines: 30, session: session)
              .then((read) {
              final lines = splitLines(parseAnsi(read.text));
              _model = detectPromptSelect(lines);
              return lines;
            });
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
  }

  /// 上下文按钮：点选项走防护链（新鲜读取 → 结构相等 → 带 expectedPrompt 发键）。
  Future<void> _tapOption(PromptOption opt) async {
    final api = ref.read(apiProvider);
    final model = _model;
    if (api == null || model == null || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await tapPromptOption(
        api: api,
        paneId: widget.pane.paneId,
        session: ref.read(sessionFilterProvider),
        tapped: model,
        opt: opt,
      );
      if (!mounted) return;
      switch (res.outcome) {
        case PromptTapOutcome.sent:
          Navigator.of(context).pop();
          _toast('已发送');
        case PromptTapOutcome.changed:
          _toast('界面已变化，请打开详情确认');
          _reload();
        case PromptTapOutcome.failed:
          _toast(res.error ?? '发送失败');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 通用动作：盲发按键（不带 expectedPrompt），成功关卡。
  Future<void> _tapGeneric(List<String> keys) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    setState(() => _busy = true);
    try {
      final res = await api.sendKeys(widget.pane.paneId, keys,
          session: ref.read(sessionFilterProvider));
      if (!mounted) return;
      if (res.success) {
        Navigator.of(context).pop();
      } else {
        _toast(res.error ?? '发送失败');
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
      MaterialPageRoute(builder: (_) => AgentScreen(paneId: widget.pane.paneId)),
    );
  }

  /// 对齐 dashboard 的 _togglePinned：toggle + SnackBar。
  Future<void> _togglePinned() async {
    final session = ref.read(sessionFilterProvider);
    await ref
        .read(pinnedPanesProvider.notifier)
        .toggle(session, widget.pane.paneId);
    if (mounted) _toast(widget.pinned ? '已取消置顶' : '已置顶');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pane = widget.pane;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.circle,
                    size: 12, color: statusColor(scheme, pane.status)),
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
                  label: Text(statusLabel(pane.status)),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide.none,
                  backgroundColor:
                      statusColor(scheme, pane.status).withValues(alpha: 0.15),
                ),
                IconButton(
                  tooltip: widget.pinned ? '取消置顶' : '置顶',
                  icon: Icon(widget.pinned
                      ? Icons.push_pin
                      : Icons.push_pin_outlined),
                  onPressed: _togglePinned,
                ),
                TextButton(
                  onPressed: _openDetail,
                  child: const Text('打开详情'),
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
                      return Center(child: Text('读取失败：${snap.error}'));
                    }
                    if (!snap.hasData) {
                      return const Center(
                          child: Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator(),
                      ));
                    }
                    return Container(
                      width: double.infinity,
                      color: mirrorBackground,
                      padding: const EdgeInsets.all(8),
                      child: SingleChildScrollView(
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
                        for (final a in _genericActions)
                          OutlinedButton(
                            onPressed:
                                snap.hasData && !_busy ? () => _tapGeneric(a.keys) : null,
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
