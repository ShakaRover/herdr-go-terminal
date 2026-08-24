/// easytier_runtime 状态机与 TOML 生成的测试。
///
/// 用 fake EasyTierChannel（easytierChannelProvider override）验证：
/// - buildInstanceToml 显式写 instance_name = profile.id，全部 server 写入
///   `[[peer]]` 数组，字段与转义行为；
/// - connect 调用序列：startInstance → 轮询 currentVirtualIp(profileId) →
///   addPortForward(profileId, `127.0.0.1:<picked>` → virtualIp:port) →
///   bridge API 可达 → Ready（无 teardown 性质的 stopInstance）；
/// - virtualIp 轮询超时 → Failed；startInstance 抛错 → Failed；
/// - disconnect → removePortForward(ADD 时的完整 cfg) +
///   stopInstance(profileId)；
/// - family(profileId) 的两个实例各自独立 connect，调用序列互不影响。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/easytier_channel.dart';
import 'package:herdrgo/model/remote_profile.dart';
import 'package:herdrgo/state/easytier_runtime.dart';

/// 脚本化的 EasyTierChannel：记录调用顺序（含 instanceName），
/// 按队列吐出 virtualIp 结果。bind 端口由 runtime 真实抢占，fake 只记录。
class FakeEasyTierChannel extends EasyTierChannel {
  FakeEasyTierChannel()
      : super(const MethodChannel('dev.herdr/easytier-test'));

  final calls = <String>[];
  final startedConfigs = <String>[];

  /// 每次 currentVirtualIp 弹一个；取空后反复吐最后一个，永不超时。
  final virtualIpResults = <String?>[null, '10.10.64.62'];
  Object? startInstanceError;
  Completer<void>? startInstanceGate;
  Completer<void>? addPortForwardGate;
  Completer<void>? removePortForwardGate;
  final addPortForwardErrors = <Object>[];

  /// 最近一次 ADD 的 bind 端口（= Ready.localPort）。
  int? lastBindPort;

  /// 每个实例最近一次 ADD 的 bind 端口（family 多实例断言用）。
  final bindPorts = <String, int>{};

  @override
  Future<void> startInstance(String tomlConfig) async {
    calls.add('startInstance');
    startedConfigs.add(tomlConfig);
    await startInstanceGate?.future;
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
  Future<String?> currentVirtualIpRaw(String instanceName) =>
      currentVirtualIp(instanceName);

  @override
  Future<void> addPortForward(String instanceName,
      {required String bindIp,
      required int bindPort,
      required String dstIp,
      required int dstPort}) async {
    calls.add('addPortForward($instanceName,$bindIp:$bindPort->$dstIp:$dstPort)');
    await addPortForwardGate?.future;
    if (addPortForwardErrors.isNotEmpty) {
      throw addPortForwardErrors.removeAt(0);
    }
    lastBindPort = bindPort;
    bindPorts[instanceName] = bindPort;
  }

  @override
  Future<void> removePortForward(String instanceName,
      {required String bindIp,
      required int bindPort,
      required String dstIp,
      required int dstPort}) async {
    calls.add(
        'removePortForward($instanceName,$bindIp:$bindPort->$dstIp:$dstPort)');
    await removePortForwardGate?.future;
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
    bridgeReachabilityProbeProvider.overrideWithValue((_, _) async => true),
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

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('等待测试条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // 测试不真等生产间隔。
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 10);
    EasyTierRuntimeNotifier.bridgeProbeInterval =
        const Duration(milliseconds: 10);
  });
  tearDown(() {
    EasyTierRuntimeNotifier.pollInterval = const Duration(milliseconds: 250);
    EasyTierRuntimeNotifier.virtualIpTimeout = const Duration(seconds: 15);
    EasyTierRuntimeNotifier.bridgeProbeInterval =
        const Duration(milliseconds: 300);
    EasyTierRuntimeNotifier.bridgeProbeTimeout = const Duration(seconds: 1);
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
    test('成功序列：startInstance → 轮询 → addPortForward → Ready，'
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
      expect(s, isA<EasyTierReady>());
      // Ready 的 localPort 就是 runtime 抢占后交给 PatchConfig bind 的端口。
      expect((s as EasyTierReady).localPort, channel.lastBindPort);
      expect(channel.calls.length, 4);
      expect(channel.calls[0], 'startInstance');
      expect(channel.calls[1], 'currentVirtualIp(${profile.id})'); // 第一次 null
      expect(channel.calls[2], 'currentVirtualIp(${profile.id})'); // 第二次拿到 IP
      // bind 在 127.0.0.1 随机端口，dst 是 pairing 里的虚拟 IP:port。
      expect(channel.calls[3],
          'addPortForward(${profile.id},127.0.0.1:${channel.lastBindPort}'
          '->${profile.virtualIp}:${profile.port})');
      expect(channel.calls.where((c) => c.startsWith('stop')), isEmpty);
      expect(channel.startedConfigs, [buildInstanceToml(profile)]);
    });

    test('端口转发后持续探测 bridge，实际可达才进入 Ready', () async {
      final channel = FakeEasyTierChannel();
      final probeResults = <bool>[false, false, true];
      final probedPorts = <int>[];
      final container = ProviderContainer(overrides: [
        easytierChannelProvider.overrideWithValue(channel),
        bridgeReachabilityProbeProvider.overrideWithValue((port, _) async {
          probedPorts.add(port);
          return probeResults.removeAt(0);
        }),
      ]);
      addTearDown(container.dispose);

      final ready =
          waitRuntime(container, profile.id, (s) => s is EasyTierReady);
      await container
          .read(easytierRuntimeProvider(profile.id).notifier)
          .connect(profile);
      final state = await ready;

      expect(probedPorts, [
        channel.lastBindPort,
        channel.lastBindPort,
        channel.lastBindPort,
      ]);
      expect((state as EasyTierReady).localPort, channel.lastBindPort);
    });

    test('virtualIp 轮询超时 → Failed(等待虚拟 IP 超时)，不再打转发 patch', () async {
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
          channel.calls.where((c) => c.startsWith('addPortForward')), isEmpty);
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
          channel.calls.where((c) => c.startsWith('addPortForward')), isEmpty);
    });
  });

  group('disconnect', () {
    test('connect 后 disconnect → removePortForward + stopInstance(id) → '
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
      // REMOVE 必须复现 ADD 时的完整 cfg（bind+dst）。
      expect(channel.calls, [
        'removePortForward(${profile.id},127.0.0.1:${channel.lastBindPort}'
            '->${profile.virtualIp}:${profile.port})',
        'stopInstance(${profile.id})',
      ]);
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

  group('port-forward lifecycle', () {
    test('后台只撤销转发，回前台重建 listener，不重启 EasyTier 实例',
        () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      await keepAlive(container, profile.id);
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);

      await notifier.connect(profile);
      final firstPort =
          (container.read(easytierRuntimeProvider(profile.id)) as EasyTierReady)
              .localPort;
      channel.calls.clear();

      await notifier.suspendPortForward();

      expect(container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierForwardSuspended>());
      expect(channel.calls, [
        'removePortForward(${profile.id},127.0.0.1:$firstPort'
            '->${profile.virtualIp}:${profile.port})',
      ]);

      channel.calls.clear();
      await notifier.resumePortForward();

      final resumed = container.read(easytierRuntimeProvider(profile.id));
      expect(resumed, isA<EasyTierReady>());
      expect(channel.calls, [
        startsWith('addPortForward(${profile.id},127.0.0.1:'),
      ]);
      expect(channel.calls.single,
          endsWith('->${profile.virtualIp}:${profile.port})'));
      expect(channel.calls.where((c) => c.startsWith('startInstance')), isEmpty);
      expect(channel.calls.where((c) => c.startsWith('stopInstance')), isEmpty);
    });

    test('快速回前台时，等待后台 REMOVE 完成后才 ADD', () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      await keepAlive(container, profile.id);
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);
      await notifier.connect(profile);
      channel.calls.clear();

      final removeGate = Completer<void>();
      channel.removePortForwardGate = removeGate;
      final suspend = notifier.suspendPortForward();
      await pumpEventQueue();
      final resume = notifier.resumePortForward();
      await pumpEventQueue();

      expect(channel.calls, hasLength(1));
      expect(channel.calls.single, startsWith('removePortForward'));

      removeGate.complete();
      await Future.wait([suspend, resume]);
      expect(channel.calls, hasLength(2));
      expect(channel.calls[0], startsWith('removePortForward'));
      expect(channel.calls[1], startsWith('addPortForward'));
      expect(container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierReady>());
    });

    test('回前台 ADD 瞬时失败后短周期重试，不进入永久 Failed', () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      await keepAlive(container, profile.id);
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);
      await notifier.connect(profile);
      await notifier.suspendPortForward();
      channel.calls.clear();
      channel.addPortForwardErrors.add(StateError('temporary ADD failure'));

      await notifier.resumePortForward();

      expect(container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierReady>());
      expect(channel.calls.where((c) => c.startsWith('addPortForward')),
          hasLength(2));
      expect(channel.calls.where((c) => c.startsWith('removePortForward')),
          hasLength(1),
          reason: '首次 ADD 可能已生效，重试前应按原配置容错撤销');
      expect(channel.calls.where((c) => c.startsWith('stopInstance')), isEmpty);
    });
  });

  group('autoDispose cleanup', () {
    test('启动中销毁 provider：等待 startInstance 返回后再 stop', () async {
      final channel = FakeEasyTierChannel();
      final container = makeContainer(channel);
      final sub = container.listen(
          easytierRuntimeProvider(profile.id), (_, _) {});
      await pumpEventQueue();
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);
      final startGate = Completer<void>();
      channel.startInstanceGate = startGate;
      final connect = notifier.connect(profile);
      await pumpEventQueue();

      sub.close();
      await pumpEventQueue();
      expect(channel.calls.where((c) => c.startsWith('stopInstance')), isEmpty,
          reason: 'start 尚未返回时不能先发一个会 no-op 的 stop');

      startGate.complete();
      await connect;
      await waitUntil(() => channel.calls
          .contains('stopInstance(${profile.id})'));
      expect(channel.calls.first, 'startInstance');
      expect(channel.calls.last, 'stopInstance(${profile.id})');
    });

    test('恢复探测中销毁 provider：取消探测、撤销 listener 并 stop', () async {
      var reachable = true;
      var probeCount = 0;
      final channel = FakeEasyTierChannel();
      final container = ProviderContainer(overrides: [
        easytierChannelProvider.overrideWithValue(channel),
        bridgeReachabilityProbeProvider.overrideWithValue((_, _) async {
          probeCount++;
          return reachable;
        }),
      ]);
      addTearDown(container.dispose);
      final sub = container.listen(
          easytierRuntimeProvider(profile.id), (_, _) {});
      await pumpEventQueue();
      final notifier =
          container.read(easytierRuntimeProvider(profile.id).notifier);
      await notifier.connect(profile);
      await notifier.suspendPortForward();
      reachable = false;
      final resume = notifier.resumePortForward();
      await waitUntil(() => probeCount >= 2);

      sub.close();
      await pumpEventQueue();
      await resume;
      await waitUntil(() => channel.calls
          .contains('stopInstance(${profile.id})'));

      expect(channel.calls.where((c) => c.startsWith('removePortForward')),
          hasLength(2),
          reason: '后台撤销一次，dispose 再撤销恢复阶段的新 listener');
      final countAfterDispose = probeCount;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(probeCount, countAfterDispose,
          reason: 'provider 销毁后不能继续可达性探测');
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
      final notifier1Port = channel.bindPorts[profile.id];

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
              .where((c) => c.startsWith('addPortForward(${profile.id},')),
          ['addPortForward(${profile.id},127.0.0.1:${channel.bindPorts[profile.id]}'
              '->${profile.virtualIp}:${profile.port})']);
      // profile2 的转发 dst 不同，且 bind 端口独立。
      final p2Calls = channel.calls
          .where((c) => c.startsWith('addPortForward(${profile2.id},'))
          .toList();
      expect(p2Calls, hasLength(1));
      expect(p2Calls.single, contains('->${profile2.virtualIp}:${profile2.port})'));
      expect(channel.bindPorts[profile2.id],
          isNot(equals(channel.bindPorts[profile.id])));

      // disconnect 一个实例，另一个保持 Ready 且只停本实例。
      channel.calls.clear();
      await notifier1.disconnect();

      expect(container.read(easytierRuntimeProvider(profile.id)),
          isA<EasyTierDisconnected>());
      expect(container.read(easytierRuntimeProvider(profile2.id)),
          isA<EasyTierReady>());
      expect(channel.calls, [
        'removePortForward(${profile.id},127.0.0.1:$notifier1Port'
            '->${profile.virtualIp}:${profile.port})',
        'stopInstance(${profile.id})',
      ]);
    });
  });
}
