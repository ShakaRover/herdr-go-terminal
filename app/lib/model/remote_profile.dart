import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 一个远端 bridge 的配对信息，来自扫码（bridge 打印的 EasyTier 配对二维码，
/// 见 bridge easytier_net::pairing_payload）。持久化在 shared_preferences。
class RemoteProfile {
  const RemoteProfile({
    required this.id,
    required this.label,
    required this.server,
    required this.networkName,
    required this.secret,
    required this.virtualIp,
    required this.port,
    this.enabled = true,
  });

  /// 本地生成 uuid，仅在 app 侧标识这条配置。
  final String id;

  /// 展示名；缺省取 networkName 前 8 位。
  final String label;

  /// EasyTier 入口列表（多 peer：内网监听地址 + 公网中继），
  /// 例 [tcp://10.0.0.2:22023, tcp://vpn.example.com:11010]。
  final List<String> server;
  final String networkName;
  final String secret;

  /// bridge 在虚拟网里的地址（不含 CIDR 后缀）。
  final String virtualIp;

  /// bridge data-plane 端口。
  final int port;

  /// 是否参与多 bridge 连接；旧数据缺该字段视为 true。
  final bool enabled;

  RemoteProfile copyWith({String? label, bool? enabled}) => RemoteProfile(
        id: id,
        label: label ?? this.label,
        server: server,
        networkName: networkName,
        secret: secret,
        virtualIp: virtualIp,
        port: port,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'server': server,
        'networkName': networkName,
        'secret': secret,
        'virtualIp': virtualIp,
        'port': port,
        'enabled': enabled,
      };

  factory RemoteProfile.fromJson(Map<String, dynamic> j) => RemoteProfile(
        id: j['id'] is String ? j['id'] as String : '',
        label: j['label'] is String ? j['label'] as String : '',
        server: _serverFromJson(j['server']),
        networkName:
            j['networkName'] is String ? j['networkName'] as String : '',
        secret: j['secret'] is String ? j['secret'] as String : '',
        virtualIp: j['virtualIp'] is String ? j['virtualIp'] as String : '',
        port: j['port'] is int ? j['port'] as int : 0,
        enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
      );

  /// 兼容旧格式：server 曾是单值字符串，读到时包成单元素数组。
  static List<String> _serverFromJson(Object? v) {
    if (v is String) return v.isEmpty ? const [] : [v];
    if (v is List) return v.whereType<String>().toList();
    return const [];
  }

  /// 解析二维码载荷。要求 v==1，server 为非空字符串数组（兼容旧版二维码的
  /// 单值字符串，包成单元素数组），networkName/secret/virtualIp 为非空
  /// String，port 为 1..65535 的 int；未知字段忽略。校验失败抛
  /// [FormatException]。
  factory RemoteProfile.fromPairingJson(Map<String, dynamic> j) {
    if (j['v'] != 1) {
      throw const FormatException('unsupported version');
    }
    final server = _requiredServerList(j, 'server');
    final networkName = _requiredString(j, 'networkName');
    final secret = _requiredString(j, 'secret');
    final virtualIp = _requiredString(j, 'virtualIp');
    final port = j['port'];
    if (port is! int || port < 1 || port > 65535) {
      throw const FormatException('invalid port');
    }
    final rawLabel = j['label'];
    final label = (rawLabel is String && rawLabel.trim().isNotEmpty)
        ? rawLabel.trim()
        : networkName.substring(0, networkName.length < 8 ? networkName.length : 8);
    return RemoteProfile(
      id: const Uuid().v4(),
      label: label,
      server: server,
      networkName: networkName,
      secret: secret,
      virtualIp: virtualIp,
      port: port,
    );
  }

  static String _requiredString(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v is! String || v.isEmpty) {
      throw FormatException('missing or invalid $key');
    }
    return v;
  }

  /// 二维码里的 server：非空字符串数组；兼容旧版二维码的单值字符串。
  static List<String> _requiredServerList(Map<String, dynamic> j, String key) {
    final v = j[key];
    if (v is String) {
      if (v.isEmpty) throw FormatException('missing or invalid $key');
      return [v];
    }
    if (v is List &&
        v.isNotEmpty &&
        v.every((e) => e is String && e.isNotEmpty)) {
      return v.cast<String>().toList();
    }
    throw FormatException('missing or invalid $key');
  }
}

/// shared_preferences 里的 profile 列表键。
const profileStorePrefsKey = 'bridge_profiles_v1';

/// RemoteProfile 的持久化仓库：JSON list 存在 shared_preferences。
class ProfileStore {
  ProfileStore(this._prefs);

  final SharedPreferences _prefs;

  Future<List<RemoteProfile>> list() async {
    final raw = _prefs.getString(profileStorePrefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(RemoteProfile.fromJson)
          .toList();
    } catch (_) {
      // 损坏的持久化数据按空处理。
      return [];
    }
  }

  /// 追加一条 profile，返回写入后的实例（含 id）。
  Future<RemoteProfile> add(RemoteProfile profile) async {
    final all = await list();
    all.add(profile);
    await _save(all);
    return profile;
  }

  Future<void> remove(String id) async {
    final all = await list();
    all.removeWhere((p) => p.id == id);
    await _save(all);
  }

  Future<RemoteProfile?> getById(String id) async {
    for (final p in await list()) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 更新单条 profile 的 enabled 并重写列表。
  Future<void> setEnabled(String id, bool enabled) async {
    final all = await list();
    var found = false;
    for (var i = 0; i < all.length; i++) {
      if (all[i].id == id) {
        all[i] = all[i].copyWith(enabled: enabled);
        found = true;
        break;
      }
    }
    if (found) await _save(all);
  }

  Future<void> _save(List<RemoteProfile> all) => _prefs.setString(
      profileStorePrefsKey, jsonEncode(all.map((p) => p.toJson()).toList()));
}
