/// bridge 连接设置：直填 DirectConfig 列表（label/baseUrl/可选自定义请求头/
/// enabled）。持久化在 shared_preferences。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../api/bridge_api.dart';
import '../model/direct_config.dart';
import '../model/remote_profile.dart';

/// 在 main 里用已初始化的实例 override。
final sharedPrefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError('sharedPrefsProvider 未 override'),
);

class BridgeSettings {
  const BridgeSettings({this.directConfigs = const []});

  final List<DirectConfig> directConfigs;

  bool get isConfigured =>
      directConfigs.any((c) => c.enabled && c.baseUrl.trim().isNotEmpty);

  BridgeSettings copyWith({List<DirectConfig>? directConfigs}) =>
      BridgeSettings(directConfigs: directConfigs ?? this.directConfigs);

  Map<String, dynamic> toJson() => {
        'directConfigs':
            directConfigs.map((c) => c.toJson()).toList(),
      };

  factory BridgeSettings.fromJson(Map<String, dynamic> j) {
    final raw = j['directConfigs'];
    if (raw is! List) return const BridgeSettings();
    return BridgeSettings(
      directConfigs: raw
          .whereType<Map<String, dynamic>>()
          .map(DirectConfig.fromJson)
          .toList(),
    );
  }
}

/// shared_preferences 键（v2：直连配置列表化、删 active profileId）。
const bridgeSettingsPrefsKey = 'bridge_settings_v2';

/// 仅迁移用：v2 缺失且 v1 存在时包成单条 DirectConfig 后删除。
const _legacyBridgeSettingsPrefsKey = 'bridge_settings_v1';

class SettingsNotifier extends Notifier<BridgeSettings> {
  @override
  BridgeSettings build() {
    final prefs = ref.watch(sharedPrefsProvider);
    final raw = prefs.getString(bridgeSettingsPrefsKey);
    if (raw == null || raw.isEmpty) {
      return _migrateLegacy(prefs) ?? const BridgeSettings();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return BridgeSettings.fromJson(decoded);
      }
    } catch (_) {
      // 损坏的持久化数据按未配置处理。
    }
    return const BridgeSettings();
  }

  /// v1（单条 baseUrl/header + active profileId）迁移：baseUrl 非空则包成
  /// 单条 enabled 的 DirectConfig（label 取 host），忽略旧 profileId（profile
  /// 启用态改由 RemoteProfile.enabled 承载，旧数据默认 true = 保持旧行为）；
  /// 随后删除 v1 键。
  BridgeSettings? _migrateLegacy(SharedPreferences prefs) {
    final legacy = prefs.getString(_legacyBridgeSettingsPrefsKey);
    if (legacy == null) return null;
    BridgeSettings? migrated;
    try {
      final decoded = jsonDecode(legacy);
      if (decoded is Map<String, dynamic>) {
        final baseUrl =
            decoded['baseUrl'] is String ? decoded['baseUrl'] as String : '';
        if (baseUrl.trim().isNotEmpty) {
          final config = DirectConfig(
            id: const Uuid().v4(),
            label: _hostOf(baseUrl),
            baseUrl: baseUrl,
            headerName: decoded['headerName'] is String
                ? decoded['headerName'] as String
                : '',
            headerValue: decoded['headerValue'] is String
                ? decoded['headerValue'] as String
                : '',
          );
          migrated = BridgeSettings(directConfigs: [config]);
          prefs.setString(
              bridgeSettingsPrefsKey, jsonEncode(migrated.toJson()));
        }
      }
    } catch (_) {
      // 损坏的 v1 数据按未配置处理，仍删除旧键。
    }
    prefs.remove(_legacyBridgeSettingsPrefsKey);
    return migrated;
  }

  static String _hostOf(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host ?? '';
    return host.isNotEmpty ? host : baseUrl.trim();
  }

  Future<void> save(BridgeSettings settings) async {
    state = settings;
    await ref
        .read(sharedPrefsProvider)
        .setString(bridgeSettingsPrefsKey, jsonEncode(settings.toJson()));
  }
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, BridgeSettings>(SettingsNotifier.new);

/// profile 列表的本地持久化仓库。
final profileStoreProvider = Provider<ProfileStore>(
  (ref) => ProfileStore(ref.watch(sharedPrefsProvider)),
);

/// 已配置时为可用的 API 客户端，否则为 null（UI 据此跳设置页）。
/// 过渡实现：只取首条 enabled 直连配置，Task 7 迁移到 state/bridges.dart。
final apiProvider = Provider<BridgeApi?>((ref) {
  final s = ref.watch(settingsProvider);
  for (final c in s.directConfigs) {
    if (c.enabled && c.baseUrl.trim().isNotEmpty) {
      return BridgeApi(baseUrl: c.baseUrl, headers: c.headers);
    }
  }
  return null;
});
