import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../state/settings.dart';
import 'generated/app_localizations.dart';

extension AppLocalizationsContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this)!;
}

/// Resolve strings outside a widget tree (currently Android notifications).
/// Unsupported system locales intentionally fall back to English, matching
/// Flutter's locale resolution in [HerdrApp].
AppLocalizations appLocalizationsFor(AppLocalePreference preference) {
  final locale = preference.locale ?? PlatformDispatcher.instance.locale;
  final languageCode = locale.languageCode == 'zh' ? 'zh' : 'en';
  return lookupAppLocalizations(Locale(languageCode));
}
