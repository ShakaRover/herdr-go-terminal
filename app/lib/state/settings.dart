/// bridge 连接设置：baseUrl + 可选的自定义请求头（应对 collie 前置代理的
/// device gate 部署）。持久化在 shared_preferences。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/bridge_api.dart';
import '../model/remote_profile.dart';
import 'easytier_runtime.dart';

/// 在 main 里用已初始化的实例 override。
final sharedPrefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError('sharedPrefsProvider 未 override'),
);

class BridgeSettings {
  const BridgeSettings({
    this.baseUrl = '',
    this.headerName = '',
    this.headerValue = '',
    this.profileId = '',
  });

  /// 例：https://myhost.tail1234.ts.net（不带尾斜杠，api 层会再归一化）。
  final String baseUrl;

  /// 可选自定义请求头（如 X-Device-Id）。两者都非空才生效。
  final String headerName;
  final String headerValue;

  /// 当前 active 的 RemoteProfile id；空 = 旧的直填 baseUrl 模式（向后兼容）。
  final String profileId;

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  Map<String, String> get headers =>
      headerName.trim().isEmpty ? const {} : {headerName.trim(): headerValue};

  BridgeSettings copyWith(
          {String? baseUrl,
          String? headerName,
          String? headerValue,
          String? profileId}) =>
      BridgeSettings(
        baseUrl: baseUrl ?? this.baseUrl,
        headerName: headerName ?? this.headerName,
        headerValue: headerValue ?? this.headerValue,
        profileId: profileId ?? this.profileId,
      );

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'headerName': headerName,
        'headerValue': headerValue,
        'profileId': profileId,
      };

  factory BridgeSettings.fromJson(Map<String, dynamic> j) => BridgeSettings(
        baseUrl: j['baseUrl'] is String ? j['baseUrl'] as String : '',
        headerName: j['headerName'] is String ? j['headerName'] as String : '',
        headerValue:
            j['headerValue'] is String ? j['headerValue'] as String : '',
        profileId: j['profileId'] is String ? j['profileId'] as String : '',
      );
}

/// shared_preferences 里 bridge 设置的键（前台与后台任务共用）。
const bridgeSettingsPrefsKey = 'bridge_settings_v1';

class SettingsNotifier extends Notifier<BridgeSettings> {
  @override
  BridgeSettings build() {
    final raw = ref.watch(sharedPrefsProvider).getString(bridgeSettingsPrefsKey);
    if (raw == null || raw.isEmpty) return const BridgeSettings();
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
/// profileId 非空时忽略直填 baseUrl，改走 EasyTier 本地转发口：
/// runtime Ready → `http://127.0.0.1:<localPort>`，其余状态 → null。
final apiProvider = Provider<BridgeApi?>((ref) {
  final s = ref.watch(settingsProvider);
  if (s.profileId.isNotEmpty) {
    return switch (ref.watch(easytierRuntimeProvider)) {
      EasyTierReady(:final localPort) => BridgeApi(
          baseUrl: 'http://127.0.0.1:$localPort', headers: s.headers),
      _ => null,
    };
  }
  if (!s.isConfigured) return null;
  return BridgeApi(baseUrl: s.baseUrl, headers: s.headers);
});
