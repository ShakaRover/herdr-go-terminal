/// EasyTier Android JNI / iOS C ABI 的 MethodChannel 封装（`dev.herdr/easytier`）。
///
/// 原生侧（MainActivity.kt / AppDelegate.swift）只做转发，参数校验与 JSON
/// 解析都在本层：
/// - 方法全量携带 instanceName（= RemoteProfile.id，见
///   state/easytier_runtime.dart 的 buildInstanceToml），多实例由
///   EasyTier 内核 registry 承载；
/// - 端口转发的 bind/dst IP 必须是合法 IPv4、端口 1..65535，否则抛
///   [ArgumentError]；
/// - `currentVirtualIp` 从原生侧已按实例过滤的 collectNetworkInfos
///   JSON（`{"map": {"<name>": <info>}}`）里取
///   `map.*.my_node_info.virtual_ipv4.address.addr`（u32，网络序）转成点分十进制。
///
/// 端口转发用法：EasyTier 实例以无 TUN 模式嵌入 app，通过管理 RPC
/// `api.config.ConfigRpcService/PatchConfig` 给运行中的实例打 port_forward patch
/// （EasyTier 主线自带能力，内核 socket 监听 + data-plane 拨出），patch 生效后
/// `127.0.0.1:<bindPort>` 即桥接到虚拟网络内的 dstIp:dstPort；REMOVE patch 按
/// bind_addr + proto 匹配即可撤销。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class EasyTierChannel {
  const EasyTierChannel([
    this._channel = const MethodChannel('dev.herdr/easytier'),
  ]);

  final MethodChannel _channel;

  /// 管理 RPC 的服务/方法名（lib.rs 的 dispatch 键；rust 侧 snake_case
  /// 同名方法亦兼容，见 easytier-android-jni 的 callJsonRpc 注释）。
  static const _configRpcService = 'api.config.ConfigRpcService';
  static const _patchConfigMethod = 'PatchConfig';

  /// 以 TOML 配置启动 EasyTier 实例。失败抛 [PlatformException]。
  Future<void> startInstance(String tomlConfig) =>
      _channel.invokeMethod<void>('startInstance', {'config': tomlConfig});

  /// 停止名为 [instanceName] 的 EasyTier 实例（原生侧按名 retain，
  /// 不存在时为 no-op）。
  Future<void> stopInstance(String instanceName) => _channel
      .invokeMethod<void>('stopInstance', {'instanceName': instanceName});

  /// [instanceName] 实例的当前虚拟 IPv4（点分十进制）；
  /// 实例未运行或未分配时返回 null。
  Future<String?> currentVirtualIp(String instanceName) async {
    final json = await _channel.invokeMethod<String>(
        'currentVirtualIp', {'instanceName': instanceName});
    if (json == null || json.isEmpty) return null;
    return _parseVirtualIp(json);
  }

  /// 调试用：返回 [instanceName] 实例的原始 collectNetworkInfos JSON。
  Future<String?> currentVirtualIpRaw(String instanceName) =>
      _channel.invokeMethod<String>(
          'currentVirtualIp', {'instanceName': instanceName});

  /// 在 [instanceName] 实例上打 ADD patch：`127.0.0.1:bindPort` 转发到
  /// 虚拟网络内的 `dstIp:dstPort`（TCP）。失败抛 [PlatformException]。
  Future<void> addPortForward(String instanceName,
      {required String bindIp,
      required int bindPort,
      required String dstIp,
      required int dstPort}) async {
    _checkIPv4(bindIp, 'bindIp');
    _checkIPv4(dstIp, 'dstIp');
    _checkPort(bindPort, 'bindPort');
    _checkPort(dstPort, 'dstPort');
    await _patchConfig(instanceName, {
      'action': 'ADD',
      'cfg': {
        'bind_addr': _socketAddr(bindIp, bindPort),
        'dst_addr': _socketAddr(dstIp, dstPort),
        'socket_type': 'TCP',
      },
    });
  }

  /// 撤销 [addPortForward] 加的转发。REMOVE 按整条 PortForwardConfig 相等
  /// 匹配（core `patch_vec` 的语义），因此必须带上与 ADD 相同的 dst。
  Future<void> removePortForward(String instanceName,
      {required String bindIp,
      required int bindPort,
      required String dstIp,
      required int dstPort}) async {
    _checkIPv4(bindIp, 'bindIp');
    _checkIPv4(dstIp, 'dstIp');
    _checkPort(bindPort, 'bindPort');
    _checkPort(dstPort, 'dstPort');
    await _patchConfig(instanceName, {
      'action': 'REMOVE',
      'cfg': {
        'bind_addr': _socketAddr(bindIp, bindPort),
        'dst_addr': _socketAddr(dstIp, dstPort),
        'socket_type': 'TCP',
      },
    });
  }

  Future<void> _patchConfig(
      String instanceName, Map<String, Object?> portForwardPatch) async {
    final response = await _channel.invokeMethod<String>('callJsonRpc', {
      'service': _configRpcService,
      'method': _patchConfigMethod,
      'payload': jsonEncode({
        'patch': {
          'port_forwards': [portForwardPatch],
        },
        'instance': {
          'instance_selector': {'name': instanceName},
        },
      }),
    });
    if (response == null) {
      throw PlatformException(
          code: 'easytier', message: 'callJsonRpc 返回空响应');
    }
  }

  /// `{"ipv4": {"addr": <网络序 u32>}, "port": port}` 的 SocketAddr pbjson。
  static Map<String, Object?> _socketAddr(String ip, int port) => {
        'ipv4': {'addr': _ipv4ToU32(ip)},
        'port': port,
      };

  /// 点分十进制 → 网络序 u32（`_u32ToIPv4` 的逆运算）。
  static int _ipv4ToU32(String ip) {
    final parts = ip.split('.').map(int.parse).toList();
    return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
  }

  static void _checkIPv4(String ip, String name) {
    final addr = InternetAddress.tryParse(ip);
    if (addr == null || addr.type != InternetAddressType.IPv4) {
      throw ArgumentError.value(ip, name, '必须是合法 IPv4 地址');
    }
  }

  static void _checkPort(int port, String name) {
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, name, '端口须在 1..65535');
    }
  }

  /// collectNetworkInfos JSON → 点分十进制虚拟 IP。
  /// 形状：`{"map": {"<实例名>": {"running": true, "my_node_info":
  /// {"virtual_ipv4": {"address": {"addr": u32}, ...}}}}`，addr 为网络序。
  // 以真机 JSON 为准（字段来自 easytier-proto 的 pbjson serde，snake_case）。
  static String? _parseVirtualIp(String jsonStr) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonStr);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final map = decoded['map'];
    if (map is! Map<String, dynamic>) return null;
    for (final info in map.values) {
      if (info is! Map<String, dynamic> || info['running'] != true) continue;
      final node = info['my_node_info'];
      if (node is! Map<String, dynamic>) continue;
      final v4 = node['virtual_ipv4'];
      if (v4 is! Map<String, dynamic>) continue;
      final address = v4['address'];
      if (address is! Map<String, dynamic>) continue;
      final addr = address['addr'];
      if (addr is int) return _u32ToIPv4(addr);
    }
    return null;
  }

  static String _u32ToIPv4(int addr) =>
      '${addr >> 24 & 0xff}.${addr >> 16 & 0xff}.${addr >> 8 & 0xff}.${addr & 0xff}';
}
