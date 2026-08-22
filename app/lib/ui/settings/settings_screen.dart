import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../model/remote_profile.dart';
import '../../state/settings.dart';
import 'scan_pairing_screen.dart';

/// bridge 连接设置：扫码配对的 profile 列表，逐条 enabled 开关 + 显式删除。
///
/// 全 EasyTier 删直连后不再有直填表单（见 state/settings.dart 头注释）；
/// 每次增删/开关立即落盘并触发 enabledProfilesProvider.reload()，
/// bridgesProvider 据此重建连接集合。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _message;
  bool _messageIsError = false;

  /// 已保存的配对 profile 列表（本地状态，增删后刷新）。
  List<RemoteProfile> _profiles = const [];

  @override
  void initState() {
    super.initState();
    _reloadProfiles();
  }

  Future<void> _reloadProfiles() async {
    final profiles = await ref.read(profileStoreProvider).list();
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _scanAndAdd() async {
    final profile = await Navigator.of(context).push<RemoteProfile>(
      MaterialPageRoute(builder: (_) => const ScanPairingScreen()),
    );
    if (profile == null || !mounted) return;
    // 新 profile 默认 enabled=true（见 RemoteProfile），仅落盘 + 刷新连接
    // 集合，不再有「设为 active」语义。
    await ref.read(profileStoreProvider).add(profile);
    await ref.read(enabledProfilesProvider.notifier).reload();
    await _reloadProfiles();
    if (!mounted) return;
    setState(() {
      _message = '已添加：${profile.label}';
      _messageIsError = false;
    });
  }

  Future<void> _setEnabled(RemoteProfile profile, bool enabled) async {
    await ref.read(profileStoreProvider).setEnabled(profile.id, enabled);
    await ref.read(enabledProfilesProvider.notifier).reload();
    await _reloadProfiles();
  }

  Future<void> _confirmDelete(RemoteProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除配置'),
        content: Text('删除「${profile.label}」（${profile.virtualIp}）？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(profileStoreProvider).remove(profile.id);
    await ref.read(enabledProfilesProvider.notifier).reload();
    await _reloadProfiles();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('连接设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('远端 bridge（扫码配对）', style: theme.textTheme.titleSmall),
              FilledButton.icon(
                onPressed: _scanAndAdd,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码添加'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_profiles.isEmpty)
            Text(
              '尚未配对。在 bridge 主机上运行 herdr-bridge --show-qr，扫码后即可通过 EasyTier 虚拟网连接。',
              style: theme.textTheme.bodySmall,
            )
          else
            ..._profiles.map((p) => Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    title: Text(p.label),
                    subtitle: Text('${p.virtualIp}:${p.port} · ${p.server.join(', ')}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: p.enabled,
                          onChanged: (v) => _setEnabled(p, v),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: Icon(Icons.delete_outline,
                              color: theme.colorScheme.error),
                          onPressed: () => _confirmDelete(p),
                        ),
                      ],
                    ),
                  ),
                )),
          if (_profiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '开关控制是否连接该 bridge；多条同时开启即为多宿主机模式。',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(
              _message!,
              style: TextStyle(
                color: _messageIsError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
