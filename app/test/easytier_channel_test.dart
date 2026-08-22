/// easytier_channel 的 MethodChannel 契约测试。
///
/// 用 TestDefaultBinaryMessenger mock `dev.herdr/easytier` 通道，断言：
/// - 每个方法发出的调用名与参数 map；
/// - currentVirtualIp 从 collectNetworkInfos JSON 解析出点分十进制虚拟 IP；
/// - targetIp/端口的非法参数在 Dart 侧抛 ArgumentError（不触达原生）；
/// - 原生侧 PlatformException 原样传播。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/api/easytier_channel.dart';

class _Harness {
  _Harness() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      final error = nextError;
      if (error != null) {
        nextError = null;
        throw error;
      }
      return nextResult;
    });
  }

  static const _channel = MethodChannel('dev.herdr/easytier');

  final calls = <MethodCall>[];
  Object? nextResult;
  PlatformException? nextError;

  EasyTierChannel create({String instanceName = 'default'}) =>
      EasyTierChannel(const MethodChannel('dev.herdr/easytier'), instanceName);

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// collectNetworkInfos 的真实 JSON 形状（pbjson，snake_case），
/// addr = 0x0A0A403E = 10.10.64.62。以真机 JSON 为准。
const _infosJson = '{"map":{"default":{"running":true,"my_node_info":{'
    '"virtual_ipv4":{"address":{"addr":168443966},"network_length":24}}}}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  test('startInstance 发 startInstance 与 config 参数', () async {
    await h.create().startInstance('instance_name = "default"');
    expect(h.calls, hasLength(1));
    expect(h.calls.single.method, 'startInstance');
    expect(h.calls.single.arguments,
        {'config': 'instance_name = "default"'});
  });

  test('stopInstance 发 stopInstance，无参数', () async {
    await h.create().stopInstance();
    expect(h.calls.single.method, 'stopInstance');
    expect(h.calls.single.arguments, isNull);
  });

  test('currentVirtualIp 解析 my_node_info.virtual_ipv4 为点分十进制', () async {
    h.nextResult = _infosJson;
    expect(await h.create().currentVirtualIp(), '10.10.64.62');
    expect(h.calls.single.method, 'currentVirtualIp');
  });

  test('currentVirtualIp：null/空 map/未 running 都返回 null', () async {
    h.nextResult = null;
    expect(await h.create().currentVirtualIp(), isNull);

    h.nextResult = '{"map":{}}';
    expect(await h.create().currentVirtualIp(), isNull);

    h.nextResult = '{"map":{"default":{"running":false,"my_node_info":{'
        '"virtual_ipv4":{"address":{"addr":168443966}}}}}}';
    expect(await h.create().currentVirtualIp(), isNull);
  });

  test('startForwarder 发实例名/目标/端口，返回本地端口', () async {
    h.nextResult = 40001;
    final port = await h.create(instanceName: 'inst1')
        .startForwarder('10.10.64.62', 8080);
    expect(port, 40001);
    expect(h.calls.single.method, 'startForwarder');
    expect(h.calls.single.arguments, {
      'instanceName': 'inst1',
      'targetIp': '10.10.64.62',
      'targetPort': 8080,
    });
  });

  test('startForwarder 默认实例名为 default', () async {
    h.nextResult = 1;
    await h.create().startForwarder('10.0.0.1', 80);
    expect(h.calls.single.arguments, containsPair('instanceName', 'default'));
  });

  test('startForwarder：非法 IP/端口抛 ArgumentError 且不触达通道', () async {
    final api = h.create();
    for (final badIp in ['', 'abc', '999.1.2.3', '::1', '10.0.0.256']) {
      expect(() => api.startForwarder(badIp, 80), throwsArgumentError);
    }
    for (final badPort in [0, -1, 65536]) {
      expect(() => api.startForwarder('10.0.0.1', badPort),
          throwsArgumentError);
    }
    expect(h.calls, isEmpty);
  });

  test('startForwarder：原生返回非法端口抛 PlatformException', () async {
    h.nextResult = null;
    expect(() => h.create().startForwarder('10.0.0.1', 80),
        throwsA(isA<PlatformException>()));
    h.nextResult = -1;
    expect(() => h.create().startForwarder('10.0.0.1', 80),
        throwsA(isA<PlatformException>()));
  });

  test('stopForwarder 发 localPort；非法端口抛 ArgumentError', () async {
    await h.create().stopForwarder(40001);
    expect(h.calls.single.method, 'stopForwarder');
    expect(h.calls.single.arguments, {'localPort': 40001});

    expect(() => h.create().stopForwarder(0), throwsArgumentError);
    expect(() => h.create().stopForwarder(70000), throwsArgumentError);
  });

  test('原生 PlatformException 原样传播', () async {
    h.nextError = PlatformException(code: 'easytier', message: 'boom');
    expect(() => h.create().startInstance(''),
        throwsA(isA<PlatformException>()
            .having((e) => e.message, 'message', 'boom')));
  });
}
