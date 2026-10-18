import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../ansi/ansi.dart';
import '../../api/bridge_api.dart';
import '../../blocks/prompt_action.dart';
import '../../blocks/prompt_model.dart';
import '../../blocks/prompt_select.dart';
import '../../l10n/l10n.dart';
import '../../state/bridges.dart';
import '../../state/pane_read.dart';
import '../../state/settings.dart';
import '../../state/snapshot.dart';
import '../history/history_screen.dart';
import '../content_pane.dart';
import '../status_style.dart';
import 'ansi_span.dart';
import 'rename_pane_dialog.dart';

typedef _TerminalGridSize = ({int cols, int rows});

const _mirrorPadding = EdgeInsets.fromLTRB(12, 12, 12, 16);

_TerminalGridSize _terminalGridSize(
  BuildContext context,
  BoxConstraints constraints, {
  required double fontSize,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: '0',
      style: segmentStyle(const AnsiSegment(text: '0'), fontSize: fontSize),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final usableWidth = constraints.maxWidth - _mirrorPadding.horizontal;
  final usableHeight = constraints.maxHeight - _mirrorPadding.vertical;
  final cols = (usableWidth / painter.width).floor().clamp(20, 300).toInt();
  final rows = (usableHeight / painter.preferredLineHeight)
      .floor()
      .clamp(5, 200)
      .toInt();
  return (cols: cols, rows: rows);
}

/// agent 详情：输出镜像 + 回复框 + 特殊按键条。
class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key, required this.bridgeId, required this.paneId});

  final String bridgeId;
  final String paneId;

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _scrollController = ScrollController();
  final _replyController = TextEditingController();

  /// 用户停留在底部时，新内容到达自动跟随；上翻后不再抢滚动条。
  bool _stickToBottom = true;
  bool _userScrolling = false;
  bool _atTop = false;
  bool _sending = false;
  bool _historyLoading = false;
  bool _foreground = true;
  bool _resizeEligible = false;
  bool _leaseRequestInFlight = false;
  bool _leaseSyncQueued = false;
  bool _leaseSyncAgain = false;
  bool _scrollToBottomQueued = false;
  bool _renewLease = false;
  int _leaseEpoch = 0;
  String? _terminalLeaseId;
  String? _leaseSession;
  BridgeApi? _leaseApi;
  _TerminalGridSize? _viewportSize;
  _TerminalGridSize? _leasedSize;
  Timer? _leaseHeartbeat;
  AppLifecycleListener? _lifecycleListener;
  final _terminalPointers = <int, Offset>{};
  int? _pinchPointerA;
  int? _pinchPointerB;
  double? _pinchStartDistance;
  double? _pinchStartFontSize;
  double? _pinchFontSize;

  /// 最近一次 build 时识别到的尾部对话框（供回复发送前的误批准拦截）。
  PromptRegion? _lastPromptRegion;

  static const _keys = [
    (label: 'Esc', keys: ['Escape']),
    (label: 'Ctrl+C', keys: ['ctrl+c']),
    (label: '↑', keys: ['Up']),
    (label: '↓', keys: ['Down']),
    (label: '←', keys: ['Left']),
    (label: '→', keys: ['Right']),
    (label: 'Tab', keys: ['Tab']),
    (label: '⇧Tab', keys: ['shift+tab']),
    (label: 'Enter', keys: ['Enter']),
  ];

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onStateChange: (state) {
        final foreground = state == AppLifecycleState.resumed;
        if (_foreground == foreground) return;
        _foreground = foreground;
        if (foreground) {
          _queueLeaseSync();
        } else {
          unawaited(_releaseTerminalLease());
        }
      },
    );
    _scrollController.addListener(() {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      final atBottom = pos.maxScrollExtent - pos.pixels < 48;
      final atTop = pos.pixels < 24;
      if (!_userScrolling && atBottom != _stickToBottom) {
        _stickToBottom = atBottom;
      }
      if (atTop != _atTop) {
        setState(() => _atTop = atTop);
      }
    });
  }

  @override
  void dispose() {
    _lifecycleListener?.dispose();
    unawaited(_releaseTerminalLease());
    _scrollController.dispose();
    _replyController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollToBottomQueued) return;
    _scrollToBottomQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomQueued = false;
      if (_stickToBottom && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  bool _handleTerminalScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _userScrolling = true;
      _stickToBottom = false;
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      if (_scrollController.hasClients) {
        final pos = _scrollController.position;
        _stickToBottom = pos.maxScrollExtent - pos.pixels < 1;
      }
    }
    return false;
  }

  Future<void> _loadEarlierOutput(PaneReadKey paneKey) async {
    if (_historyLoading) return;
    final position = _scrollController.hasClients
        ? (
            pixels: _scrollController.position.pixels,
            maxExtent: _scrollController.position.maxScrollExtent,
          )
        : null;
    setState(() => _historyLoading = true);
    try {
      await ref.read(paneReadProvider(paneKey).notifier).loadEarlierOutput();
      if (!mounted || position == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollController.hasClients) return;
        final newMax = _scrollController.position.maxScrollExtent;
        final addedExtent = (newMax - position.maxExtent).clamp(0.0, newMax);
        final target = (position.pixels + addedExtent).clamp(0.0, newMax);
        _scrollController.jumpTo(target);
      });
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _resumeLiveOutput(PaneReadKey paneKey) async {
    if (_historyLoading) return;
    setState(() => _historyLoading = true);
    try {
      await ref.read(paneReadProvider(paneKey).notifier).resumeLiveOutput();
      if (!mounted) return;
      _stickToBottom = true;
      _scrollToBottom();
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  void _updateTerminalViewport(
    BuildContext context,
    BoxConstraints constraints, {
    required bool enabled,
    required double fontSize,
  }) {
    final eligibilityChanged = _resizeEligible != enabled;
    _resizeEligible = enabled;
    if (!enabled) {
      _viewportSize = null;
      if (eligibilityChanged || _terminalLeaseId != null) {
        _queueLeaseSync();
      }
      return;
    }
    final size = _terminalGridSize(context, constraints, fontSize: fontSize);
    final widthChanged = _viewportSize?.cols != size.cols;
    _viewportSize = size;
    if (eligibilityChanged || widthChanged || _terminalLeaseId == null) {
      _queueLeaseSync();
    }
  }

  bool get _isPinching => _pinchPointerA != null;

  void _handleTerminalPointerDown(PointerDownEvent event) {
    _terminalPointers[event.pointer] = event.localPosition;
    if (_isPinching || _terminalPointers.length != 2) return;
    final pointers = _terminalPointers.keys.toList();
    final first = _terminalPointers[pointers[0]]!;
    final second = _terminalPointers[pointers[1]]!;
    final distance = (first - second).distance;
    if (distance == 0) return;
    setState(() {
      _pinchPointerA = pointers[0];
      _pinchPointerB = pointers[1];
      _pinchStartDistance = distance;
      _pinchStartFontSize = ref.read(terminalFontSizeProvider);
      _pinchFontSize = _pinchStartFontSize;
    });
  }

  void _handleTerminalPointerMove(PointerMoveEvent event) {
    if (!_terminalPointers.containsKey(event.pointer)) return;
    _terminalPointers[event.pointer] = event.localPosition;
    final first = _terminalPointers[_pinchPointerA];
    final second = _terminalPointers[_pinchPointerB];
    final startDistance = _pinchStartDistance;
    final startFontSize = _pinchStartFontSize;
    if (first == null ||
        second == null ||
        startDistance == null ||
        startFontSize == null) {
      return;
    }
    final fontSize = (startFontSize * (first - second).distance / startDistance)
        .clamp(terminalMinFontSize, terminalMaxFontSize)
        .toDouble();
    if ((_pinchFontSize! - fontSize).abs() < 0.01) return;
    setState(() => _pinchFontSize = fontSize);
  }

  void _handleTerminalPointerEnd(PointerEvent event) {
    _terminalPointers.remove(event.pointer);
    if (event.pointer != _pinchPointerA && event.pointer != _pinchPointerB) {
      return;
    }
    final fontSize = _pinchFontSize;
    _pinchPointerA = null;
    _pinchPointerB = null;
    _pinchStartDistance = null;
    _pinchStartFontSize = null;
    if (fontSize == null) return;
    final persist = ref
        .read(terminalFontSizeProvider.notifier)
        .setFontSize(fontSize);
    setState(() => _pinchFontSize = null);
    unawaited(persist);
  }

  bool get _wantsTerminalLease =>
      mounted && _foreground && _resizeEligible && _viewportSize != null;

  void _queueLeaseSync({bool renew = false}) {
    _renewLease = _renewLease || renew;
    if (_leaseSyncQueued) return;
    _leaseSyncQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _leaseSyncQueued = false;
      unawaited(_syncTerminalLease());
    });
  }

  void _ensureLeaseHeartbeat() {
    _leaseHeartbeat ??= Timer.periodic(const Duration(seconds: 5), (_) {
      if (_wantsTerminalLease) {
        _queueLeaseSync(renew: true);
      }
    });
  }

  Future<void> _syncTerminalLease() async {
    if (_leaseRequestInFlight) {
      _leaseSyncAgain = true;
      return;
    }
    if (!_wantsTerminalLease) {
      await _releaseTerminalLease();
      return;
    }
    final api = ref.read(apiProvider(widget.bridgeId));
    final size = _viewportSize;
    if (api == null || size == null) {
      await _releaseTerminalLease();
      return;
    }
    final session = ref.read(sessionFilterProvider(widget.bridgeId));
    if (_terminalLeaseId != null &&
        (_leaseApi != api || _leaseSession != session)) {
      await _releaseTerminalLease();
    }

    final existingLease = _terminalLeaseId;
    final previousSize = _leasedSize;
    final renew = _renewLease;
    _renewLease = false;
    if (existingLease != null && !renew && previousSize?.cols == size.cols) {
      return;
    }

    _ensureLeaseHeartbeat();
    final requestEpoch = _leaseEpoch;
    _leaseRequestInFlight = true;
    try {
      final leaseId = await api.holdPaneSize(
        widget.paneId,
        cols: size.cols,
        rows: size.rows,
        session: session,
        leaseId: existingLease,
      );
      if (!_wantsTerminalLease || requestEpoch != _leaseEpoch) {
        await api.releasePaneSize(widget.paneId, leaseId, session: session);
        return;
      }
      _terminalLeaseId = leaseId;
      _leaseApi = api;
      _leaseSession = session;
      _leasedSize = size;
      if (existingLease == null || previousSize?.cols != size.cols) {
        await ref
            .read(
              paneReadProvider((
                bridgeId: widget.bridgeId,
                paneId: widget.paneId,
              )).notifier,
            )
            .refresh();
      }
    } on ApiException {
      // Best effort: the heartbeat retries acquisition if a lease expires or
      // the bridge is temporarily unreachable.
      _terminalLeaseId = null;
      _leaseApi = null;
      _leaseSession = null;
      _leasedSize = null;
    } finally {
      _leaseRequestInFlight = false;
      if (_leaseSyncAgain) {
        _leaseSyncAgain = false;
        _queueLeaseSync();
      }
    }
  }

  Future<void> _releaseTerminalLease() async {
    _leaseEpoch += 1;
    _leaseHeartbeat?.cancel();
    _leaseHeartbeat = null;
    _renewLease = false;
    final leaseId = _terminalLeaseId;
    final api = _leaseApi;
    final session = _leaseSession;
    _terminalLeaseId = null;
    _leaseApi = null;
    _leaseSession = null;
    _leasedSize = null;
    if (leaseId == null || api == null) return;
    try {
      await api.releasePaneSize(widget.paneId, leaseId, session: session);
    } on ApiException {
      // The bridge TTL releases the controller if teardown cannot reach it.
    }
  }

  Future<void> _sendReply() async {
    final l10n = context.l10n;
    // 发送前 trim（对齐 collie composer）：尾随换行会变成额外的 Enter 打进 PTY。
    final text = _replyController.text.trim();
    if (text.isEmpty || _sending) return;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null) return;
    // 屏幕上有对话框时，reply 路径是「打字 + 盲发 Enter」——回车可能批准
    // 对话框高亮的默认选项（collie issue #34 类事故）。先确认；
    // 自由文本逃生行（"Type something."）仍可经「仍发送」打字回答。
    if (_lastPromptRegion != null && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(ctx.l10n.pendingDialogTitle),
          content: Text(ctx.l10n.pendingDialogBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(ctx.l10n.sendAnyway),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
    setState(() => _sending = true);
    try {
      final res = await api.sendReply(
        widget.paneId,
        text,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (res.success) {
        _replyController.clear();
        _toast(l10n.sent);
      } else if (res.promptChanged) {
        _toast(l10n.screenChangedRetry);
      } else if (res.textDelivered) {
        _toast(l10n.textDeliveredWarning);
      } else {
        _toast(l10n.sendFailed(res.error ?? l10n.unknownError));
      }
      await _refreshAll();
    } on ApiException catch (e) {
      _toast(l10n.sendFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendKeys(List<String> keys) async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _sending) return;
    setState(() => _sending = true);
    try {
      final res = await api.sendKeys(
        widget.paneId,
        keys,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (!res.success) {
        _toast(
          res.promptChanged
              ? l10n.screenChangedShort
              : l10n.keyFailed(res.error ?? l10n.unknownError),
        );
      }
      await _refreshAll();
    } on ApiException catch (e) {
      _toast(l10n.keyFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 点按对话框按钮走共用防护链 helper（对齐 collie dialog-guard 的
  /// prompt-select 路径）：新鲜读取 → 重新派生模型 → 结构相等校验 →
  /// 带 expectedPrompt 发键。这里只把结果映射成 toast 并触发刷新。
  Future<void> _tapPromptOption(PromptModel tapped, PromptOption opt) async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _sending) return;
    final session = ref.read(sessionFilterProvider(widget.bridgeId));
    setState(() => _sending = true);
    try {
      final result = await tapPromptOption(
        api: api,
        paneId: widget.paneId,
        session: session,
        tapped: tapped,
        opt: opt,
      );
      if (!mounted) return;
      switch (result.outcome) {
        case PromptTapOutcome.sent:
          _toast(l10n.sent);
        case PromptTapOutcome.changed:
          _toast(l10n.screenChangedRetry);
        case PromptTapOutcome.failed:
          _toast(l10n.sendFailed(result.error ?? l10n.unknownError));
      }
      // failed（含 readPane 抛 ApiException）不刷新，与现状一致。
      if (result.outcome != PromptTapOutcome.failed) {
        await _refreshAll();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _refreshAll() async {
    await ref
        .read(
          paneReadProvider((bridgeId: widget.bridgeId, paneId: widget.paneId))
              .notifier,
        )
        .refresh();
    await ref.read(bridgeSnapshotProvider(widget.bridgeId).notifier).refresh();
  }

  Future<void> _openHistory(String title) async {
    await _releaseTerminalLease();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => HistoryScreen(
          bridgeId: widget.bridgeId,
          paneId: widget.paneId,
          title: title,
        ),
      ),
    );
    if (mounted) _queueLeaseSync();
  }

  /// 相册选图 → 上传到宿主机 → 返回的路径插进回复框（agent 按路径读图）。
  Future<void> _pickAndUpload() async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    if (api == null || _sending) return;
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
    );
    if (picked == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final res = await api.uploadImage(
        widget.paneId,
        picked.path,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      if (res.success && res.path != null) {
        final current = _replyController.text;
        final path = res.path!;
        _replyController.text = current.isEmpty ? path : '$current $path';
        _toast(l10n.imageUploaded);
      } else {
        _toast(l10n.uploadFailed(res.error ?? l10n.unknownError));
      }
    } on ApiException catch (e) {
      _toast(l10n.uploadFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 重命名 agent：调 herdr pane.rename，AppBar 标题随下一次快照轮询刷新。
  Future<void> _rename() async {
    final l10n = context.l10n;
    final api = ref.read(apiProvider(widget.bridgeId));
    final pane = ref
        .read(bridgeSnapshotProvider(widget.bridgeId))
        .data
        ?.paneById(widget.paneId);
    if (api == null || pane == null || _sending) return;
    final label = await showRenamePaneDialog(context, pane);
    if (label == null || !mounted) return;
    setState(() => _sending = true);
    try {
      final res = await api.renamePane(
        widget.paneId,
        label,
        session: ref.read(sessionFilterProvider(widget.bridgeId)),
      );
      if (!mounted) return;
      _toast(
        res.success
            ? (label.isEmpty ? l10n.aliasCleared : l10n.renamed)
            : (res.error ?? l10n.renameFailedShort),
      );
      if (res.success) await _refreshAll();
    } on ApiException catch (e) {
      _toast(l10n.renameFailed('$e'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final paneKey = (bridgeId: widget.bridgeId, paneId: widget.paneId);
    final readState = ref.watch(paneReadProvider(paneKey));
    final snapshotState = ref.watch(bridgeSnapshotProvider(widget.bridgeId));
    final snap = snapshotState.data;
    final pane = snap?.paneById(widget.paneId);
    final readOnly = snap?.readOnly ?? false;
    final terminalAutoResize = ref.watch(terminalAutoResizeProvider);
    final storedTerminalFontSize = ref.watch(terminalFontSizeProvider);
    final terminalFontSize = _pinchFontSize ?? storedTerminalFontSize;
    final canLoadEarlier =
        _atTop &&
        readState.data?.truncated == true &&
        (readState.historyLines ?? 0) < PaneReadNotifier.historyLineSteps.last;

    // 新内容到达且用户在底部 → 跟随。
    ref.listen(paneReadProvider(paneKey), (prev, next) {
      if (_stickToBottom &&
          next.historyLines == null &&
          next.data != prev?.data) {
        _scrollToBottom();
      }
    });

    final text = readState.data?.text ?? '';
    final lines = splitLines(parseAnsi(text));
    // 尾部对话框识别：命中则菜单区域换成原生按钮（问题与前言保持原文）。
    // shell pane 的输出不是 agent 对话框，误判成按钮会盲发方向键，跳过。
    final promptRegion = text.isEmpty || (pane?.isShell ?? false)
        ? null
        : detectPromptSelectRegion(lines);
    _lastPromptRegion = promptRegion;
    final mirrorLines = promptRegion != null
        ? trimTrailingBlank(lines.sublist(0, promptRegion.startLine))
        : trimTrailingBlank(lines);

    return Scaffold(
      backgroundColor: mirrorBackground,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              pane?.displayName ?? widget.paneId,
              style: const TextStyle(fontSize: 16),
            ),
            if (pane != null)
              Text(
                [
                  pane.workspaceLabel,
                  if (pane.tabLabel != null) pane.tabLabel!,
                  pane.isShell ? l10n.shellPane : pane.agent,
                ].where((part) => part.isNotEmpty).join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          // shell pane 的 status 是缺省 unknown，显示状态 chip 只会误导。
          if (pane != null && !pane.isShell)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                label: Text(statusLabel(l10n, pane.status)),
                visualDensity: VisualDensity.compact,
                side: BorderSide.none,
                backgroundColor: statusColor(
                  Theme.of(context).colorScheme,
                  pane.status,
                ).withValues(alpha: 0.15),
              ),
            ),
          IconButton(
            tooltip: l10n.refreshTooltip,
            icon: const Icon(Icons.refresh),
            onPressed: _refreshAll,
          ),
          if (pane != null && !readOnly)
            IconButton(
              tooltip: l10n.renameTooltip,
              icon: const Icon(Icons.edit_outlined),
              onPressed: _sending ? null : _rename,
            ),
          if (pane?.hasSession == true)
            IconButton(
              tooltip: l10n.historyTooltip,
              icon: const Icon(Icons.history),
              onPressed: () => _openHistory(pane?.displayName ?? widget.paneId),
            ),
        ],
      ),
      body: Column(
        children: [
          if (readOnly)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                l10n.readOnlyMode,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (readState.error != null)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                l10n.outputRefreshFailed('${readState.error}'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final resizeEnabled =
                    terminalAutoResize && pane != null && !readOnly;
                final previewGrid = _terminalGridSize(
                  context,
                  constraints,
                  fontSize: terminalFontSize,
                );
                if (!_isPinching || !resizeEnabled) {
                  _updateTerminalViewport(
                    context,
                    constraints,
                    enabled: resizeEnabled,
                    fontSize: terminalFontSize,
                  );
                }
                return text.isEmpty && readState.error == null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              l10n.readingOutput,
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      )
                    : Listener(
                        key: const Key('terminal-output-gesture-area'),
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: _handleTerminalPointerDown,
                        onPointerMove: _handleTerminalPointerMove,
                        onPointerUp: _handleTerminalPointerEnd,
                        onPointerCancel: _handleTerminalPointerEnd,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            NotificationListener<ScrollNotification>(
                              onNotification: _handleTerminalScrollNotification,
                              child: SingleChildScrollView(
                                controller: _scrollController,
                                physics: _isPinching
                                    ? const NeverScrollableScrollPhysics()
                                    : const ClampingScrollPhysics(),
                                padding: _mirrorPadding,
                                child: SizedBox(
                                  width: double.infinity,
                                  child: SelectableText.rich(
                                    TextSpan(
                                      children: [
                                        linesToSpan(
                                          mirrorLines,
                                          fontSize: terminalFontSize,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (canLoadEarlier)
                              Positioned(
                                top: 8,
                                left: 0,
                                right: 0,
                                child: Center(
                                  child: IconButton.filledTonal(
                                    key: const Key(
                                      'load-earlier-output-button',
                                    ),
                                    tooltip: l10n.terminalLoadEarlier,
                                    visualDensity: VisualDensity.compact,
                                    onPressed: _historyLoading
                                        ? null
                                        : () => _loadEarlierOutput(paneKey),
                                    icon: _historyLoading
                                        ? const SizedBox.square(
                                            dimension: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.keyboard_arrow_up_rounded,
                                          ),
                                  ),
                                ),
                              ),
                            if (readState.historyLines != null)
                              Positioned(
                                top: 8,
                                right: 8,
                                child: IconButton.filledTonal(
                                  key: const Key('back-to-live-button'),
                                  tooltip: l10n.backToLive,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _historyLoading
                                      ? null
                                      : () => _resumeLiveOutput(paneKey),
                                  icon: const Icon(Icons.play_arrow_rounded),
                                ),
                              ),
                            if (_isPinching)
                              Positioned(
                                top: 12,
                                left: 0,
                                right: 0,
                                child: IgnorePointer(
                                  child: Center(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: 0.78,
                                        ),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        child: Text(
                                          '${terminalFontSize.toStringAsFixed(1)} pt'
                                          ' · ${previewGrid.cols}×${previewGrid.rows}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
              },
            ),
          ),
          if (!readOnly && promptRegion != null)
            ContentPane(
              child: _PromptCard(
                model: promptRegion.model,
                enabled: !_sending,
                onTap: (opt) => _tapPromptOption(promptRegion.model, opt),
              ),
            ),
          if (!readOnly) ...[
            const Divider(height: 1),
            ContentPane(
              child: _buildComposer(context, shell: pane?.isShell == true),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context, {required bool shell}) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              // 不加纵向 padding：水平 ListView 会把交叉轴紧约束传给子项，
              // padding 会把 chip 的 48dp 触摸目标钳小。
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: _keys.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final k = _keys[i];
                return ActionChip(
                  label: Text(k.label),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onPressed: _sending ? null : () => _sendKeys(k.keys),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: context.l10n.sendImageTooltip,
                  icon: const Icon(Icons.image_outlined),
                  onPressed: _sending ? null : _pickAndUpload,
                ),
                Expanded(
                  child: TextField(
                    controller: _replyController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: shell
                          ? context.l10n.shellReplyHint
                          : context.l10n.replyHint,
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : _sendReply,
                  icon: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 识别出的单选对话框卡片：选项按钮。问题与前言保留在上方镜像区原文，
/// 卡片不再重复显示问题文本。
class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.model,
    required this.enabled,
    required this.onTap,
  });

  final PromptModel model;
  final bool enabled;
  final ValueChanged<PromptOption> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final opt in model.options)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: enabled ? () => onTap(opt) : null,
                  style: FilledButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(opt.label),
                      if (opt.description != null)
                        Text(
                          opt.description!,
                          style: theme.textTheme.bodySmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
