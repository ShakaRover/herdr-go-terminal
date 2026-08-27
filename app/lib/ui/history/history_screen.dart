import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/bridge_api.dart';
import '../../l10n/l10n.dart';
import '../../model/history.dart';
import '../../state/bridges.dart';
import '../../state/snapshot.dart';
import '../content_pane.dart';

/// 对话历史页：从 agent 自己的会话日志分页读取（非终端滚屏）。
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({
    super.key,
    required this.bridgeId,
    required this.paneId,
    required this.title,
  });

  final String bridgeId;
  final String paneId;
  final String title;

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final List<TranscriptEntry> _entries = [];
  final _scrollController = ScrollController();
  bool _hasMore = false;
  bool _fileTruncated = false;
  bool _loading = false;
  String? _unavailableReason;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadOlder();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadOlder() async {
    if (_loading) return;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await api.fetchHistory(
        widget.paneId,
        before: _entries.isEmpty ? null : _entries.first.uuid,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      setState(() {
        switch (page) {
          case HistoryUnavailable(:final reason):
            _unavailableReason = reason;
          case HistoryPage(
            entries: final entries,
            hasMore: final hasMore,
            fileTruncated: final fileTruncated,
          ):
            _entries.insertAll(0, entries);
            _hasMore = hasMore;
            _fileTruncated = fileTruncated;
        }
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.historyTitle(widget.title))),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final l10n = context.l10n;
    if (_unavailableReason != null) {
      final text = switch (_unavailableReason!) {
        'disabled' => l10n.historyDisabled,
        'no-session' => l10n.historyNoSession,
        'no-log' => l10n.historyNoLog,
        final r => l10n.historyUnavailable(r),
      };
      return Center(child: Text(text, style: theme.textTheme.bodyMedium));
    }
    if (_entries.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty && _error != null) {
      return Center(child: Text(l10n.loadFailed('$_error')));
    }
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      interactive: true,
      child: ListView(
        controller: _scrollController,
        reverse: true,
        padding: contentPanePadding(context, const EdgeInsets.all(12)),
        children: [
          // reverse 列表以 offset 0 锚定底部；数据也反向渲染后，视觉顺序仍是
          // 旧消息在上、最新消息在下。加载更早时，新 child 只追加到顶部，
          // Flutter 会自然保持当前消息的位置，不再依赖帧后的 jumpTo。
          for (final e in _entries.reversed) _EntryCard(entry: e),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.loadFailed('$_error'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          if (_fileTruncated)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.historyTruncated,
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          if (_hasMore)
            TextButton.icon(
              onPressed: _loading ? null : _loadOlder,
              icon: _loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.history, size: 18),
              label: Text(_loading ? l10n.loading : l10n.loadOlder),
            ),
        ],
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final (label, color) = switch (entry.role) {
      TranscriptRole.user => (l10n.roleYou, Colors.tealAccent),
      TranscriptRole.assistant => (l10n.roleAgent, Colors.lightBlueAccent),
      TranscriptRole.summary => (l10n.roleSummary, Colors.amberAccent),
      TranscriptRole.note => (l10n.roleSystem, theme.colorScheme.outline),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: color),
                ),
                const SizedBox(width: 8),
                if (entry.ts.isNotEmpty)
                  Text(_shortTs(entry.ts), style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 6),
            for (final part in entry.parts) _PartView(part: part),
          ],
        ),
      ),
    );
  }

  String _shortTs(String iso) {
    // "2026-08-13T07:12:34.567Z" → "08-13 07:12"
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _PartView extends StatelessWidget {
  const _PartView({required this.part});

  final TranscriptPart part;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return switch (part) {
      TextPart(:final text) => SelectableText(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
      ),
      ThinkingPart(:final text) =>
        text.isEmpty
            ? const SizedBox.shrink()
            : SelectableText(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.outline,
                  height: 1.4,
                ),
              ),
      ToolPart(:final name, :final summary, :final result) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '🔧 $name · $summary',
              style: theme.textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (result != null && result.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  result.text,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: result.isError
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                ),
              ),
          ],
        ),
      ),
    };
  }
}
