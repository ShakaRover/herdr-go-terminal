import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
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
    final l10n = context.l10n;
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
      _message = l10n.profileAdded(profile.label);
      _messageIsError = false;
    });
  }

  Future<void> _setEnabled(RemoteProfile profile, bool enabled) async {
    await ref.read(profileStoreProvider).setEnabled(profile.id, enabled);
    await ref.read(enabledProfilesProvider.notifier).reload();
    await _reloadProfiles();
  }

  /// 编辑设备别名（展示名）：本地落盘 + 刷新连接集合。
  Future<void> _editLabel(RemoteProfile profile) async {
    final controller = TextEditingController(text: profile.label);
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.deviceAlias),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(hintText: ctx.l10n.displayNameHint),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(ctx.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(ctx.l10n.commonConfirm),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
    if (label == null || label.isEmpty || !mounted) return;
    await ref.read(profileStoreProvider).setLabel(profile.id, label);
    await ref.read(enabledProfilesProvider.notifier).reload();
    await _reloadProfiles();
  }

  Future<void> _confirmDelete(RemoteProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.deleteConfigTitle),
        content: Text(
          ctx.l10n.deleteConfigBody(profile.label, profile.virtualIp),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.l10n.commonDelete),
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
    final l10n = context.l10n;
    final localePreference = ref.watch(appLocaleProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.connectionSettings)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.language),
            trailing: DropdownButton<AppLocalePreference>(
              value: localePreference,
              onChanged: (value) {
                if (value != null) {
                  ref.read(appLocaleProvider.notifier).select(value);
                }
              },
              items: [
                DropdownMenuItem(
                  value: AppLocalePreference.system,
                  child: Text(l10n.systemLanguage),
                ),
                DropdownMenuItem(
                  value: AppLocalePreference.simplifiedChinese,
                  child: Text(l10n.simplifiedChinese),
                ),
                DropdownMenuItem(
                  value: AppLocalePreference.english,
                  child: Text(l10n.english),
                ),
              ],
            ),
          ),
          const Divider(),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.remoteBridge,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _scanAndAdd,
                icon: const Icon(Icons.qr_code_scanner),
                label: Text(l10n.scanToAdd),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_profiles.isEmpty)
            Text(l10n.notPaired, style: theme.textTheme.bodySmall)
          else
            ..._profiles.map(
              (p) => Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(p.label),
                  subtitle: Text(
                    '${p.virtualIp}:${p.port} · ${p.server.join(', ')}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: l10n.editAliasTooltip,
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _editLabel(p),
                      ),
                      Switch(
                        value: p.enabled,
                        onChanged: (v) => _setEnabled(p, v),
                      ),
                      IconButton(
                        tooltip: l10n.deleteTooltip,
                        icon: Icon(
                          Icons.delete_outline,
                          color: theme.colorScheme.error,
                        ),
                        onPressed: () => _confirmDelete(p),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_profiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.bridgeEnableHelp,
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
