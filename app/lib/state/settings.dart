/// settings 层：shared_preferences 实例、profile 列表仓库、enabled profile
/// 列表的常驻视图。
///
/// 全 EasyTier 后连接配置只剩扫码 profile 一种，
/// 直填配置（DirectConfig / bridge_settings_v2）已删除——遗留的
/// bridge_settings_v1/v2 键检测到即删，不做迁移。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/easytier_channel.dart';
import '../model/remote_profile.dart';

/// 在 main 里用已初始化的实例 override。
final sharedPrefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError('sharedPrefsProvider 未 override'),
);

const appLocalePreferenceKey = 'app_locale_v1';
const terminalAutoResizePreferenceKey = 'terminal_auto_resize_v1';
const terminalFontSizePreferenceKey = 'terminal_font_size_v1';
const diagnosticLoggingPreferenceKey = 'easytier_diagnostic_logging_v1';
const terminalDefaultFontSize = 12.5;
const terminalMinFontSize = 9.5;
const terminalMaxFontSize = 16.0;

double normalizeTerminalFontSize(double value) {
  if (!value.isFinite) return terminalDefaultFontSize;
  final clamped = value.clamp(terminalMinFontSize, terminalMaxFontSize);
  return (clamped * 10).roundToDouble() / 10;
}

enum AppLocalePreference {
  system,
  simplifiedChinese,
  english;

  Locale? get locale => switch (this) {
    AppLocalePreference.system => null,
    AppLocalePreference.simplifiedChinese => const Locale('zh'),
    AppLocalePreference.english => const Locale('en'),
  };
}

class AppLocaleNotifier extends Notifier<AppLocalePreference> {
  @override
  AppLocalePreference build() {
    final stored = ref
        .watch(sharedPrefsProvider)
        .getString(appLocalePreferenceKey);
    return AppLocalePreference.values
            .where((value) => value.name == stored)
            .firstOrNull ??
        AppLocalePreference.system;
  }

  Future<void> select(AppLocalePreference preference) async {
    state = preference;
    await ref
        .read(sharedPrefsProvider)
        .setString(appLocalePreferenceKey, preference.name);
  }
}

final appLocaleProvider =
    NotifierProvider<AppLocaleNotifier, AppLocalePreference>(
      AppLocaleNotifier.new,
    );

class TerminalAutoResizeNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPrefsProvider).getBool(terminalAutoResizePreferenceKey) ??
      true;

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    await ref
        .read(sharedPrefsProvider)
        .setBool(terminalAutoResizePreferenceKey, enabled);
  }
}

final terminalAutoResizeProvider =
    NotifierProvider<TerminalAutoResizeNotifier, bool>(
      TerminalAutoResizeNotifier.new,
    );

class TerminalFontSizeNotifier extends Notifier<double> {
  @override
  double build() => normalizeTerminalFontSize(
    ref.watch(sharedPrefsProvider).getDouble(terminalFontSizePreferenceKey) ??
        terminalDefaultFontSize,
  );

  void preview(double fontSize) {
    state = normalizeTerminalFontSize(fontSize);
  }

  Future<void> setFontSize(double fontSize) async {
    state = normalizeTerminalFontSize(fontSize);
    await ref
        .read(sharedPrefsProvider)
        .setDouble(terminalFontSizePreferenceKey, state);
  }

  Future<void> reset() => setFontSize(terminalDefaultFontSize);
}

final terminalFontSizeProvider =
    NotifierProvider<TerminalFontSizeNotifier, double>(
      TerminalFontSizeNotifier.new,
    );

final diagnosticLogChannelProvider = Provider<EasyTierChannel>(
  (_) => const EasyTierChannel(),
);

class DiagnosticLoggingNotifier extends Notifier<bool> {
  @override
  bool build() =>
      ref.watch(sharedPrefsProvider).getBool(diagnosticLoggingPreferenceKey) ??
      false;

  Future<void> setEnabled(bool enabled) async {
    await ref
        .read(diagnosticLogChannelProvider)
        .configureDiagnosticLogging(enabled);
    state = enabled;
    await ref
        .read(sharedPrefsProvider)
        .setBool(diagnosticLoggingPreferenceKey, enabled);
  }
}

final diagnosticLoggingProvider =
    NotifierProvider<DiagnosticLoggingNotifier, bool>(
      DiagnosticLoggingNotifier.new,
    );

/// profile 列表的本地持久化仓库。
final profileStoreProvider = Provider<ProfileStore>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  // 删直连：旧键（v1 单条直连配置、v2 直连配置列表）不再有地方放，
  // 检测到即删，数据丢弃。
  prefs.remove('bridge_settings_v1');
  prefs.remove('bridge_settings_v2');
  return ProfileStore(prefs);
});

/// 全部 enabled profile 的常驻列表（bridgesProvider 的数据源）。
///
/// 改 profile（扫码添加 / 删除 / 开关 enabled）后由调用方（settings 页）
/// 调 [EnabledProfilesNotifier.reload] 刷新；bridgesProvider watch 本
/// provider，enabled 集合变化即重建连接集合。
class EnabledProfilesNotifier extends Notifier<List<RemoteProfile>> {
  @override
  List<RemoteProfile> build() {
    ref.watch(profileStoreProvider);
    Future.microtask(reload);
    return const [];
  }

  /// 从持久化层重读 enabled profile 列表。
  Future<void> reload() async {
    final all = await ref.read(profileStoreProvider).list();
    // 首次 reload 由 build 的 microtask 触发，读完后 provider 可能已被销毁。
    if (!ref.mounted) return;
    state = all.where((p) => p.enabled).toList();
  }
}

final enabledProfilesProvider =
    NotifierProvider<EnabledProfilesNotifier, List<RemoteProfile>>(
      EnabledProfilesNotifier.new,
    );
