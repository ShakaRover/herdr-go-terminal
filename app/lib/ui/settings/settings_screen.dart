import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/bridge_api.dart';
import '../../model/remote_profile.dart';
import '../../state/settings.dart';
import 'scan_pairing_screen.dart';

/// bridge 连接设置：扫码配对 profile、直填 URL、可选自定义请求头、连接测试。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  final _headerNameController = TextEditingController();
  final _headerValueController = TextEditingController();

  bool _testing = false;
  String? _message;
  bool _messageIsError = false;

  /// 已保存的配对 profile 列表（本地状态，增删后刷新）。
  List<RemoteProfile> _profiles = const [];

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _urlController.text = s.baseUrl;
    _headerNameController.text = s.headerName;
    _headerValueController.text = s.headerValue;
    _reloadProfiles();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _headerNameController.dispose();
    _headerValueController.dispose();
    super.dispose();
  }

  BridgeSettings get _formValue => BridgeSettings(
        baseUrl: _urlController.text.trim(),
        headerName: _headerNameController.text.trim(),
        headerValue: _headerValueController.text,
        profileId: ref.read(settingsProvider).profileId,
      );

  Future<void> _reloadProfiles() async {
    final profiles = await ref.read(profileStoreProvider).list();
    if (mounted) setState(() => _profiles = profiles);
  }

  Future<void> _scanAndAdd() async {
    final profile = await Navigator.of(context).push<RemoteProfile>(
      MaterialPageRoute(builder: (_) => const ScanPairingScreen()),
    );
    if (profile == null || !mounted) return;
    await ref.read(profileStoreProvider).add(profile);
    // 设为 active，旧的直填字段保留不动。
    await ref
        .read(settingsProvider.notifier)
        .save(ref.read(settingsProvider).copyWith(profileId: profile.id));
    await _reloadProfiles();
    if (!mounted) return;
    setState(() {
      _message = '已添加并切换：${profile.label}';
      _messageIsError = false;
    });
  }

  Future<void> _setActive(RemoteProfile profile) async {
    await ref
        .read(settingsProvider.notifier)
        .save(ref.read(settingsProvider).copyWith(profileId: profile.id));
    if (!mounted) return;
    setState(() {});
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
    // 删除的是 active profile 时回到直填模式。
    final s = ref.read(settingsProvider);
    if (s.profileId == profile.id) {
      await ref
          .read(settingsProvider.notifier)
          .save(s.copyWith(profileId: ''));
    }
    await _reloadProfiles();
  }

  Future<void> _testAndSave() async {
    final settings = _formValue;
    if (!settings.isConfigured) {
      setState(() {
        _message = '请填写 bridge URL';
        _messageIsError = true;
      });
      return;
    }
    setState(() {
      _testing = true;
      _message = null;
    });
    try {
      final api = BridgeApi(baseUrl: settings.baseUrl, headers: settings.headers);
      final config = await api.getConfig();
      final snap = await api.getSnapshot();
      final device = snap.device;
      final authNote = device != null && device.enforced
          ? (device.authorized ? '设备已授权' : '设备未授权（只读）')
          : null;
      await ref.read(settingsProvider.notifier).save(settings);
      if (!mounted) return;
      setState(() {
        _message = '已连接并保存 · ${snap.agents.length} 个 agent'
            '${config.build != null ? ' · build ${config.build}' : ''}'
            '${authNote != null ? ' · $authNote' : ''}';
        _messageIsError = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _message = '连接失败：$e';
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Widget _buildProfileSection(ThemeData theme, String activeProfileId) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
          ..._profiles.map((p) {
            final active = p.id == activeProfileId;
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: Icon(
                  active ? Icons.check_circle : Icons.circle_outlined,
                  color: active ? theme.colorScheme.primary : null,
                ),
                title: Row(
                  children: [
                    Flexible(child: Text(p.label)),
                    if (active) ...[
                      const SizedBox(width: 8),
                      Text(
                        '当前',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
                subtitle: Text('${p.virtualIp}:${p.port} · ${p.server}'),
                onTap: () => _setActive(p),
                onLongPress: () => _confirmDelete(p),
              ),
            );
          }),
        if (_profiles.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '点击切换当前使用的 bridge，长按删除。',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('连接设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildProfileSection(theme, settings.profileId),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          Text(
            'collie bridge 地址（直填模式）',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'https://myhost.tail1234.ts.net',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '与 collie 网页版同一个地址。手机需能通过 VPN/内网访问该地址。',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          ExpansionTile(
            title: const Text('自定义请求头（可选）'),
            subtitle: const Text('bridge 开了 device gate 时填写'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(top: 8),
            children: [
              TextField(
                controller: _headerNameController,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Header 名',
                  hintText: 'X-Device-Id',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _headerValueController,
                autocorrect: false,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Header 值',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _testing ? null : _testAndSave,
            icon: _testing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.wifi_tethering),
            label: Text(_testing ? '测试中…' : '测试连接并保存'),
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
