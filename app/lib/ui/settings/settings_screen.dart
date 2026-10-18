import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../model/remote_profile.dart';
import '../../state/settings.dart';
import '../content_pane.dart';
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
  bool _diagnosticBusy = false;

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

  Future<void> _addProfile(RemoteProfile profile) async {
    // 新 profile 默认 enabled=true（见 RemoteProfile），仅落盘 + 刷新连接
    // 集合，不再有「设为 active」语义。
    await ref.read(profileStoreProvider).add(profile);
    await ref.read(enabledProfilesProvider.notifier).reload();
    await _reloadProfiles();
    if (!mounted) return;
    setState(() {
      _message = context.l10n.profileAdded(profile.label);
      _messageIsError = false;
    });
  }

  Future<void> _scanAndAdd() async {
    final profile = await Navigator.of(context).push<RemoteProfile>(
      MaterialPageRoute(builder: (_) => const ScanPairingScreen()),
    );
    if (profile == null || !mounted) return;
    await _addProfile(profile);
  }

  Future<void> _addFromString() async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => const _PairingStringDialog(),
    );
    if (raw == null || raw.isEmpty || !mounted) return;
    RemoteProfile profile;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not a json object');
      }
      profile = RemoteProfile.fromPairingJson(decoded);
    } on FormatException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.invalidPairingString)),
      );
      return;
    }
    await _addProfile(profile);
  }

  Future<void> _openWebsitePage({
    required String englishPath,
    required String chinesePath,
  }) async {
    final languageCode = Localizations.localeOf(context).languageCode;
    final pluginGuideUrl = Uri.parse(
      'https://herdr-go.github.io${languageCode == 'zh' ? chinesePath : englishPath}',
    );
    final opened = await launchUrl(
      pluginGuideUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(context.l10n.openLinkFailed)));
    }
  }

  Future<void> _openPluginGuide() =>
      _openWebsitePage(englishPath: '/#install', chinesePath: '/zh/#install');

  Future<void> _showPluginSetup() {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        return AlertDialog(
          title: Text(l10n.computerSetup),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.pluginSetupHelp),
                const SizedBox(height: 12),
                const SelectionArea(
                  child: Text(
                    'herdr plugin install herdr-go/herdr-go\n'
                    'herdr plugin action invoke herdrgo.setup',
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                const SizedBox(height: 16),
                Text(l10n.pluginPairAgainHelp),
                const SizedBox(height: 8),
                const SelectionArea(
                  child: Text(
                    'herdr plugin action invoke herdrgo.pair',
                    style: TextStyle(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                _openPluginGuide();
              },
              icon: const Icon(Icons.open_in_new),
              label: Text(l10n.pluginInstallGuide),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.commonClose),
            ),
          ],
        );
      },
    );
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

  Future<void> _setDiagnosticLogging(bool enabled) async {
    setState(() => _diagnosticBusy = true);
    try {
      await ref.read(diagnosticLoggingProvider.notifier).setEnabled(enabled);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.diagnosticLogsError('$error'))),
        );
      }
    } finally {
      if (mounted) setState(() => _diagnosticBusy = false);
    }
  }

  Future<void> _shareDiagnosticLogs() async {
    setState(() => _diagnosticBusy = true);
    try {
      await ref.read(diagnosticLogChannelProvider).shareDiagnosticLogs();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.diagnosticLogsError('$error'))),
        );
      }
    } finally {
      if (mounted) setState(() => _diagnosticBusy = false);
    }
  }

  Future<void> _confirmClearDiagnosticLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(dialogContext.l10n.clearDiagnosticLogsTitle),
        content: Text(dialogContext.l10n.clearDiagnosticLogsBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(dialogContext.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(dialogContext.l10n.clearDiagnosticLogs),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _diagnosticBusy = true);
    try {
      await ref.read(diagnosticLogChannelProvider).clearDiagnosticLogs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.diagnosticLogsCleared)),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.diagnosticLogsError('$error'))),
        );
      }
    } finally {
      if (mounted) setState(() => _diagnosticBusy = false);
    }
  }

  Future<void> _showDiagnosticDetails() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(dialogContext.l10n.diagnosticLoggingDetailsTitle),
      content: SingleChildScrollView(
        child: Text(dialogContext.l10n.diagnosticLoggingDetails),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(dialogContext.l10n.commonClose),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final localePreference = ref.watch(appLocaleProvider);
    final terminalAutoResize = ref.watch(terminalAutoResizeProvider);
    final terminalRefreshRate = ref.watch(terminalRefreshRateProvider);
    final terminalFontSize = ref.watch(terminalFontSizeProvider);
    final diagnosticLogging = ref.watch(diagnosticLoggingProvider);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.connectionSettings)),
      body: ListView(
        padding: contentPanePadding(context, const EdgeInsets.all(16)),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l10n.devices, style: theme.textTheme.titleMedium),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: _showPluginSetup,
                icon: const Icon(Icons.help_outline, size: 18),
                label: Text(l10n.deploymentHelp),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _scanAndAdd,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(l10n.addDevice),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _addFromString,
              icon: const Icon(Icons.content_paste),
              label: Text(l10n.addFromString),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.remoteBridge,
                  style: theme.textTheme.titleSmall,
                ),
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
          const Divider(height: 40),
          Text(l10n.otherSettings, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.terminalAutoResize),
            subtitle: Text(l10n.terminalAutoResizeHelp),
            value: terminalAutoResize,
            onChanged: (enabled) => ref
                .read(terminalAutoResizeProvider.notifier)
                .setEnabled(enabled),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.terminalRefreshRate),
            subtitle: Text(l10n.terminalRefreshRateHelp),
            trailing: DropdownButton<TerminalRefreshRate>(
              value: terminalRefreshRate,
              selectedItemBuilder: (_) => [
                Text(l10n.terminalRefreshAutomatic),
                const Text('20 FPS'),
                const Text('10 FPS'),
                const Text('4 FPS'),
              ],
              onChanged: (value) {
                if (value != null) {
                  ref.read(terminalRefreshRateProvider.notifier).select(value);
                }
              },
              items: [
                DropdownMenuItem(
                  value: TerminalRefreshRate.automatic,
                  child: Text(l10n.terminalRefreshAutomatic),
                ),
                DropdownMenuItem(
                  value: TerminalRefreshRate.smooth,
                  child: Text(l10n.terminalRefreshSmooth),
                ),
                DropdownMenuItem(
                  value: TerminalRefreshRate.balanced,
                  child: Text(l10n.terminalRefreshBalanced),
                ),
                DropdownMenuItem(
                  value: TerminalRefreshRate.batterySaver,
                  child: Text(l10n.terminalRefreshBatterySaver),
                ),
              ],
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.terminalFontSize),
            subtitle: Text(l10n.terminalFontSizeHelp),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${terminalFontSize.toStringAsFixed(1)} pt'),
                IconButton(
                  tooltip: l10n.terminalFontSizeReset,
                  icon: const Icon(Icons.restart_alt),
                  onPressed: terminalFontSize == terminalDefaultFontSize
                      ? null
                      : () =>
                            ref.read(terminalFontSizeProvider.notifier).reset(),
                ),
              ],
            ),
          ),
          Slider(
            value: terminalFontSize,
            min: terminalMinFontSize,
            max: terminalMaxFontSize,
            divisions: ((terminalMaxFontSize - terminalMinFontSize) * 10)
                .round(),
            onChanged: (value) =>
                ref.read(terminalFontSizeProvider.notifier).preview(value),
            onChangeEnd: (value) =>
                ref.read(terminalFontSizeProvider.notifier).setFontSize(value),
          ),
          if (defaultTargetPlatform == TargetPlatform.iOS) ...[
            const Divider(height: 40),
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.diagnostics,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: l10n.diagnosticLoggingDetailsTitle,
                  onPressed: _showDiagnosticDetails,
                  icon: const Icon(Icons.info_outline),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.diagnosticLogging),
              subtitle: Text(l10n.diagnosticLoggingHelp),
              value: diagnosticLogging,
              onChanged: _diagnosticBusy ? null : _setDiagnosticLogging,
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _diagnosticBusy ? null : _shareDiagnosticLogs,
                  icon: const Icon(Icons.ios_share),
                  label: Text(l10n.shareDiagnosticLogs),
                ),
                TextButton.icon(
                  onPressed: _diagnosticBusy
                      ? null
                      : _confirmClearDiagnosticLogs,
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: Text(l10n.clearDiagnosticLogs),
                ),
              ],
            ),
          ],
          const Divider(height: 40),
          Text(l10n.about, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.privacy_tip_outlined),
            title: Text(l10n.privacyPolicy),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _openWebsitePage(
              englishPath: '/privacy/',
              chinesePath: '/zh/privacy/',
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.support_agent_outlined),
            title: Text(l10n.technicalSupport),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _openWebsitePage(
              englishPath: '/support/',
              chinesePath: '/zh/support/',
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

/// 粘贴配对字符串的对话框。控制器由 State 持有，避免在路由退出动画
/// 期间提前 dispose 导致 "TextEditingController used after being disposed"。
class _PairingStringDialog extends StatefulWidget {
  const _PairingStringDialog();

  @override
  State<_PairingStringDialog> createState() => _PairingStringDialogState();
}

class _PairingStringDialogState extends State<_PairingStringDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      scrollable: true,
      title: Text(l10n.addFromStringTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.addFromStringHelp),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            minLines: 3,
            maxLines: 5,
            autofocus: true,
            decoration: InputDecoration(
              hintText: l10n.addFromStringHint,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}
