/// settings 层：shared_preferences 实例、profile 列表仓库、enabled profile
/// 列表的常驻视图。
///
/// 全 EasyTier 后连接配置只剩扫码 profile 一种（见
/// docs/superpowers/specs/2026-08-21-multi-bridge-dashboard-design.md），
/// 直填配置（DirectConfig / bridge_settings_v2）已删除——遗留的
/// bridge_settings_v1/v2 键检测到即删，不做迁移。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../model/remote_profile.dart';

/// 在 main 里用已初始化的实例 override。
final sharedPrefsProvider = Provider<SharedPreferences>(
  (_) => throw UnimplementedError('sharedPrefsProvider 未 override'),
);

/// profile 列表的本地持久化仓库。
final profileStoreProvider = Provider<ProfileStore>(
  (ref) {
    final prefs = ref.watch(sharedPrefsProvider);
    // 删直连：旧键（v1 单条直连配置、v2 直连配置列表）不再有地方放，
    // 检测到即删，数据丢弃。
    prefs.remove('bridge_settings_v1');
    prefs.remove('bridge_settings_v2');
    return ProfileStore(prefs);
  },
);

/// 全部 enabled profile 的常驻列表（bridgesProvider 的数据源）。
///
/// 改 profile（扫码添加 / 删除 / 开关 enabled）后由调用方（settings 页）
/// 调 [EnabledProfilesNotifier.reload] 刷新；bridgesProvider watch 本
/// provider，enabled 集合变化即重建连接集合。
class EnabledProfilesNotifier extends Notifier<List<RemoteProfile>> {
  @override
  List<RemoteProfile> build() {
    ref.watch(profileStoreProvider);
    Future.microtask(reload);
    return const [];
  }

  /// 从持久化层重读 enabled profile 列表。
  Future<void> reload() async {
    final all = await ref.read(profileStoreProvider).list();
    // 首次 reload 由 build 的 microtask 触发，读完后 provider 可能已被销毁。
    if (!ref.mounted) return;
    state = all.where((p) => p.enabled).toList();
  }

  /// 有 enabled profile 即视为已配置（RootGate 据此跳 dashboard/设置页）。
  bool get isConfigured => state.isNotEmpty;
}

final enabledProfilesProvider =
    NotifierProvider<EnabledProfilesNotifier, List<RemoteProfile>>(
        EnabledProfilesNotifier.new);
