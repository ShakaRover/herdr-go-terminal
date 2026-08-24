/// EasyTier 连接生命周期：每条 RemoteProfile 一个内嵌 EasyTier 实例 +
/// 本地 TCP 转发器，`127.0.0.1:<localPort>` 即桥接到该 profile 的 bridge。
///
/// 状态机：Disconnected → Connecting → Ready(localPort) / Failed(message)。
/// easytierRuntimeProvider 是 family(profileId) 的 autoDispose notifier：
/// 由 bridgesProvider（Task 7）对每条 enabled profile 读
/// easytierRuntimeProvider(profile.id) 并调 connect/disconnect；
/// 本层不 listen settingsProvider，不做任何自动连接。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/easytier_channel.dart';
import '../model/remote_profile.dart';

/// 生产/测试可替换的 EasyTier 通道（测试 override 成 fake）。
final easytierChannelProvider =
    Provider<EasyTierChannel>((_) => const EasyTierChannel());

/// 端口转发建立后，从本地回环端口探测 bridge API 是否已端到端可达。
typedef BridgeReachabilityProbe = Future<bool> Function(
    int localPort, Duration timeout);

final bridgeReachabilityProbeProvider = Provider<BridgeReachabilityProbe>(
    (_) => _probeBridgeReachability);

Future<bool> _probeBridgeReachability(
    int localPort, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await (() async {
      final origin = 'http://127.0.0.1:$localPort';
      final request = await client.getUrl(Uri.parse('$origin/api/v1/config'));
      request.headers.set('x-requested-with', 'XMLHttpRequest');
      request.headers.set('Origin', origin);
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    })()
        .timeout(timeout);
  } on SocketException {
    return false;
  } on HttpException {
    return false;
  } on TimeoutException {
    return false;
  } finally {
    client.close(force: true);
  }
}

sealed class EasyTierRuntimeState {
  const EasyTierRuntimeState();
}

/// 未连接（或已断开），该 profile 没有 EasyTier 实例在跑。
class EasyTierDisconnected extends EasyTierRuntimeState {
  const EasyTierDisconnected();
}

/// 正在建立连接（startInstance / 等虚拟 IP / 起转发器期间）。
class EasyTierConnecting extends EasyTierRuntimeState {
  const EasyTierConnecting();
}

/// 转发器已就绪且 bridge API 可达：`127.0.0.1:localPort` 即桥接到
/// profile 的 bridge。
class EasyTierReady extends EasyTierRuntimeState {
  const EasyTierReady(this.localPort);

  final int localPort;
}

/// 连接失败（启动报错 / 等虚拟 IP 超时）。
class EasyTierFailed extends EasyTierRuntimeState {
  const EasyTierFailed(this.message);

  final String message;
}

/// RemoteProfile → EasyTier 实例 TOML 配置（无 TUN 转发模式，纯函数便于测试）。
///
/// 显式 instance_name = profile.id：多实例由 EasyTier 内核 registry 承载，
/// stopInstance/currentVirtualIp/端口转发 patch 均以该名字为 key。
/// 全部 server（内网监听地址 + 公网中继）写入 `[[peer]]` 数组，
/// 由 EasyTier 自己挑通的走。
String buildInstanceToml(RemoteProfile p) {
  final peers = StringBuffer();
  for (final s in p.server) {
    peers.writeln('[[peer]]\nuri = "${_esc(s)}"');
  }
  return '''
instance_name = "${_esc(p.id)}"
hostname = "herdr-app"
dhcp = true
listeners = []

[network_identity]
network_name = "${_esc(p.networkName)}"
network_secret = "${_esc(p.secret)}"

$peers[flags]
no_tun = true
disable_upnp = true
''';
}

/// TOML basic string 转义：本层字段不含控制字符，只需处理 `\` 与 `"`。
String _esc(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

class EasyTierRuntimeNotifier extends Notifier<EasyTierRuntimeState> {
  /// family 参数：profileId（= EasyTier 实例名）。
  EasyTierRuntimeNotifier(this.profileId);

  final String profileId;

  /// 虚拟 IP 轮询节奏与总超时；测试里可缩短避免等真时间。
  @visibleForTesting
  static Duration pollInterval = const Duration(milliseconds: 250);
  @visibleForTesting
  static Duration virtualIpTimeout = const Duration(seconds: 15);
  @visibleForTesting
  static Duration bridgeProbeInterval = const Duration(milliseconds: 300);
  @visibleForTesting
  static Duration bridgeProbeTimeout = const Duration(seconds: 1);

  int _localPort = 0;
  /// 与 [_localPort] 同生命周期：REMOVE patch 按「整条 PortForwardConfig
  /// 相等」匹配，撤销时必须复现 ADD 时的 dst（见 easytier_channel.dart）。
  String _dstIp = '';
  int _dstPort = 0;

  /// 代际计数：connect/disconnect 交错时，旧的异步流程在下一个 await 后
  /// 检出自己已过期即退出，避免后到的状态被先到的覆盖。
  int _generation = 0;

  @override
  EasyTierRuntimeState build() => const EasyTierDisconnected();

  /// 启动本实例：生成 TOML → startInstance → 轮询 currentVirtualIp
  /// → 选回环端口 → PatchConfig ADD port_forward → 探测 bridge API → Ready。
  ///
  /// 多实例下不做 teardown 性质的「先 stopInstance」残留清理，只停本实例
  /// 已有的转发（重连时防端口泄漏）；失败时回滚本实例（转发 + 容错
  /// stopInstance）——startInstance 成功后的失败若不停实例，同名实例残留
  /// 会让重试被 EasyTier 内核以 "instance name already exists" 拒绝。
  Future<void> connect(RemoteProfile profile) async {
    final gen = ++_generation;
    state = const EasyTierConnecting();
    final channel = ref.read(easytierChannelProvider);
    try {
      await channel.startInstance(buildInstanceToml(profile));
      // 等本实例拿到虚拟 IP（证明 EasyTier 已连上网络），然后向
      // bridge 的虚拟 IP（pairing 里的 virtualIp）打端口转发 patch。
      final ip = await _waitVirtualIp(channel, gen);
      if (gen != _generation) return;
      if (ip == null) {
        throw StateError('等待虚拟 IP 超时（${virtualIpTimeout.inSeconds}s）');
      }
      // PatchConfig 通路不支持「bind 端口 0 再读回」，先在 Dart 侧占一个
      // 临时回环端口再交给内核 bind；抢占失败会走下面的 Failed 路径。
      final port = await _pickLoopbackPort();
      // ignore: avoid_print
      print('[easytier] instance $profileId got ip=$ip, '
          'forwarding 127.0.0.1:$port to ${profile.virtualIp}:${profile.port}');
      await channel.addPortForward(profileId,
          bindIp: '127.0.0.1',
          bindPort: port,
          dstIp: profile.virtualIp,
          dstPort: profile.port);
      if (gen != _generation) return;
      _localPort = port;
      _dstIp = profile.virtualIp;
      _dstPort = profile.port;
      await _waitBridgeReachable(port, gen);
      if (gen != _generation) return;
      // ignore: avoid_print
      print('[easytier] instance $profileId forward on :$_localPort');
      state = EasyTierReady(_localPort);
    } catch (e) {
      // ignore: avoid_print
      print('[easytier] instance $profileId connect failed: $e');
      if (gen != _generation) return;
      await _removeForward(channel);
      try {
        await channel.stopInstance(profileId);
      } catch (_) {
        // startInstance 本身失败时实例不存在，按已停处理。
      }
      if (gen != _generation) return;
      state = EasyTierFailed('$e');
    }
  }

  /// 停本实例的转发与 EasyTier 实例；重复调用幂等（已断开时 no-op）。
  Future<void> disconnect() async {
    _generation++;
    if (_localPort == 0 && state is EasyTierDisconnected) return;
    // 先取通道再 await：autoDispose 下 await 之后 provider 可能已销毁。
    final channel = ref.read(easytierChannelProvider);
    await _removeForward(channel);
    try {
      await channel.stopInstance(profileId);
    } catch (_) {
      // 实例可能已被原生侧停掉，按已停处理。
    }
    state = const EasyTierDisconnected();
  }

  /// 停本实例的转发（如有）；失败不影响后续流程。
  Future<void> _removeForward(EasyTierChannel channel) async {
    if (_localPort > 0) {
      final port = _localPort;
      final dstIp = _dstIp;
      final dstPort = _dstPort;
      _localPort = 0;
      _dstIp = '';
      _dstPort = 0;
      try {
        await channel.removePortForward(profileId,
            bindIp: '127.0.0.1',
            bindPort: port,
            dstIp: dstIp,
            dstPort: dstPort);
      } catch (_) {
        // 转发可能已随实例消失，按已停处理。
      }
    }
  }

  /// 占一个临时回环 TCP 端口后立即释放；返回的端口交给 PatchConfig bind。
  static Future<int> _pickLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// 每 [pollInterval] 轮询一次本实例的虚拟 IP，总超时 [virtualIpTimeout]；
  /// 超时或代际过期返回 null。
  Future<String?> _waitVirtualIp(EasyTierChannel channel, int gen) async {
    final deadline = DateTime.now().add(virtualIpTimeout);
    for (;;) {
      final raw = await channel.currentVirtualIpRaw(profileId);
      // ignore: avoid_print
      print('[easytier] _waitVirtualIp $profileId raw=$raw');
      if (raw != null) return raw;
      if (gen != _generation) return null;
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<void> _waitBridgeReachable(int localPort, int gen) async {
    final probe = ref.read(bridgeReachabilityProbeProvider);
    for (;;) {
      if (await probe(localPort, bridgeProbeTimeout)) return;
      if (gen != _generation) return;
      await Future<void>.delayed(bridgeProbeInterval);
    }
  }
}

final easytierRuntimeProvider = NotifierProvider.family<
    EasyTierRuntimeNotifier,
    EasyTierRuntimeState,
    String>(EasyTierRuntimeNotifier.new, isAutoDispose: true);
