/// 相对时间格式化。
library;

import '../l10n/generated/app_localizations.dart';

String relativeTime(
  int? epochMs,
  DateTime now,
  AppLocalizations localizations,
) {
  if (epochMs == null || epochMs <= 0) return '';
  final diff = now.millisecondsSinceEpoch - epochMs;
  if (diff < 0) return '';
  if (diff < 60 * 1000) return localizations.relativeJustNow;
  if (diff < 60 * 60 * 1000) {
    return localizations.relativeMinutesAgo(diff ~/ 60000);
  }
  if (diff < 24 * 60 * 60 * 1000) {
    return localizations.relativeHoursAgo(diff ~/ 3600000);
  }
  return localizations.relativeDaysAgo(diff ~/ 86400000);
}
