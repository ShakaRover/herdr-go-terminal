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
  });

  /// 本地生成 uuid，仅在 app 侧标识这条配置。
  final String id;

  /// 展示名；缺省取 networkName 前 8 位。
  final String label;

  /// EasyTier 入口，例 tcp://vpn.example.com:11010。
  final String server;
  final String networkName;
  final String secret;

  /// bridge 在虚拟网里的地址（不含 CIDR 后缀）。
  final String virtualIp;

  /// bridge data-plane 端口。
  final int port;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'server': server,
        'networkName': networkName,
        'secret': secret,
        'virtualIp': virtualIp,
        'port': port,
      };

  factory RemoteProfile.fromJson(Map<String, dynamic> j) => RemoteProfile(
        id: j['id'] is String ? j['id'] as String : '',
        label: j['label'] is String ? j['label'] as String : '',
        server: j['server'] is String ? j['server'] as String : '',
        networkName:
            j['networkName'] is String ? j['networkName'] as String : '',
        secret: j['secret'] is String ? j['secret'] as String : '',
        virtualIp: j['virtualIp'] is String ? j['virtualIp'] as String : '',
        port: j['port'] is int ? j['port'] as int : 0,
      );

  /// 解析二维码载荷。要求 v==1，server/networkName/secret/virtualIp 为非空
  /// String，port 为 1..65535 的 int；未知字段忽略。校验失败抛
  /// [FormatException]。
  factory RemoteProfile.fromPairingJson(Map<String, dynamic> j) {
    if (j['v'] != 1) {
      throw const FormatException('unsupported version');
    }
    final server = _requiredString(j, 'server');
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

  Future<void> _save(List<RemoteProfile> all) => _prefs.setString(
      profileStorePrefsKey, jsonEncode(all.map((p) => p.toJson()).toList()));
}
