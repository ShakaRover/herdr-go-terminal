/// 相对时间格式化（不引 intl，够用就好）。
library;

String relativeTime(int? epochMs, DateTime now) {
  if (epochMs == null || epochMs <= 0) return '';
  final diff = now.millisecondsSinceEpoch - epochMs;
  if (diff < 0) return '';
  if (diff < 60 * 1000) return '刚刚';
  if (diff < 60 * 60 * 1000) return '${diff ~/ 60000} 分钟前';
  if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ 3600000} 小时前';
  return '${diff ~/ 86400000} 天前';
}
