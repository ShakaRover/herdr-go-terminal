import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/bridge_api.dart';
import '../../model/history.dart';
import '../../state/bridges.dart';
import '../../state/snapshot.dart';

/// 对话历史页：从 agent 自己的会话日志分页读取（非终端滚屏）。
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen(
      {super.key,
      required this.bridgeId,
      required this.paneId,
      required this.title});

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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _preserveViewport(double oldPixels, double oldMaxExtent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      final addedExtent = position.maxScrollExtent - oldMaxExtent;
      final target = (oldPixels + addedExtent)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      _scrollController.jumpTo(target);
    });
  }

  Future<void> _loadOlder() async {
    if (_loading) return;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null) return;
    final initialLoad = _entries.isEmpty;
    final oldPixels = _scrollController.hasClients
        ? _scrollController.position.pixels
        : null;
    final oldMaxExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : null;
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
              fileTruncated: final fileTruncated
            ):
            _entries.insertAll(0, entries);
            _hasMore = hasMore;
            _fileTruncated = fileTruncated;
        }
      });
      if (initialLoad) {
        _scrollToBottom();
      } else if (oldPixels != null && oldMaxExtent != null) {
        _preserveViewport(oldPixels, oldMaxExtent);
      }
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
      appBar: AppBar(title: Text('历史 · ${widget.title}')),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_unavailableReason != null) {
      final text = switch (_unavailableReason!) {
        'disabled' => 'bridge 关闭了历史功能（COLLIE_TRANSCRIPT）',
        'no-session' => '这个 agent 没有会话日志',
        'no-log' => '找不到该会话的日志文件',
        final r => '历史不可用：$r',
      };
      return Center(child: Text(text, style: theme.textTheme.bodyMedium));
    }
    if (_entries.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_entries.isEmpty && _error != null) {
      return Center(child: Text('加载失败：$_error'));
    }
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.all(12),
      children: [
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
            label: Text(_loading ? '加载中…' : '加载更早'),
          ),
        if (_fileTruncated)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('日志过大，只解析了尾部',
                style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('加载失败：$_error',
                style: TextStyle(color: theme.colorScheme.error)),
          ),
        for (final e in _entries) _EntryCard(entry: e),
      ],
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({required this.entry});

  final TranscriptEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (entry.role) {
      TranscriptRole.user => ('你', Colors.tealAccent),
      TranscriptRole.assistant => ('agent', Colors.lightBlueAccent),
      TranscriptRole.summary => ('摘要', Colors.amberAccent),
      TranscriptRole.note => ('系统', theme.colorScheme.outline),
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
                Text(label,
                    style: theme.textTheme.labelMedium?.copyWith(color: color)),
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
      TextPart(:final text) => SelectableText(text,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.4)),
      ThinkingPart(:final text) => text.isEmpty
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
              Text('🔧 $name · $summary',
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
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
