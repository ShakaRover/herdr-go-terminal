/// easytier_runtime 状态机与 TOML 生成的测试。
///
/// 用 fake EasyTierChannel（easytierChannelProvider override）验证：
/// - buildInstanceToml 的内容与字符串转义；
/// - connect 调用序列：stopForwarder → stopInstance → startInstance →
///   轮询 currentVirtualIp → startForwarder → Ready；
/// - virtualIp 轮询超时 → Failed；startInstance 抛错 → Failed；
/// - profileId 置空 / 找不到 profile → disconnect 清理；
/// - apiProvider 在 Ready 时指向本地转发口，其余状态为 null。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/api/easytier_channel.dart';
import 'package:herdr_web/model/remote_profile.dart';
import 'package:herdr_web/state/easytier_runtime.dart';
import 'package:herdr_web/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 脚本化的 EasyTierChannel：记录调用顺序，按队列吐出 virtualIp 结果。
class FakeEasyTierChannel extends EasyTierChannel {
  FakeEasyTierChannel()
      : super(const MethodChannel('dev.herdr/easytier-test'), 'default');

  final calls = <String>[];
  final startedConfigs = <String>[];

  /// 每次 currentVirtualIp 弹一个；取空后反复吐最后一个，永不超时。
  final virtualIpResults = <String?>[null, '10.10.64.62'];
  Object? startInstanceError;
  Object? stopInstanceError;
  int nextForwarderPort = 40001;

  @override
  Future<void> startInstance(String tomlConfig) async {
    calls.add('startInstance');
    startedConfigs.add(tomlConfig);
    final e = startInstanceError;
    if (e != null) throw e;
  }

  @override
  Future<void> stopInstance() async {
    calls.add('stopInstance');
    final e = stopInstanceError;
    if (e != null) throw e;
  }

  @override
  Future<String?> currentVirtualIp() async {
    calls.add('currentVirtualIp');
    if (virtualIpResults.length > 1) return virtualIpResults.removeAt(0);
    return virtualIpResults.single;
  }

  @override
  Future<int> startForwarder(String targetIp, int targetPort) async {
    calls.add('startForwarder($targetIp:$targetPort)');
    return nextForwarderPort;
  }

  @override
  Future<void> stopForwarder(int localPort) async {
    calls.add('stopForwarder($localPort)');
  }
}

const profile = RemoteProfile(
  id: 'abcdefgh-1234-5678-9abc-def012345678',
  label: 'devbox',
  server: 'tcp://vpn.example.com:11010',
  networkName: 'mynet',
  secret: 's3cr3t',
  virtualIp: '10.10.64.62',
  port: 46810,
);

/// 建好 container 并把 profile 落盘、settings.profileId 指过去。
/// [withProfile] 为 false 时 profileId 指向不存在的 id。
Future<ProviderContainer> makeContainer(
  FakeEasyTierChannel channel, {
  bool withProfile = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  if (withProfile) await ProfileStore(prefs).add(profile);
  final container = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(prefs),
    easytierChannelProvider.overrideWithValue(channel),
  ]);
  addTearDown(container.dispose);
  await container.read(settingsProvider.notifier).save(
      BridgeSettings(profileId: withProfile ? profile.id : 'missing-id'));
  return container;
}

/// 等 runtime 状态满足条件（依赖 ref.listen，超时即失败）。
Future<EasyTierRuntimeState> waitRuntime(
  ProviderContainer container,
  bool Function(EasyTierRuntimeState) test,
) {
  final c = Completer<EasyTierRuntimeState>();
  final sub = container.listen(easytierRuntimeProvider, (_, next) {
    if (test(next) && !c.isCompleted) c.complete(next);
  });
  addTearDown(sub.close);
  return c.future.timeout(const Duration(seconds: 5));
}

/// 轮等条件成立（用于 identical 状态不触发监听的场景），5s 不成立即失败。
Future<void> pumpUntil(bool Function() test) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('pumpUntil 超时：条件 5s 内未成立');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 测试不真等 500ms 一拍。
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 10);
  });
  tearDown(() {
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 500);
    EasyTierRuntimeNotifier.virtualIpTimeout = const Duration(seconds: 15);
  });

  group('buildInstanceToml', () {
    test('字段齐全：默认实例名（与转发器默认对齐），no_tun 转发模式', () {
      final toml = buildInstanceToml(profile);
      expect(toml, '''
hostname = "herdr-app"
network_name = "mynet"
network_secret = "s3cr3t"
dhcp = true
peers = ["tcp://vpn.example.com:11010"]
listeners = []
[flags]
no_tun = true
disable_upnp = true
''');
      expect(toml, isNot(contains('instance_name')));
    });

    test(r'networkName/secret/server 中的 \ 和 " 被转义', () {
      const p = RemoteProfile(
        id: '12345678-xxxx',
        label: 'l',
        server: 'tcp://a"b\\c:11010',
        networkName: 'net\\"x"',
        secret: 'sec\\"ret"',
        virtualIp: '10.0.0.1',
        port: 80,
      );
      final toml = buildInstanceToml(p);
      expect(toml, contains(r'network_name = "net\\\"x\""'));
      expect(toml, contains(r'network_secret = "sec\\\"ret\""'));
      expect(toml, contains(r'peers = ["tcp://a\"b\\c:11010"]'));
    });
  });

  group('connect', () {
    test('成功序列：stopInstance → startInstance → 轮询 → forward → Ready',
        () async {
      final channel = FakeEasyTierChannel();
      final container = await makeContainer(channel);
      final states = <EasyTierRuntimeState>[];
      final sub = container
          .listen(easytierRuntimeProvider, (_, s) => states.add(s));
      addTearDown(sub.close);

      final s = await waitRuntime(
          container, (s) => s is EasyTierReady || s is EasyTierFailed);

      expect(states.first, isA<EasyTierConnecting>());
      expect(s, isA<EasyTierReady>().having(
          (s) => s.localPort, 'localPort', 40001));
      expect(channel.calls, [
        'stopInstance',
        'startInstance',
        'currentVirtualIp', // 第一次 null
        'currentVirtualIp', // 第二次拿到 10.10.64.62
        'startForwarder(10.10.64.62:46810)',
      ]);
      expect(channel.startedConfigs, [buildInstanceToml(profile)]);
    });

    test('stopInstance 的残留错误被忽略，不影响 connect', () async {
      final channel = FakeEasyTierChannel()
        ..stopInstanceError = PlatformException(code: 'x', message: '残留');
      final container = await makeContainer(channel);
      final s = await waitRuntime(
          container, (s) => s is EasyTierReady || s is EasyTierFailed);
      expect(s, isA<EasyTierReady>());
    });

    test('virtualIp 轮询超时 → Failed(等待虚拟 IP 超时)，不再启动转发器', () async {
      EasyTierRuntimeNotifier.virtualIpTimeout =
          const Duration(milliseconds: 100);
      final channel = FakeEasyTierChannel()
        ..virtualIpResults.clear()
        ..virtualIpResults.add(null); // 永远拿不到虚拟 IP，必超时
      final container = await makeContainer(channel);

      final s = await waitRuntime(container, (s) => s is EasyTierFailed);
      expect((s as EasyTierFailed).message, contains('等待虚拟 IP 超时'));
      expect(
          channel.calls.where((c) => c.startsWith('startForwarder')), isEmpty);
    });

    test('startInstance 抛错 → Failed，不轮询不转发', () async {
      final channel = FakeEasyTierChannel()
        ..startInstanceError = PlatformException(code: 'easytier', message: 'boom');
      final container = await makeContainer(channel);

      final s = await waitRuntime(container, (s) => s is EasyTierFailed);
      expect((s as EasyTierFailed).message, contains('boom'));
      expect(channel.calls,
          isNot(contains(startsWith('currentVirtualIp'))));
      expect(
          channel.calls.where((c) => c.startsWith('startForwarder')), isEmpty);
    });
  });

  group('disconnect', () {
    test('profileId 置空 → stopForwarder + stopInstance → Disconnected',
        () async {
      final channel = FakeEasyTierChannel();
      final container = await makeContainer(channel);
      await waitRuntime(container, (s) => s is EasyTierReady);
      channel.calls.clear();

      final disconnected =
          waitRuntime(container, (s) => s is EasyTierDisconnected);
      await container
          .read(settingsProvider.notifier)
          .save(const BridgeSettings());
      await disconnected;

      expect(channel.calls, ['stopForwarder(40001)', 'stopInstance']);
    });

    test('profileId 指向不存在的 profile → Disconnected，不启动实例', () async {
      final channel = FakeEasyTierChannel();
      final container =
          await makeContainer(channel, withProfile: false);
      container.read(easytierRuntimeProvider); // 触发初始 connect 流程
      // disconnect 前后都是 const EasyTierDisconnected()（identical，不触发
      // 监听），改为等 teardown 的副作用：stopInstance 被调用。
      await pumpUntil(() => channel.calls.isNotEmpty);

      expect(container.read(easytierRuntimeProvider),
          isA<EasyTierDisconnected>());
      expect(channel.calls,
          ['stopInstance']); // 只做容错 teardown，不 startInstance
    });
  });

  group('apiProvider', () {
    test('Ready → baseUrl 指向本地转发口；其余状态 → null', () async {
      final channel = FakeEasyTierChannel();
      final container = await makeContainer(channel);

      expect(container.read(apiProvider), isNull);
      await waitRuntime(container, (s) => s is EasyTierReady);
      final api = container.read(apiProvider);
      expect(api, isNotNull);
      expect(api!.baseUrl, 'http://127.0.0.1:40001');
    });

    test('profileId 为空时保持旧的直填 baseUrl 行为', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        easytierChannelProvider.overrideWithValue(FakeEasyTierChannel()),
      ]);
      addTearDown(container.dispose);
      await container.read(settingsProvider.notifier).save(
          const BridgeSettings(baseUrl: 'https://myhost.ts.net'));

      final api = container.read(apiProvider);
      expect(api, isNotNull);
      expect(api!.baseUrl, 'https://myhost.ts.net');
    });
  });
}
