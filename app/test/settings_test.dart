import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/model/direct_config.dart';
import 'package:herdr_web/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用给定的 prefs 初始值建 container，读 settings 并返回。
Future<(ProviderContainer, BridgeSettings)> buildSettings(
    Map<String, Object> initialValues) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(prefs),
  ]);
  addTearDown(container.dispose);
  return (container, container.read(settingsProvider));
}

void main() {
  group('BridgeSettings v2', () {
    test('v2 无数据时 directConfigs 为空、isConfigured false', () async {
      final (_, s) = await buildSettings({});
      expect(s.directConfigs, isEmpty);
      expect(s.isConfigured, isFalse);
    });

    test('v2 round-trip：多条 DirectConfig 序列化反序列化不变', () {
      const s = BridgeSettings(directConfigs: [
        DirectConfig(
          id: 'id-1',
          label: 'home',
          baseUrl: 'https://a.ts.net',
          headerName: 'X-Device-Id',
          headerValue: 'v1',
        ),
        DirectConfig(
          id: 'id-2',
          label: 'office',
          baseUrl: 'https://b.ts.net',
          headerName: 'X-Device-Id',
          headerValue: 'v2',
          enabled: false,
        ),
        DirectConfig(
          id: 'id-3',
          label: 'bare',
          baseUrl: 'https://c.ts.net',
        ),
      ]);
      final restored = BridgeSettings.fromJson(jsonDecode(jsonEncode(s.toJson()))
          as Map<String, dynamic>);
      expect(restored.directConfigs, hasLength(3));
      for (var i = 0; i < s.directConfigs.length; i++) {
        final want = s.directConfigs[i];
        final got = restored.directConfigs[i];
        expect(got.id, want.id);
        expect(got.label, want.label);
        expect(got.baseUrl, want.baseUrl);
        expect(got.headerName, want.headerName);
        expect(got.headerValue, want.headerValue);
        expect(got.enabled, want.enabled);
        expect(got.headers, want.headers);
      }
    });

    test('isConfigured：全部 disabled 或 baseUrl 空时为 false', () {
      const allDisabled = BridgeSettings(directConfigs: [
        DirectConfig(
            id: '1', label: 'a', baseUrl: 'https://a.ts.net', enabled: false),
      ]);
      expect(allDisabled.isConfigured, isFalse);

      const blankUrl = BridgeSettings(directConfigs: [
        DirectConfig(id: '1', label: 'a', baseUrl: '  '),
      ]);
      expect(blankUrl.isConfigured, isFalse);

      const oneEnabled = BridgeSettings(directConfigs: [
        DirectConfig(
            id: '1', label: 'a', baseUrl: 'https://a.ts.net', enabled: false),
        DirectConfig(id: '2', label: 'b', baseUrl: 'https://b.ts.net'),
      ]);
      expect(oneEnabled.isConfigured, isTrue);
    });

    test('copyWith 只替换 directConfigs', () {
      const s = BridgeSettings(directConfigs: [
        DirectConfig(id: '1', label: 'a', baseUrl: 'https://a.ts.net'),
      ]);
      const updated = BridgeSettings();
      final got = s.copyWith(directConfigs: updated.directConfigs);
      expect(got.directConfigs, isEmpty);
      // 不传参时保持原值
      expect(s.copyWith().directConfigs, hasLength(1));
    });
  });

  group('bridge_settings_v1 → v2 迁移', () {
    test('v1 非空 → 包成单条 DirectConfig，v1 键删除、v2 键写入', () async {
      final (container, s) = await buildSettings({
        'bridge_settings_v1': jsonEncode({
          'baseUrl': 'https://a.ts.net',
          'headerName': 'X-Device-Id',
          'headerValue': 'v',
          'profileId': 'abc',
        }),
      });
      expect(s.directConfigs, hasLength(1));
      final c = s.directConfigs.single;
      expect(c.id, isNotEmpty);
      expect(c.enabled, isTrue);
      expect(c.label, 'a.ts.net');
      expect(c.baseUrl, 'https://a.ts.net');
      expect(c.headers, {'X-Device-Id': 'v'});

      final prefs = container.read(sharedPrefsProvider);
      expect(prefs.getString('bridge_settings_v1'), isNull);
      final rawV2 = prefs.getString(bridgeSettingsPrefsKey);
      expect(rawV2, isNotNull);
      final decoded =
          jsonDecode(rawV2!) as Map<String, dynamic>;
      expect(decoded['directConfigs'], hasLength(1));
    });

    test('v1 baseUrl 为空 → directConfigs 为空、v1 键仍被删', () async {
      final (container, s) = await buildSettings({
        'bridge_settings_v1': jsonEncode({
          'baseUrl': '',
          'headerName': '',
          'headerValue': '',
          'profileId': 'abc',
        }),
      });
      expect(s.directConfigs, isEmpty);
      expect(s.isConfigured, isFalse);
      expect(container.read(sharedPrefsProvider).getString('bridge_settings_v1'),
          isNull);
    });

    test('v2 已存在时不做迁移、v1 键保留', () async {
      const existing = BridgeSettings(directConfigs: [
        DirectConfig(id: 'id-9', label: 'x', baseUrl: 'https://x.ts.net'),
      ]);
      final (container, s) = await buildSettings({
        bridgeSettingsPrefsKey: jsonEncode(existing.toJson()),
        'bridge_settings_v1': jsonEncode({'baseUrl': 'https://a.ts.net'}),
      });
      expect(s.directConfigs, hasLength(1));
      expect(s.directConfigs.single.id, 'id-9');
      expect(container.read(sharedPrefsProvider).getString('bridge_settings_v1'),
          isNotNull);
    });
  });
}
