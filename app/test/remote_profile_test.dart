import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/model/remote_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> validPairingJson() => {
      'v': 1,
      'server': ['tcp://10.0.0.2:22023', 'tcp://vpn.example.com:11010'],
      'networkName': 'abcdefgh-1234-5678-9abc-def012345678',
      'secret': 's3cret',
      'virtualIp': '10.126.0.1',
      'port': 56001,
    };

void main() {
  group('RemoteProfile.fromPairingJson', () {
    test('正常解析：字段齐全，label 取 networkName 前 8 位', () {
      final p = RemoteProfile.fromPairingJson(validPairingJson());
      expect(p.server,
          ['tcp://10.0.0.2:22023', 'tcp://vpn.example.com:11010']);
      expect(p.networkName,
          'abcdefgh-1234-5678-9abc-def012345678');
      expect(p.secret, 's3cret');
      expect(p.virtualIp, '10.126.0.1');
      expect(p.port, 56001);
      expect(p.label, 'abcdefgh');
      expect(p.id, isNotEmpty);
    });

    test('未知字段忽略', () {
      final j = validPairingJson()
        ..['extra'] = 'whatever'
        ..['nested'] = {'a': 1};
      final p = RemoteProfile.fromPairingJson(j);
      expect(p.server, validPairingJson()['server']);
    });

    test('server 兼容旧版二维码的单值字符串（包成单元素数组）', () {
      final p = RemoteProfile.fromPairingJson(
          {...validPairingJson(), 'server': 'tcp://vpn.example.com:11010'});
      expect(p.server, ['tcp://vpn.example.com:11010']);
    });

    test('v != 1 抛 FormatException', () {
      for (final v in [0, 2, '1']) {
        expect(
          () => RemoteProfile.fromPairingJson({...validPairingJson(), 'v': v}),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('version'))),
        );
      }
    });

    test('必填字段缺失或类型错误抛 FormatException', () {
      for (final key in ['server', 'networkName', 'secret', 'virtualIp']) {
        // 缺失
        final missing = validPairingJson()..remove(key);
        expect(() => RemoteProfile.fromPairingJson(missing),
            throwsA(isA<FormatException>()));
        // 类型错误
        expect(
          () => RemoteProfile.fromPairingJson({...validPairingJson(), key: 42}),
          throwsA(isA<FormatException>()),
        );
      }
      for (final key in ['networkName', 'secret', 'virtualIp']) {
        // 空字符串
        expect(
          () => RemoteProfile.fromPairingJson({...validPairingJson(), key: ''}),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('server 为空数组或含空/非 String 元素抛 FormatException', () {
      for (final bad in [
        <String>[],
        [''],
        ['tcp://a:11010', 42],
        ['tcp://a:11010', ''],
      ]) {
        expect(
          () => RemoteProfile.fromPairingJson(
              {...validPairingJson(), 'server': bad}),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('port 缺失或非 int 或越界（0 / 65536）抛 FormatException', () {
      final missing = validPairingJson()..remove('port');
      expect(() => RemoteProfile.fromPairingJson(missing),
          throwsA(isA<FormatException>()));
      for (final port in ['56001', 0, 65536, -1, 1.5]) {
        expect(
          () => RemoteProfile.fromPairingJson(
              {...validPairingJson(), 'port': port}),
          throwsA(isA<FormatException>()),
        );
      }
      // 边界合法值
      expect(
          RemoteProfile.fromPairingJson({...validPairingJson(), 'port': 1})
              .port,
          1);
      expect(
          RemoteProfile.fromPairingJson(
                  {...validPairingJson(), 'port': 65535})
              .port,
          65535);
    });

    test('自定义 label 优先于默认', () {
      final p = RemoteProfile.fromPairingJson(
          {...validPairingJson(), 'label': 'home'});
      expect(p.label, 'home');
    });
  });

  group('RemoteProfile enabled', () {
    test('fromJson 缺 enabled 字段默认为 true', () {
      final p = RemoteProfile.fromJson(
          RemoteProfile.fromPairingJson(validPairingJson()).toJson()
            ..remove('enabled'));
      expect(p.enabled, isTrue);
    });

    test('fromJson 显式 enabled: false 保留', () {
      final p = RemoteProfile.fromJson(
          RemoteProfile.fromPairingJson(validPairingJson()).toJson()
            ..['enabled'] = false);
      expect(p.enabled, isFalse);
    });

    test('fromPairingJson 默认 enabled 为 true', () {
      expect(RemoteProfile.fromPairingJson(validPairingJson()).enabled, isTrue);
    });

    test('copyWith(enabled: false) 只改 enabled，其余字段不动', () {
      final p = RemoteProfile.fromPairingJson(validPairingJson());
      final updated = p.copyWith(enabled: false);
      expect(updated.enabled, isFalse);
      expect(updated.id, p.id);
      expect(updated.label, p.label);
      expect(updated.server, p.server);
      expect(updated.networkName, p.networkName);
      expect(updated.secret, p.secret);
      expect(updated.virtualIp, p.virtualIp);
      expect(updated.port, p.port);
    });

    test('copyWith(label: ...) 只改 label，enabled 不动', () {
      final p = RemoteProfile.fromPairingJson(validPairingJson())
          .copyWith(enabled: false);
      final updated = p.copyWith(label: 'new');
      expect(updated.label, 'new');
      expect(updated.enabled, isFalse);
    });
  });

  group('RemoteProfile toJson/fromJson 往返', () {
    test('roundtrip 保持所有字段', () {
      final p = RemoteProfile.fromPairingJson(validPairingJson());
      final restored = RemoteProfile.fromJson(p.toJson());
      expect(restored.id, p.id);
      expect(restored.label, p.label);
      expect(restored.server, p.server);
      expect(restored.networkName, p.networkName);
      expect(restored.secret, p.secret);
      expect(restored.virtualIp, p.virtualIp);
      expect(restored.port, p.port);
    });

    test('toJson 把 server 写成数组，fromJson 读回一致', () {
      final p = RemoteProfile.fromPairingJson(validPairingJson());
      final j = p.toJson();
      expect(j['server'], isA<List>());
      expect(j['server'],
          ['tcp://10.0.0.2:22023', 'tcp://vpn.example.com:11010']);
      expect(RemoteProfile.fromJson(j).server, p.server);
    });

    test('fromJson 迁移旧格式：server 单值字符串包成单元素数组', () {
      final j = RemoteProfile.fromPairingJson(validPairingJson()).toJson()
        ..['server'] = 'tcp://vpn.example.com:11010';
      expect(RemoteProfile.fromJson(j).server,
          ['tcp://vpn.example.com:11010']);
    });

    test('fromJson 缺失或非法 server 得空数组', () {
      final base =
          RemoteProfile.fromPairingJson(validPairingJson()).toJson();
      expect(RemoteProfile.fromJson(base..remove('server')).server, isEmpty);
      expect(
          RemoteProfile.fromJson(
                  RemoteProfile.fromPairingJson(validPairingJson()).toJson()
                    ..['server'] = 42)
              .server,
          isEmpty);
    });
  });

  group('ProfileStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<ProfileStore> freshStore() async =>
        ProfileStore(await SharedPreferences.getInstance());

    test('空 store list 为空', () async {
      expect(await (await freshStore()).list(), isEmpty);
    });

    test('add 后 list/getById 可见，id 自动生成', () async {
      final store = await freshStore();
      final p = await store.add(RemoteProfile.fromPairingJson(validPairingJson()));
      final list = await store.list();
      expect(list, hasLength(1));
      expect(list.single.id, p.id);
      final got = await store.getById(p.id);
      expect(got, isNotNull);
      expect(got!.secret, 's3cret');
    });

    test('add 多个按插入顺序保留', () async {
      final store = await freshStore();
      await store.add(RemoteProfile.fromPairingJson(validPairingJson()));
      await store.add(RemoteProfile.fromPairingJson(
          {...validPairingJson(), 'virtualIp': '10.126.0.2'}));
      expect(await store.list(), hasLength(2));
    });

    test('remove 按 id 删除，剩余不受影响', () async {
      final store = await freshStore();
      final a = await store
          .add(RemoteProfile.fromPairingJson(validPairingJson()));
      final b = await store.add(RemoteProfile.fromPairingJson(
          {...validPairingJson(), 'virtualIp': '10.126.0.2'}));
      await store.remove(a.id);
      final list = await store.list();
      expect(list.single.id, b.id);
      expect(await store.getById(a.id), isNull);
    });

    test('remove 不存在的 id 不报错', () async {
      final store = await freshStore();
      await store.remove('no-such-id');
      expect(await store.list(), isEmpty);
    });

    test('损坏的持久化数据按空处理', () async {
      SharedPreferences.setMockInitialValues(
          {'bridge_profiles_v1': 'not json {{'});
      expect(await (await freshStore()).list(), isEmpty);
    });

    test('新实例能读到之前写入的数据（持久化）', () async {
      final store = await freshStore();
      final p = await store.add(RemoteProfile.fromPairingJson(validPairingJson()));
      // 模拟应用重启后用新的 store 实例重新读取。
      final store2 = await freshStore();
      final got = await store2.getById(p.id);
      expect(got, isNotNull);
      expect(got!.virtualIp, '10.126.0.1');
    });

    test('setEnabled 翻转到 false 后持久生效，其余字段不变', () async {
      final store = await freshStore();
      final p = await store.add(RemoteProfile.fromPairingJson(validPairingJson()));
      await store.setEnabled(p.id, false);
      // 用新实例重读，验证已持久化。
      final got = await (await freshStore()).getById(p.id);
      expect(got, isNotNull);
      expect(got!.enabled, isFalse);
      expect(got.id, p.id);
      expect(got.label, p.label);
      expect(got.server, p.server);
      expect(got.networkName, p.networkName);
      expect(got.secret, p.secret);
      expect(got.virtualIp, p.virtualIp);
      expect(got.port, p.port);
    });

    test('setEnabled 不存在的 id 不报错', () async {
      final store = await freshStore();
      await store.add(RemoteProfile.fromPairingJson(validPairingJson()));
      await store.setEnabled('no-such-id', false);
      final list = await store.list();
      expect(list, hasLength(1));
      expect(list.single.enabled, isTrue);
    });

    test('setLabel 改名后持久生效，其余字段不变', () async {
      final store = await freshStore();
      final p = await store.add(RemoteProfile.fromPairingJson(validPairingJson()));
      await store.setLabel(p.id, '我的 NAS');
      final got = await (await freshStore()).getById(p.id);
      expect(got, isNotNull);
      expect(got!.label, '我的 NAS');
      expect(got.id, p.id);
      expect(got.enabled, p.enabled);
      expect(got.virtualIp, p.virtualIp);
    });

    test('setLabel 空白忽略，不存在的 id 不报错', () async {
      final store = await freshStore();
      final p = await store.add(RemoteProfile.fromPairingJson(validPairingJson()));
      await store.setLabel(p.id, '   ');
      expect((await store.getById(p.id))!.label, p.label);
      await store.setLabel('no-such-id', 'x');
      expect(await store.list(), hasLength(1));
    });
  });
}
