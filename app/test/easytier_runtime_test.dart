/// easytier_runtime 状态机与 TOML 生成的测试。
///
/// 用 fake EasyTierChannel（easytierChannelProvider override）验证：
/// - buildInstanceToml 显式写 instance_name = profile.id，全部 server 写入
///   `[[peer]]` 数组，字段与转义行为；
/// - connect 调用序列：startInstance → 轮询 currentVirtualIp(profileId) →
///   startForwarder(profileId, ip, port) → Ready（无 teardown 性质的
///   stopInstance）；
/// - virtualIp 轮询超时 → Failed；startInstance 抛错 → Failed；
/// - disconnect → stopForwarder(localPort) + stopInstance(profileId)；
/// - family(profileId) 的两个实例各自独立 connect，调用序列互不影响。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/api/easytier_channel.dart';
import 'package:herdr_web/model/remote_profile.dart';
import 'package:herdr_web/state/easytier_runtime.dart';

/// 脚本化的 EasyTierChannel：记录调用顺序（含 instanceName），
/// 按队列吐出 virtualIp 结果。
class FakeEasyTierChannel extends EasyTierChannel {
  FakeEasyTierChannel()
      : super(const MethodChannel('dev.herdr/easytier-test'));

  final calls = <String>[];
  final startedConfigs = <String>[];

  /// 每次 currentVirtualIp 弹一个；取空后反复吐最后一个，永不超时。
  final virtualIpResults = <String?>[null, '10.10.64.62'];
  Object? startInstanceError;
  int nextForwarderPort = 40001;

  @override
  Future<void> startInstance(String tomlConfig) async {
    calls.add('startInstance');
    startedConfigs.add(tomlConfig);
    final e = startInstanceError;
    if (e != null) throw e;
  }

  @override
  Future<void> stopInstance(String instanceName) async {
    calls.add('stopInstance($instanceName)');
  }

  @override
  Future<String?> currentVirtualIp(String instanceName) async {
    calls.add('currentVirtualIp($instanceName)');
    if (virtualIpResults.length > 1) return virtualIpResults.removeAt(0);
    return virtualIpResults.single;
  }

  @override
  Future<int> startForwarder(
      String instanceName, String targetIp, int targetPort) async {
    calls.add('startForwarder($instanceName,$targetIp:$targetPort)');
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
  server: ['tcp://10.0.0.2:22023', 'tcp://vpn.example.com:11010'],
  networkName: 'mynet',
  secret: 's3cr3t',
  virtualIp: '10.10.64.62',
  port: 46810,
);

/// 另一条 profile：id 不同 ⇒ 独立的 family 实例，端口也不同。
const profile2 = RemoteProfile(
  id: '12345678-0000-0000-0000-000000000000',
  label: 'buildbox',
  server: ['tcp://vpn2.example.com:11010'],
  networkName: 'othernet',
  secret: 'hunter2',
  virtualIp: '10.10.64.99',
  port: 46811,
);

ProviderContainer makeContainer(FakeEasyTierChannel channel) {
  final container = ProviderContainer(overrides: [
    easytierChannelProvider.overrideWithValue(channel),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// 等某条 profile 的 runtime 状态满足条件（依赖 listen，超时即失败）。
Future<EasyTierRuntimeState> waitRuntime(
  ProviderContainer container,
  String profileId,
  bool Function(EasyTierRuntimeState) test,
) {
  final c = Completer<EasyTierRuntimeState>();
  final sub = container.listen(easytierRuntimeProvider(profileId), (_, next) {
    if (test(next) && !c.isCompleted) c.complete(next);
  });
  addTearDown(sub.close);
  return c.future.timeout(const Duration(seconds: 5));
}

/// 常驻监听并等首帧状态（autoDispose 的 family 实例在无监听时会被销毁；
/// 先 listen 再 pump 一帧可保证读取 notifier 时实例已就绪）。
Future<void> keepAlive(ProviderContainer container, String profileId) async {
  final sub = container.listen(easytierRuntimeProvider(profileId), (_, _) {});
  addTearDown(sub.close);
  await pumpEventQueue();
}

void main() {
  setUp(() {
    // 测试不真等 500ms 一拍。
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 10);
  });
  tearDown(() {
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 500);
    EasyTierRuntimeNotifier.virtualIpTimeout = const Duration(seconds: 15);
  });

  group('buildInstanceToml', () {
    test('首行显式 instance_name = profile.id，全部 server 写入 [[peer]]，'
        'no_tun 转发模式', () {
      final toml = buildInstanceToml(profile);
      expect(toml, '''
instance_name = "abcdefgh-1234-5678-9abc-def012345678"
hostname = "herdr-app"
dhcp = true
listeners = []

[network_identity]
network_name = "mynet"
network_secret = "s3cr3t"

[[peer]]
uri = "tcp://10.0.0.2:22023"
[[peer]]
uri = "tcp://vpn.example.com:11010"
[flags]
no_tun = true
disable_upnp = true
''');
    });

    test(r'instance_name 与其他字段中的 \ 和 " 被转义', () {
      const p = RemoteProfile(
        id: '12345678-xxx"x',
        label: 'l',
        server: ['tcp://a"b\\c:11010', 'tcp://plain:11010'],
        networkName: 'net\\"x"',
        secret: 'sec\\"ret"',
        virtualIp: '10.0.0.1',
        port: 80,
      );
      final toml = buildInstanceToml(p);
      expect(toml, contains(r'instance_name = "12345678-xxx\"x"'));
      expect(toml, contains(r'network_name = "net\\\"x\""'));
      expect(toml, contains(r'network_secret = "sec\\\"ret\""'));
      expect(toml, contains(r'uri = "tcp://a\"b\\c:11010"'));
      expect(toml, contains(r'uri = "tcp://plain:11010"'));
    });
  });

  group('connect', () {
    test('成功序列：startInstance → 轮询 → startForwarder → Ready，'
        '无 teardown 性质的 stopInstance', () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);
      final states = <EasyTierRuntimeState>[];
      final sub = container.listen(
          easytierRuntimeProvider(profile.id), (_, s) => states.add(s));
      addTearDown(sub.close);

      final ready = waitRuntime(
          container, profile.id, (s) => s is EasyTierReady || s is EasyTierFailed);
      await notifier.connect(profile);
      final s = await ready;

      expect(states.first, isA<EasyTierConnecting>());
      expect(s, isA<EasyTierReady>().having(
          (s) => s.localPort, 'localPort', 40001));
      expect(channel.calls, [
        'startInstance',
        'currentVirtualIp(${profile.id})', // 第一次 null
        'currentVirtualIp(${profile.id})', // 第二次拿到 10.10.64.62
        'startForwarder(${profile.id},10.10.64.62:46810)',
      ]);
      expect(channel.calls.where((c) => c.startsWith('stop')), isEmpty);
      expect(channel.startedConfigs, [buildInstanceToml(profile)]);
    });

    test('virtualIp 轮询超时 → Failed(等待虚拟 IP 超时)，不再启动转发器', () async {
      EasyTierRuntimeNotifier.virtualIpTimeout =
          const Duration(milliseconds: 100);
      final channel = FakeEasyTierChannel()
        ..virtualIpResults.clear()
        ..virtualIpResults.add(null); // 永远拿不到虚拟 IP，必超时
      final container = makeContainer(channel);

      final failed = waitRuntime(container, profile.id, (s) => s is EasyTierFailed);
      await container
          .read(easytierRuntimeProvider(profile.id).notifier)
          .connect(profile);
      final s = await failed;

      expect((s as EasyTierFailed).message, contains('等待虚拟 IP 超时'));
      expect(
          channel.calls.where((c) => c.startsWith('startForwarder')), isEmpty);
    });

    test('超时失败后容错停本实例，重试 connect 可再次 startInstance', () async {
      EasyTierRuntimeNotifier.virtualIpTimeout =
          const Duration(milliseconds: 100);
      final channel = FakeEasyTierChannel()
        ..virtualIpResults.clear()
        ..virtualIpResults.add(null); // 永远拿不到虚拟 IP，必超时
      final container = makeContainer(channel);
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);

      final failed = waitRuntime(container, profile.id, (s) => s is EasyTierFailed);
      await notifier.connect(profile);
      await failed;

      // startInstance 成功后的失败必须把原生实例停掉，否则同名实例残留，
      // 重试会被 EasyTier 内核以 "instance name already exists" 拒绝。
      expect(channel.calls.last, 'stopInstance(${profile.id})');

      // 恢复虚拟 IP 后重试成功：再次 startInstance 不会被拒绝。
      channel.virtualIpResults.add('10.10.64.62');
      final ready = waitRuntime(container, profile.id, (s) => s is EasyTierReady);
      await notifier.connect(profile);
      await ready;
      expect(channel.startedConfigs, hasLength(2));
    });

    test('startInstance 抛错 → Failed，不轮询不转发', () async {
      final channel = FakeEasyTierChannel()
        ..startInstanceError = PlatformException(code: 'easytier', message: 'boom');
      final container = makeContainer(channel);

      final failed = waitRuntime(container, profile.id, (s) => s is EasyTierFailed);
      await container
          .read(easytierRuntimeProvider(profile.id).notifier)
          .connect(profile);
      final s = await failed;

      expect((s as EasyTierFailed).message, contains('boom'));
      expect(channel.calls,
          isNot(contains(startsWith('currentVirtualIp'))));
      expect(
          channel.calls.where((c) => c.startsWith('startForwarder')), isEmpty);
    });
  });

  group('disconnect', () {
    test('connect 后 disconnect → stopForwarder + stopInstance(id) → '
        'Disconnected', () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);

      final ready = waitRuntime(container, profile.id, (s) => s is EasyTierReady);
      await notifier.connect(profile);
      await ready;
      channel.calls.clear();

      await notifier.disconnect();

      expect(container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierDisconnected>());
      expect(channel.calls,
          ['stopForwarder(40001)', 'stopInstance(${profile.id})']);
    });

    test('重复 disconnect 幂等，不再触达通道', () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      await keepAlive(container, profile.id);
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);

      final ready = waitRuntime(container, profile.id, (s) => s is EasyTierReady);
      await notifier.connect(profile);
      await ready;
      await notifier.disconnect();
      channel.calls.clear();

      await notifier.disconnect();

      expect(channel.calls, isEmpty);
      expect(container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierDisconnected>());
    });
  });

  group('family', () {
    test('两个 profileId 的 family 实例各自独立 connect，互不影响', () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      final notifier1 =
          container.read(easytierRuntimeProvider(profile.id).notifier);
      final notifier2 =
          container.read(easytierRuntimeProvider(profile2.id).notifier);

      final ready1 =
          waitRuntime(container, profile.id, (s) => s is EasyTierReady);
      final ready2 =
          waitRuntime(container, profile2.id, (s) => s is EasyTierReady);
      await notifier1.connect(profile);
      await notifier2.connect(profile2);
      await Future.wait([ready1, ready2]);

      expect(
          container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierReady>());
      expect(
          container.read(easytierRuntimeProvider(profile2.id)),
          isA<EasyTierReady>());
      expect(channel.startedConfigs,
          [buildInstanceToml(profile), buildInstanceToml(profile2)]);
      expect(
          channel.calls
              .where((c) => c.startsWith('startForwarder(${profile.id},')),
          ['startForwarder(${profile.id},10.10.64.62:46810)']);
      expect(
          channel.calls
              .where((c) => c.startsWith('startForwarder(${profile2.id},')),
          ['startForwarder(${profile2.id},10.10.64.99:46811)']);

      // disconnect 一个实例，另一个保持 Ready 且只停本实例。
      channel.calls.clear();
      await notifier1.disconnect();

      expect(container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierDisconnected>());
      expect(container.read(easytierRuntimeProvider(profile2.id)),
          isA<EasyTierReady>());
      expect(channel.calls,
          ['stopForwarder(40001)', 'stopInstance(${profile.id})']);
    });
  });
}
