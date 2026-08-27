import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../model/models.dart';
import '../../state/bridges.dart';
import '../../state/snapshot.dart';
import '../content_pane.dart';

class CreateAgentOutcome {
  const CreateAgentOutcome({
    required this.bridgeId,
    required this.session,
    required this.result,
  });

  final String bridgeId;
  final String? session;
  final CreateAgentResult result;
}

Future<CreateAgentOutcome?> showCreateAgentSheet(
  BuildContext context, {
  String? initialBridgeId,
}) => showModalBottomSheet<CreateAgentOutcome>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) =>
      ContentPane(child: CreateAgentSheet(initialBridgeId: initialBridgeId)),
);

class CreateAgentSheet extends ConsumerStatefulWidget {
  const CreateAgentSheet({super.key, this.initialBridgeId});

  final String? initialBridgeId;

  @override
  ConsumerState<CreateAgentSheet> createState() => _CreateAgentSheetState();
}

class _CreateAgentSheetState extends ConsumerState<CreateAgentSheet> {
  static const _primarySession = '';
  static const _newWorkspace = '';
  static final _agentNamePattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _cwdController = TextEditingController();
  final _promptController = TextEditingController();

  String? _bridgeId;
  String? _session;
  String? _kind;
  String _workspaceId = _newWorkspace;
  Snapshot? _snapshot;
  List<String> _agentKinds = const [];
  String? _error;
  bool _loading = true;
  bool _submitting = false;
  bool _nameEdited = false;
  bool _cwdEdited = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    Future.microtask(_selectInitialBridge);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _cwdController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  List<BridgeConn> get _readyBridges => ref
      .read(bridgesProvider)
      .where((conn) => conn.status == ConnStatus.ready && conn.api != null)
      .toList();

  void _selectInitialBridge() {
    if (!mounted) return;
    final ready = _readyBridges;
    if (ready.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final preferred = ready.where((conn) => conn.id == widget.initialBridgeId);
    _selectBridge(preferred.isEmpty ? ready.first.id : preferred.first.id);
  }

  Future<void> _selectBridge(String bridgeId) async {
    if (!mounted) return;
    final session = ref.read(sessionFilterProvider(bridgeId));
    setState(() {
      _bridgeId = bridgeId;
      _session = session;
      _snapshot = null;
      _workspaceId = _newWorkspace;
      _cwdEdited = false;
      _cwdController.clear();
    });
    await _loadTarget();
  }

  Future<void> _selectSession(String? session) async {
    setState(() {
      _session = session;
      // TODO: 保留上次成功的 session 列表；当前若新 session 加载失败，
      // 下拉框会随 snapshot 清空，只能重开表单切回。
      _snapshot = null;
      _workspaceId = _newWorkspace;
      _cwdEdited = false;
      _cwdController.clear();
    });
    await _loadTarget();
  }

  Future<void> _loadTarget() async {
    final bridgeId = _bridgeId;
    if (bridgeId == null) return;
    final api = ref.read(apiProvider(bridgeId));
    if (api == null) {
      setState(() {
        _loading = false;
        _error = context.l10n.noWritableComputer;
      });
      return;
    }
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _agentKinds = const [];
      _kind = null;
    });
    try {
      final values = await Future.wait<Object>([
        api.getSnapshot(session: _session),
        api.getAgentKinds(session: _session),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      final snapshot = values[0] as Snapshot;
      final kinds = values[1] as List<String>;
      final kind = _preferredKind(kinds);
      final focusedWorkspace = _focusedWorkspace(snapshot);
      setState(() {
        _snapshot = snapshot;
        _agentKinds = kinds;
        _kind = kind;
        _workspaceId = focusedWorkspace?.workspaceId ?? _newWorkspace;
        _loading = false;
        if (!_nameEdited && kind != null) {
          _nameController.text = _generatedName(kind);
        }
        if (!_cwdEdited) {
          _cwdController.text = _cwdForWorkspace(
            snapshot,
            focusedWorkspace?.workspaceId,
          );
        }
        if (kinds.isEmpty) {
          _error = context.l10n.noAgentTypes;
        }
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = context.l10n.loadCreateAgentOptionsFailed('$error');
      });
    }
  }

  static String? _preferredKind(List<String> kinds) {
    for (final preferred in const ['codex', 'claude']) {
      if (kinds.contains(preferred)) return preferred;
    }
    return kinds.firstOrNull;
  }

  static WorkspaceInfo? _focusedWorkspace(Snapshot snapshot) {
    for (final workspace in snapshot.workspaces) {
      if (workspace.focused) return workspace;
    }
    return snapshot.workspaces.firstOrNull;
  }

  static String _cwdForWorkspace(Snapshot snapshot, String? workspaceId) {
    final panes = [...snapshot.agents, ...snapshot.shellPanes];
    for (final pane in panes) {
      if (pane.workspaceId == workspaceId && pane.cwd.isNotEmpty) {
        return pane.cwd;
      }
    }
    for (final pane in panes) {
      if (pane.cwd.isNotEmpty) return pane.cwd;
    }
    return '';
  }

  static String _generatedName(String kind) {
    var prefix = kind.toLowerCase().replaceAll(RegExp('[^a-z0-9_-]'), '-');
    if (prefix.isEmpty || !RegExp('[a-z]').hasMatch(prefix[0])) {
      prefix = 'agent';
    }
    final suffix = DateTime.now().millisecondsSinceEpoch;
    final maxPrefixLength = 32 - suffix.toString().length - 1;
    if (prefix.length > maxPrefixLength) {
      prefix = prefix.substring(0, maxPrefixLength);
    }
    return '$prefix-$suffix';
  }

  List<String> _recentDirectories() {
    final snapshot = _snapshot;
    if (snapshot == null) return const [];
    final seen = <String>{};
    final result = <String>[];
    for (final pane in [...snapshot.agents, ...snapshot.shellPanes]) {
      final cwd = pane.cwd.trim();
      if (cwd.isNotEmpty && seen.add(cwd)) result.add(cwd);
      if (result.length == 4) break;
    }
    return result;
  }

  String? _validateName(String? value) {
    return _agentNamePattern.hasMatch(value?.trim() ?? '')
        ? null
        : context.l10n.invalidAgentName;
  }

  String? _validateCwd(String? value) {
    final cwd = value?.trim() ?? '';
    return cwd.startsWith('/') && cwd.length <= 4096
        ? null
        : context.l10n.absolutePathRequired;
  }

  Future<void> _submit() async {
    if (_submitting || !_formKey.currentState!.validate()) return;
    final bridgeId = _bridgeId;
    final kind = _kind;
    final api = bridgeId == null ? null : ref.read(apiProvider(bridgeId));
    if (bridgeId == null || kind == null || api == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final cwd = _cwdController.text.trim();
    try {
      final result = await api.createAgent(
        name: _nameController.text.trim(),
        kind: kind,
        cwd: cwd,
        workspaceId: _workspaceId.isEmpty ? null : _workspaceId,
        workspaceLabel: _workspaceId.isEmpty ? _workspaceLabel(cwd) : null,
        initialPrompt: _promptController.text.trim().isEmpty
            ? null
            : _promptController.text.trim(),
        session: _session,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        CreateAgentOutcome(
          bridgeId: bridgeId,
          session: _session,
          result: result,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = '$error';
      });
    }
  }

  String _workspaceLabel(String cwd) {
    final segments = cwd.split('/').where((segment) => segment.isNotEmpty);
    return segments.isEmpty ? _nameController.text.trim() : segments.last;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final ready = ref
        .watch(bridgesProvider)
        .where((conn) => conn.status == ConnStatus.ready && conn.api != null)
        .toList();
    final snapshot = _snapshot;
    final recentDirectories = _recentDirectories();
    final selectedBridgeId = ready.any((conn) => conn.id == _bridgeId)
        ? _bridgeId
        : null;
    final canSubmit =
        !_loading &&
        !_submitting &&
        selectedBridgeId != null &&
        snapshot != null &&
        !snapshot.readOnly &&
        _agentKinds.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .9,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l10n.createAgentTitle,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      tooltip: l10n.commonCancel,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (ready.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(l10n.noWritableComputer),
                  )
                else ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey('bridge-${selectedBridgeId ?? ''}'),
                    initialValue: selectedBridgeId,
                    decoration: InputDecoration(
                      labelText: l10n.targetComputer,
                      prefixIcon: const Icon(Icons.computer_outlined),
                    ),
                    items: [
                      for (final conn in ready)
                        DropdownMenuItem(
                          value: conn.id,
                          child: Text(conn.label),
                        ),
                    ],
                    onChanged: _submitting
                        ? null
                        : (value) {
                            if (value != null && value != _bridgeId) {
                              _selectBridge(value);
                            }
                          },
                  ),
                  if (snapshot != null && snapshot.sessions.length > 1) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      key: ValueKey('session-${_session ?? 'primary'}'),
                      initialValue: _session ?? _primarySession,
                      decoration: InputDecoration(
                        labelText: l10n.herdrSession,
                        prefixIcon: const Icon(Icons.layers_outlined),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: _primarySession,
                          child: Text(l10n.defaultSession),
                        ),
                        for (final session in snapshot.sessions)
                          if (!session.isPrimary)
                            DropdownMenuItem(
                              value: session.name,
                              enabled: session.reachable,
                              child: Text(session.name),
                            ),
                      ],
                      onChanged: _submitting
                          ? null
                          : (value) => _selectSession(
                              value == _primarySession ? null : value,
                            ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('kind-${_kind ?? ''}'),
                    initialValue: _kind,
                    decoration: InputDecoration(labelText: l10n.agentType),
                    items: [
                      for (final kind in _agentKinds)
                        DropdownMenuItem(value: kind, child: Text(kind)),
                    ],
                    onChanged: _submitting
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              _kind = value;
                              if (!_nameEdited) {
                                _nameController.text = _generatedName(value);
                              }
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('create-agent-name'),
                    controller: _nameController,
                    enabled: !_submitting,
                    decoration: InputDecoration(
                      labelText: l10n.agentName,
                      helperText: l10n.agentNameHint,
                    ),
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    validator: _validateName,
                    onChanged: (_) => _nameEdited = true,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('workspace-$_workspaceId'),
                    initialValue: _workspaceId,
                    decoration: InputDecoration(labelText: l10n.workspace),
                    items: [
                      DropdownMenuItem(
                        value: _newWorkspace,
                        child: Text(l10n.newWorkspace),
                      ),
                      if (snapshot != null)
                        for (final workspace in snapshot.workspaces)
                          DropdownMenuItem(
                            value: workspace.workspaceId,
                            child: Text(
                              '${workspace.number} · ${workspace.label}',
                            ),
                          ),
                    ],
                    onChanged: _submitting
                        ? null
                        : (value) {
                            if (value == null) return;
                            setState(() {
                              _workspaceId = value;
                              final suggested = _cwdForWorkspace(
                                snapshot!,
                                value,
                              );
                              if (suggested.isNotEmpty) {
                                _cwdController.text = suggested;
                              }
                            });
                          },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('create-agent-cwd'),
                    controller: _cwdController,
                    enabled: !_submitting,
                    decoration: InputDecoration(
                      labelText: l10n.workingDirectory,
                      hintText: l10n.workingDirectoryHint,
                      prefixIcon: const Icon(Icons.folder_outlined),
                    ),
                    autocorrect: false,
                    textInputAction: TextInputAction.next,
                    validator: _validateCwd,
                    onChanged: (_) => _cwdEdited = true,
                  ),
                  if (recentDirectories.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.recentDirectories,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final cwd in recentDirectories)
                          ActionChip(
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 260),
                              child: Text(cwd, overflow: TextOverflow.ellipsis),
                            ),
                            onPressed: _submitting
                                ? null
                                : () => setState(() {
                                    _cwdEdited = true;
                                    _cwdController.text = cwd;
                                  }),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('create-agent-prompt'),
                    controller: _promptController,
                    enabled: !_submitting,
                    decoration: InputDecoration(
                      labelText: l10n.initialTask,
                      hintText: l10n.initialTaskHint,
                      alignLabelWithHint: true,
                      counterText: '',
                    ),
                    minLines: 3,
                    maxLines: 6,
                    maxLength: 100000,
                  ),
                  if (_loading) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (snapshot?.readOnly == true) ...[
                    const SizedBox(height: 12),
                    Text(
                      l10n.readOnlyMode,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (_error case final error?) ...[
                    const SizedBox(height: 12),
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('create-agent-submit'),
                    onPressed: canSubmit ? _submit : null,
                    icon: _submitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add),
                    label: Text(
                      _submitting ? l10n.creatingAgent : l10n.createAgentAction,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
