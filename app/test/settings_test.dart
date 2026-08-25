/// settings 层（删直连后）：sharedPrefsProvider / profileStoreProvider 壳 +
/// 遗留 prefs 键清理 + enabledProfilesProvider。
///
/// 全 EasyTier 后直连配置不再有地方放：bridge_settings_v1/v2 检测到即删，
/// 不做迁移。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/model/remote_profile.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用给定的 prefs 初始值建 container。
Future<ProviderContainer> buildContainer(
  Map<String, Object> initialValues,
) async {
  SharedPreferences.setMockInitialValues(initialValues);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

const _profile = RemoteProfile(
  id: 'p1',
  label: 'devbox',
  server: ['tcp://10.0.0.2:22023'],
  networkName: 'mynet',
  secret: 's3cr3t',
  virtualIp: '10.10.64.62',
  port: 46810,
);

const _profile2 = RemoteProfile(
  id: 'p2',
  label: 'buildbox',
  server: ['tcp://10.0.0.3:22023'],
  networkName: 'othernet',
  secret: 'hunter2',
  virtualIp: '10.10.64.99',
  port: 46811,
);

void main() {
  group('terminalAutoResizeProvider', () {
    test('默认开启并持久化用户选择', () async {
      final container = await buildContainer({});

      expect(container.read(terminalAutoResizeProvider), isTrue);
      await container
          .read(terminalAutoResizeProvider.notifier)
          .setEnabled(false);

      expect(container.read(terminalAutoResizeProvider), isFalse);
      expect(
        container
            .read(sharedPrefsProvider)
            .getBool(terminalAutoResizePreferenceKey),
        isFalse,
      );
    });

    test('读取已关闭的持久化选项', () async {
      final container = await buildContainer({
        terminalAutoResizePreferenceKey: false,
      });

      expect(container.read(terminalAutoResizeProvider), isFalse);
    });
  });

  group('terminalFontSizeProvider', () {
    test('默认字号可持久化并恢复', () async {
      final container = await buildContainer({});

      expect(container.read(terminalFontSizeProvider), 12.5);
      await container.read(terminalFontSizeProvider.notifier).setFontSize(10.7);

      expect(container.read(terminalFontSizeProvider), 10.7);
      expect(
        container
            .read(sharedPrefsProvider)
            .getDouble(terminalFontSizePreferenceKey),
        10.7,
      );

      await container.read(terminalFontSizeProvider.notifier).reset();
      expect(container.read(terminalFontSizeProvider), 12.5);
    });

    test('读取时限制异常和越界字号', () async {
      final tooLarge = await buildContainer({
        terminalFontSizePreferenceKey: 99.0,
      });
      expect(tooLarge.read(terminalFontSizeProvider), 16.0);
    });
  });

  group('遗留键清理', () {
    test('无任何遗留键时 prefs 不被触碰', () async {
      final container = await buildContainer({'unrelated': 'x'});
      container.read(profileStoreProvider);

      final prefs = container.read(sharedPrefsProvider);
      expect(prefs.getString('unrelated'), 'x');
      expect(prefs.getString('bridge_settings_v1'), isNull);
      expect(prefs.getString('bridge_settings_v2'), isNull);
    });

    test('bridge_settings_v1（旧单连接直连配置）检测到即删，不迁移', () async {
      final container = await buildContainer({
        'bridge_settings_v1': jsonEncode({
          'baseUrl': 'https://a.ts.net',
          'headerName': 'X-Device-Id',
          'headerValue': 'v',
          'profileId': 'abc',
        }),
      });
      container.read(profileStoreProvider);

      final prefs = container.read(sharedPrefsProvider);
      expect(prefs.getString('bridge_settings_v1'), isNull);
      // 直连数据被丢弃：不产生任何新键、不进 profile 列表。
      expect(prefs.getString('bridge_settings_v2'), isNull);
      expect(await container.read(profileStoreProvider).list(), isEmpty);
    });

    test('bridge_settings_v2（直连配置列表）检测到即删', () async {
      final container = await buildContainer({
        'bridge_settings_v2': jsonEncode({
          'directConfigs': [
            {'id': 'id-1', 'label': 'home', 'baseUrl': 'https://a.ts.net'},
          ],
        }),
      });
      container.read(profileStoreProvider);

      expect(
        container.read(sharedPrefsProvider).getString('bridge_settings_v2'),
        isNull,
      );
    });
  });

  group('enabledProfilesProvider', () {
    test('空列表 → 空、isConfigured false', () async {
      final container = await buildContainer({});
      expect(container.read(enabledProfilesProvider), isEmpty);
      expect(
        container.read(enabledProfilesProvider.notifier).isConfigured,
        isFalse,
      );
    });

    test('只含 enabled profile；setEnabled 后列表与 isConfigured 联动', () async {
      final container = await buildContainer({});
      final notifier = container.read(enabledProfilesProvider.notifier);
      final store = container.read(profileStoreProvider);
      await store.add(_profile);
      await store.add(_profile2);
      await notifier.reload();

      expect(container.read(enabledProfilesProvider).map((p) => p.id), [
        'p1',
        'p2',
      ]);
      expect(notifier.isConfigured, isTrue);

      // disable 一条 → 列表只剩另一条。
      await store.setEnabled('p1', false);
      await notifier.reload();
      expect(container.read(enabledProfilesProvider).map((p) => p.id), ['p2']);
      expect(notifier.isConfigured, isTrue);

      // 全部 disable → isConfigured false。
      await store.setEnabled('p2', false);
      await notifier.reload();
      expect(container.read(enabledProfilesProvider), isEmpty);
      expect(notifier.isConfigured, isFalse);

      // 持久化层的 enabled 确实被翻转（profile 本体字段不变）。
      final all = await store.list();
      expect(all.firstWhere((p) => p.id == 'p1').enabled, isFalse);
      expect(all.firstWhere((p) => p.id == 'p2').enabled, isFalse);
    });

    test('持久化里 disabled 的 profile 初始就不在列表里', () async {
      final container = await buildContainer({
        profileStorePrefsKey: jsonEncode([
          _profile.toJson(),
          _profile2.copyWith(enabled: false).toJson(),
        ]),
      });
      // 先 read 触发 build（返回 []），首次 reload 在 microtask 里完成后
      // 才含 enabled。
      expect(container.read(enabledProfilesProvider), isEmpty);
      await pumpEventQueue();
      expect(container.read(enabledProfilesProvider).map((p) => p.id), ['p1']);
    });
  });
}
