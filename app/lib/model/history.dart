/// 对话历史（journal）模型 —— 对齐 collie `bridge/journal/types.ts`。
///
/// 历史不是终端滚屏：agent 的 TUI 跑在 alternate screen 上没有滚屏环，
/// 完整对话只能从 agent 自己的会话日志读取（bridge 的 per-harness 适配器）。
library;

String _hs(Map<String, dynamic> j, String k, [String d = '']) =>
    j[k] is String ? j[k] as String : d;

// ---------------------------------------------------------------------------
// TranscriptPart
// ---------------------------------------------------------------------------

sealed class TranscriptPart {
  const TranscriptPart();
}

class TextPart extends TranscriptPart {
  const TextPart(this.text, {this.truncated = false});
  final String text;
  final bool truncated;
}

/// 思考/推理文本（Claude 持久化为空，Codex/pi 有真实摘要）。
class ThinkingPart extends TranscriptPart {
  const ThinkingPart(this.text, {this.truncated = false});
  final String text;
  final bool truncated;
}

class ToolResult {
  const ToolResult(this.text, {this.truncated = false, this.isError = false});
  final String text;
  final bool truncated;
  final bool isError;
}

class ToolPart extends TranscriptPart {
  const ToolPart({required this.name, required this.summary, this.result});
  final String name;

  /// 调用的一句话摘要（读了哪个文件、跑了哪条命令），永远不是完整输入。
  final String summary;
  final ToolResult? result;
}

TranscriptPart _partFromJson(Map<String, dynamic> j) {
  final kind = _hs(j, 'kind');
  switch (kind) {
    case 'thinking':
      return ThinkingPart(_hs(j, 'text'),
          truncated: j['truncated'] == true);
    case 'tool':
      final r = j['result'];
      return ToolPart(
        name: _hs(j, 'name', '?'),
        summary: _hs(j, 'summary'),
        result: r is Map<String, dynamic>
            ? ToolResult(_hs(r, 'text'),
                truncated: r['truncated'] == true,
                isError: r['isError'] == true)
            : null,
      );
    case 'text':
    default:
      // 未知 part 类型按纯文本兜底（宽容解析）。
      return TextPart(_hs(j, 'text'), truncated: j['truncated'] == true);
  }
}

// ---------------------------------------------------------------------------
// TranscriptEntry
// ---------------------------------------------------------------------------

enum TranscriptRole { user, assistant, summary, note }

TranscriptRole _roleFrom(String raw) => switch (raw) {
      'user' => TranscriptRole.user,
      'assistant' => TranscriptRole.assistant,
      'summary' => TranscriptRole.summary,
      _ => TranscriptRole.note,
    };

class TranscriptEntry {
  const TranscriptEntry({
    required this.uuid,
    required this.ts,
    required this.role,
    required this.parts,
  });

  /// 分页游标（?before=），对同一份日志的多次读取保持稳定。
  final String uuid;

  /// 日志里的 ISO 时间戳；没有则为空串。
  final String ts;
  final TranscriptRole role;
  final List<TranscriptPart> parts;

  factory TranscriptEntry.fromJson(Map<String, dynamic> j) => TranscriptEntry(
        uuid: _hs(j, 'uuid'),
        ts: _hs(j, 'ts'),
        role: _roleFrom(_hs(j, 'role')),
        parts: j['parts'] is List
            ? (j['parts'] as List)
                .whereType<Map<String, dynamic>>()
                .map(_partFromJson)
                .toList()
            : const [],
      );
}

// ---------------------------------------------------------------------------
// PaneHistoryResponse
// ---------------------------------------------------------------------------

sealed class PaneHistory {
  const PaneHistory();
}

/// reason: "disabled" | "no-session" | "no-log"。
class HistoryUnavailable extends PaneHistory {
  const HistoryUnavailable(this.reason);
  final String reason;
}

class HistoryPage extends PaneHistory {
  const HistoryPage({
    required this.entries,
    required this.hasMore,
    required this.total,
    required this.fileTruncated,
  });

  /// 最旧在前，自上而下直接渲染。
  final List<TranscriptEntry> entries;

  /// entries[0] 之前还有更早的回合 —— 用 ?before= 继续翻页。
  final bool hasMore;
  final int total;

  /// 日志超过读取上限，只解析了尾部。
  final bool fileTruncated;
}

PaneHistory paneHistoryFromJson(Map<String, dynamic> j) {
  if (j['available'] == true) {
    return HistoryPage(
      entries: j['entries'] is List
          ? (j['entries'] as List)
              .whereType<Map<String, dynamic>>()
              .map(TranscriptEntry.fromJson)
              .toList()
          : const [],
      hasMore: j['hasMore'] == true,
      total: j['total'] is num ? (j['total'] as num).toInt() : 0,
      fileTruncated: j['fileTruncated'] == true,
    );
  }
  return HistoryUnavailable(_hs(j, 'reason', 'unknown'));
}
