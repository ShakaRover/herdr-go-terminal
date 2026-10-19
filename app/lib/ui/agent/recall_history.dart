import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/bridge_api.dart';
import '../../l10n/l10n.dart';
import '../../model/history.dart';
import '../../state/bridges.dart';
import '../../state/sent_history.dart';
import '../../state/snapshot.dart';

/// 从历史填入输入框：agent 合并 journal 的 user 消息 + 本机发送记录；
/// shell 只用本机发送记录（远端 shell 自己的历史仍可用长按方向键访问）。
class RecallHistorySheet extends ConsumerStatefulWidget {
  const RecallHistorySheet({
    super.key,
    required this.historyKey,
    required this.shell,
  });

  final SentHistoryKey historyKey;
  final bool shell;

  static Future<String?> show(
    BuildContext context, {
    required SentHistoryKey historyKey,
    required bool shell,
  }) => showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => RecallHistorySheet(historyKey: historyKey, shell: shell),
  );

  @override
  ConsumerState<RecallHistorySheet> createState() => _RecallHistorySheetState();
}

class _RecallHistorySheetState extends ConsumerState<RecallHistorySheet> {
  List<String> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final local = ref.read(sentHistoryProvider(widget.historyKey));
    final journal = <String>[];
    if (!widget.shell) {
      final api = ref.read(apiProvider(widget.historyKey.bridgeId));
      if (api != null) {
        try {
          final page = await api.fetchHistory(
            widget.historyKey.paneId,
            limit: 50,
            session: ref.read(
              sessionFilterProvider(widget.historyKey.bridgeId),
            ),
          );
          if (page is HistoryPage) {
            // entries 最旧在前；回填按最新优先。
            for (final entry in page.entries.reversed) {
              if (entry.role != TranscriptRole.user) continue;
              final text = entry.parts
                  .whereType<TextPart>()
                  .map((part) => part.text)
                  .join('\n')
                  .trim();
              if (text.isNotEmpty) journal.add(text);
            }
          }
        } on ApiException {
          // 历史不可用时仍展示本机发送记录。
        }
      }
    }
    final seen = <String>{};
    final merged = <String>[];
    for (final text in [...local, ...journal]) {
      if (seen.add(text)) merged.add(text);
    }
    if (!mounted) return;
    setState(() {
      _items = merged;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final title = widget.shell
        ? l10n.recallHistoryShellTitle
        : l10n.recallHistoryTitle;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                l10n.recallHistoryHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _items.isEmpty
                    ? Center(
                        child: Text(
                          l10n.recallHistoryEmpty,
                          style: theme.textTheme.bodyMedium,
                        ),
                      )
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (context, index) {
                          final text = _items[index];
                          return Card(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: ListTile(
                              title: Text(
                                text,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.north_west, size: 18),
                              onTap: () => Navigator.of(context).pop(text),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
