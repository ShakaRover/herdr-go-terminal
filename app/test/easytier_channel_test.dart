/// easytier_channel 的 MethodChannel 契约测试。
///
/// 用 TestDefaultBinaryMessenger mock `dev.herdr/easytier` 通道，断言：
/// - 每个方法发出的调用名与参数 map（instanceName 全量携带）；
/// - currentVirtualIp 从已过滤实例的 collectNetworkInfos JSON 解析出
///   点分十进制虚拟 IP；
/// - targetIp/端口的非法参数在 Dart 侧抛 ArgumentError（不触达原生）；
/// - 原生侧 PlatformException 原样传播。
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/easytier_channel.dart';

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

  EasyTierChannel create() =>
      EasyTierChannel(const MethodChannel('dev.herdr/easytier'));

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

/// collectNetworkInfos 过滤后的真实 JSON 形状（pbjson，snake_case），
/// addr = 0x0A0A403E = 10.10.64.62。以真机 JSON 为准。
const _infosJson = '{"map":{"inst1":{"running":true,"my_node_info":{'
    '"virtual_ipv4":{"address":{"addr":168443966},"network_length":24}}}}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  test('startInstance 发 startInstance 与 config 参数', () async {
    await h.create().startInstance('instance_name = "inst1"');
    expect(h.calls, hasLength(1));
    expect(h.calls.single.method, 'startInstance');
    expect(h.calls.single.arguments,
        {'config': 'instance_name = "inst1"'});
  });

  test('stopInstance 发 stopInstance 与 instanceName 参数', () async {
    await h.create().stopInstance('inst1');
    expect(h.calls.single.method, 'stopInstance');
    expect(h.calls.single.arguments, {'instanceName': 'inst1'});
  });

  test('currentVirtualIp 解析 my_node_info.virtual_ipv4 为点分十进制', () async {
    h.nextResult = _infosJson;
    expect(await h.create().currentVirtualIp('inst1'), '10.10.64.62');
    expect(h.calls.single.method, 'currentVirtualIp');
    expect(h.calls.single.arguments, {'instanceName': 'inst1'});
  });

  test('currentVirtualIp：null/空 map/未 running 都返回 null', () async {
    h.nextResult = null;
    expect(await h.create().currentVirtualIp('inst1'), isNull);

    h.nextResult = '{"map":{}}';
    expect(await h.create().currentVirtualIp('inst1'), isNull);

    h.nextResult = '{"map":{"inst1":{"running":false,"my_node_info":{'
        '"virtual_ipv4":{"address":{"addr":168443966}}}}}}';
    expect(await h.create().currentVirtualIp('inst1'), isNull);
  });

  test('addPortForward 发 PatchConfig ADD，IPv4 编码为网络序 u32', () async {
    h.nextResult = '{}'; // callJsonRpc 的空 JSON 响应
    await h.create().addPortForward('inst1',
        bindIp: '127.0.0.1',
        bindPort: 45678,
        dstIp: '10.10.64.62',
        dstPort: 8787);
    expect(h.calls.single.method, 'callJsonRpc');
    expect(h.calls.single.arguments['service'], 'api.config.ConfigRpc');
    expect(h.calls.single.arguments['method'], 'PatchConfig');
    expect(jsonDecode(h.calls.single.arguments['payload'] as String), {
      'patch': {
        'port_forwards': [
          {
            'action': 'ADD',
            'cfg': {
              // 0x7F000001 = 127.0.0.1，0x0A0A403E = 10.10.64.62。
              'bind_addr': {
                'ipv4': {'addr': 0x7F000001},
                'port': 45678,
              },
              'dst_addr': {
                'ipv4': {'addr': 0x0A0A403E},
                'port': 8787,
              },
              'socket_type': 'TCP',
            },
          }
        ],
      },
      'instance': {
        'instance_selector': {'name': 'inst1'},
      },
    });
  });

  test('removePortForward 发 REMOVE，cfg 必须复现 ADD 的 bind+dst', () async {
    h.nextResult = '{}';
    await h.create().removePortForward('inst1',
        bindIp: '127.0.0.1',
        bindPort: 45678,
        dstIp: '10.10.64.62',
        dstPort: 8787);
    final payload =
        jsonDecode(h.calls.single.arguments['payload'] as String) as Map<String, Object?>;
    expect(
        ((payload['patch'] as Map)['port_forwards'] as List)
            .single['action'],
        'REMOVE');
  });

  test('端口转发：非法 IP/端口抛 ArgumentError 且不触达通道', () async {
    final api = h.create();
    for (final badIp in ['', 'abc', '999.1.2.3', '::1', '10.0.0.256']) {
      expect(
          () => api.addPortForward('inst1',
              bindIp: badIp,
              bindPort: 80,
              dstIp: '10.0.0.1',
              dstPort: 80),
          throwsArgumentError);
      expect(
          () => api.removePortForward('inst1',
              bindIp: '10.0.0.1',
              bindPort: 80,
              dstIp: badIp,
              dstPort: 80),
          throwsArgumentError);
    }
    for (final badPort in [0, -1, 65536]) {
      expect(
          () => api.addPortForward('inst1',
              bindIp: '127.0.0.1',
              bindPort: badPort,
              dstIp: '10.0.0.1',
              dstPort: 80),
          throwsArgumentError);
    }
    expect(h.calls, isEmpty);
  });

  test('callJsonRpc：原生返回空响应抛 PlatformException', () async {
    h.nextResult = null;
    expect(
        () => h.create().addPortForward('inst1',
            bindIp: '127.0.0.1',
            bindPort: 80,
            dstIp: '10.0.0.1',
            dstPort: 80),
        throwsA(isA<PlatformException>()));
  });

  test('原生 PlatformException 原样传播', () async {
    h.nextError = PlatformException(code: 'easytier', message: 'boom');
    expect(() => h.create().startInstance(''),
        throwsA(isA<PlatformException>()
            .having((e) => e.message, 'message', 'boom')));
  });
}
