/// EasyTier Android JNI 的 MethodChannel 封装（`dev.herdr/easytier`）。
///
/// Kotlin 侧（MainActivity）只做转发，参数校验与 JSON 解析都在本层：
/// - 转发器目标 IP 必须是合法 IPv4、端口 1..65535，否则抛 [ArgumentError]；
/// - `currentVirtualIp` 从 collectNetworkInfos 的 JSON 里取
///   `map.*.my_node_info.virtual_ipv4.address.addr`（u32，网络序）转成点分十进制。
///
/// 转发器用法：EasyTier 实例以无 TUN 模式嵌入 app，启动转发器后
/// `127.0.0.1:<返回的本地端口>` 即桥接到虚拟网络内的 targetIp:targetPort。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class EasyTierChannel {
  EasyTierChannel([
    this._channel = const MethodChannel('dev.herdr/easytier'),
    // EasyTier 配置不显式指定 instance_name 时的默认值。
    this.instanceName = 'default',
  ]);

  final MethodChannel _channel;

  /// 转发器作用的 EasyTier 实例名（须与启动配置里的 instance_name 一致）。
  final String instanceName;

  /// 以 TOML 配置启动 EasyTier 实例。失败抛 [PlatformException]。
  Future<void> startInstance(String tomlConfig) =>
      _channel.invokeMethod<void>('startInstance', {'config': tomlConfig});

  /// 停止所有 EasyTier 实例。
  Future<void> stopInstance() => _channel.invokeMethod<void>('stopInstance');

  /// 当前虚拟 IPv4（点分十进制）；无运行实例或未分配时返回 null。
  Future<String?> currentVirtualIp() async {
    final json = await _channel.invokeMethod<String>('currentVirtualIp');
    if (json == null || json.isEmpty) return null;
    return _parseVirtualIp(json);
  }

  /// 启动本地 TCP 转发器，返回实际监听的本地端口（127.0.0.1:port）。
  Future<int> startForwarder(String targetIp, int targetPort) async {
    _checkIPv4(targetIp, 'targetIp');
    _checkPort(targetPort, 'targetPort');
    final port = await _channel.invokeMethod<int>('startForwarder', {
      'instanceName': instanceName,
      'targetIp': targetIp,
      'targetPort': targetPort,
    });
    if (port == null || port <= 0) {
      throw PlatformException(
          code: 'easytier', message: 'startForwarder 返回非法端口: $port');
    }
    return port;
  }

  /// 停止 [startForwarder] 返回的本地端口对应的转发器。
  Future<void> stopForwarder(int localPort) {
    _checkPort(localPort, 'localPort');
    return _channel.invokeMethod<void>('stopForwarder', {'localPort': localPort});
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
