/// EasyTier 连接生命周期：选中 RemoteProfile 时启动内嵌 EasyTier 实例 +
/// 本地 TCP 转发器，apiProvider 经 easytierRuntimeProvider 拿到
/// `127.0.0.1:<localPort>` 作为 baseUrl。
///
/// 状态机：Disconnected → Connecting → Ready(localPort) / Failed(message)。
/// settingsProvider.profileId 变化驱动 connect/disconnect：
/// - 非空且 profile 存在 → stopForwarder → stopInstance（容错）→ 生成 TOML →
///   startInstance → 轮询 currentVirtualIp（500ms × 15s）→
///   startForwarder(virtualIp, port) → Ready；
/// - 空或 profile 不存在 → stopForwarder + stopInstance → Disconnected。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/easytier_channel.dart';
import '../model/remote_profile.dart';
import 'settings.dart';

/// 生产/测试可替换的 EasyTier 通道（测试 override 成 fake）。
final easytierChannelProvider =
    Provider<EasyTierChannel>((_) => EasyTierChannel());

sealed class EasyTierRuntimeState {
  const EasyTierRuntimeState();
}

/// 未选择 profile（或 profile 已被删除），没有 EasyTier 实例在跑。
class EasyTierDisconnected extends EasyTierRuntimeState {
  const EasyTierDisconnected();
}

/// 正在建立连接（startInstance / 等虚拟 IP / 起转发器期间）。
class EasyTierConnecting extends EasyTierRuntimeState {
  const EasyTierConnecting();
}

/// 转发器已就绪：`127.0.0.1:localPort` 即桥接到 profile 的 bridge。
class EasyTierReady extends EasyTierRuntimeState {
  const EasyTierReady(this.localPort);

  final int localPort;
}

/// 连接失败（启动报错 / 等虚拟 IP 超时），实例已尽量停掉。
class EasyTierFailed extends EasyTierRuntimeState {
  const EasyTierFailed(this.message);

  final String message;
}

/// RemoteProfile → EasyTier 实例 TOML 配置（无 TUN 转发模式，纯函数便于测试）。
///
/// 不显式指定 instance_name：EasyTier 侧默认 'default'，与转发器
/// `startForwarder` 的默认 instanceName 对齐（easytier_channel.dart）。
String buildInstanceToml(RemoteProfile p) {
  return '''
hostname = "herdr-app"
network_name = "${_esc(p.networkName)}"
network_secret = "${_esc(p.secret)}"
dhcp = true
peers = ["${_esc(p.server)}"]
listeners = []
[flags]
no_tun = true
disable_upnp = true
''';
}

/// TOML basic string 转义：本层字段不含控制字符，只需处理 `\` 与 `"`。
String _esc(String s) => s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');

class EasyTierRuntimeNotifier extends Notifier<EasyTierRuntimeState> {
  /// 虚拟 IP 轮询节奏与总超时；测试里可缩短避免等真时间。
  @visibleForTesting
  static Duration pollInterval = const Duration(milliseconds: 500);
  @visibleForTesting
  static Duration virtualIpTimeout = const Duration(seconds: 15);

  int _localPort = 0;

  /// 代际计数：connect/disconnect 交错时，旧的异步流程在下一个 await 后
  /// 检出自己已过期即退出，避免后到的状态被先到的覆盖。
  int _generation = 0;

  @override
  EasyTierRuntimeState build() {
    ref.listen(settingsProvider, (prev, next) {
      // 仅 profileId 变化才重连；改 baseUrl/请求头等不动 EasyTier。
      if (prev?.profileId != next.profileId) _onProfileId(next.profileId);
    });
    final profileId = ref.read(settingsProvider).profileId;
    if (profileId.isNotEmpty) {
      Future.microtask(() => _onProfileId(profileId));
    }
    return const EasyTierDisconnected();
  }

  Future<void> _onProfileId(String profileId) async {
    if (profileId.isEmpty) return disconnect();
    final profile = await ref.read(profileStoreProvider).getById(profileId);
    if (profile == null) return disconnect();
    return connect(profile);
  }

  Future<void> connect(RemoteProfile profile) async {
    final gen = ++_generation;
    await _teardown();
    if (gen != _generation) return;
    state = const EasyTierConnecting();
    final channel = ref.read(easytierChannelProvider);
    try {
      await channel.startInstance(buildInstanceToml(profile));
      final ip = await _waitVirtualIp(channel, gen);
      if (gen != _generation) return;
      if (ip == null) {
        throw StateError('等待虚拟 IP 超时（${virtualIpTimeout.inSeconds}s）');
      }
      _localPort = await channel.startForwarder(ip, profile.port);
      if (gen != _generation) return;
      state = EasyTierReady(_localPort);
    } catch (e) {
      if (gen != _generation) return;
      await _teardown();
      if (gen != _generation) return;
      state = EasyTierFailed('$e');
    }
  }

  Future<void> disconnect() async {
    _generation++;
    await _teardown();
    state = const EasyTierDisconnected();
  }

  /// 停转发器（如有）+ 停实例；停止残留实例的失败不影响后续流程。
  Future<void> _teardown() async {
    final channel = ref.read(easytierChannelProvider);
    if (_localPort > 0) {
      final port = _localPort;
      _localPort = 0;
      try {
        await channel.stopForwarder(port);
      } catch (_) {
        // 转发器可能已随实例消失，按已停处理。
      }
    }
    try {
      await channel.stopInstance();
    } catch (_) {
      // 无残留实例时原生侧可能报错，忽略。
    }
  }

  /// 每 [pollInterval] 轮询一次，总超时 [virtualIpTimeout]；
  /// 超时或代际过期返回 null。
  Future<String?> _waitVirtualIp(EasyTierChannel channel, int gen) async {
    final deadline = DateTime.now().add(virtualIpTimeout);
    for (;;) {
      final ip = await channel.currentVirtualIp();
      if (ip != null) return ip;
      if (gen != _generation) return null;
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(pollInterval);
    }
  }
}

final easytierRuntimeProvider =
    NotifierProvider<EasyTierRuntimeNotifier, EasyTierRuntimeState>(
        EasyTierRuntimeNotifier.new);
