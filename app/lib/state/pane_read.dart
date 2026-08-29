/// 单 pane 输出流：agent 详情页的数据源（per bridge）。
///
/// 进入页面、恢复前台与断流时用 REST 同步完整画面；连接正常后由 bridge
/// WebSocket 推送完整帧或可恢复的行增量。离开页面即销毁全部订阅与 timer。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/bridge_api.dart';
import '../model/models.dart';
import 'bridges.dart';
import 'settings.dart';
import 'snapshot.dart';

/// pane 输出流的 family key。
typedef PaneReadKey = ({String bridgeId, String paneId});

class PaneReadState {
  const PaneReadState({this.data, this.error, this.streaming = false});

  final PaneRead? data;
  final Object? error;
  final bool streaming;
}

class PaneReadNotifier extends Notifier<PaneReadState> {
  PaneReadNotifier(this.paneKey);

  static const fallbackInterval = Duration(milliseconds: 2500);
  static const retryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  final PaneReadKey paneKey;
  StreamSubscription<PaneRead>? _streamSubscription;
  Timer? _fallbackTimer;
  Timer? _retryTimer;
  PaneRead? _data;
  Object? _error;
  BridgeApi? _api;
  String? _session;
  TerminalRefreshRate? _rate;
  bool? _foreground;
  int? _refreshGeneration;
  bool _disposed = false;
  bool _configured = false;
  int _generation = 0;
  int _retryAttempt = 0;

  @override
  PaneReadState build() {
    final api = ref.read(apiProvider(paneKey.bridgeId));
    final session = ref.read(sessionFilterProvider(paneKey.bridgeId));
    final rate = ref.read(terminalRefreshRateProvider);
    final foreground = ref.read(appForegroundProvider);
    ref.listen(apiProvider(paneKey.bridgeId), (_, _) => _queueConfigure());
    ref.listen(
      sessionFilterProvider(paneKey.bridgeId),
      (_, _) => _queueConfigure(),
    );
    ref.listen(terminalRefreshRateProvider, (_, _) => _queueConfigure());
    ref.listen(appForegroundProvider, (_, _) => _queueConfigure());
    ref.onDispose(_dispose);
    Future.microtask(() => _configure(api, session, rate, foreground));
    return PaneReadState(data: _data, error: _error);
  }

  void _queueConfigure() {
    Future.microtask(
      () => _configure(
        ref.read(apiProvider(paneKey.bridgeId)),
        ref.read(sessionFilterProvider(paneKey.bridgeId)),
        ref.read(terminalRefreshRateProvider),
        ref.read(appForegroundProvider),
      ),
    );
  }

  Future<void> _configure(
    BridgeApi? api,
    String? session,
    TerminalRefreshRate rate,
    bool foreground,
  ) async {
    if (_disposed ||
        (_api == api &&
            _session == session &&
            _rate == rate &&
            _foreground == foreground)) {
      return;
    }
    final wasConfigured = _configured;
    final previousApi = _api;
    final previousSession = _session;
    final previousForeground = _foreground;
    final sessionChanged = wasConfigured && previousSession != session;
    final needsRestSync =
        !wasConfigured ||
        previousApi != api ||
        previousSession != session ||
        (foreground && previousForeground != true);
    _configured = true;
    _api = api;
    _session = session;
    _rate = rate;
    _foreground = foreground;
    _retryAttempt = 0;
    final generation = ++_generation;
    if (sessionChanged) {
      _data = null;
      _error = null;
      state = const PaneReadState();
    }
    await _cancelTransport();
    if (_disposed || generation != _generation || !foreground || api == null) {
      return;
    }
    if (needsRestSync) {
      await refresh();
      if (_disposed || generation != _generation) return;
    }
    _startStream(generation);
  }

  void _startStream(int generation) {
    final api = _api;
    final rate = _rate;
    if (_disposed ||
        generation != _generation ||
        api == null ||
        rate == null ||
        _foreground != true) {
      return;
    }
    var finished = false;
    _streamSubscription = api
        .watchPane(
          paneKey.paneId,
          lines: 200,
          intervalMs: rate.intervalMs,
          session: _session,
        )
        .listen(
          (read) {
            if (_disposed || generation != _generation) return;
            _retryAttempt = 0;
            _fallbackTimer?.cancel();
            _fallbackTimer = null;
            _accept(read, streaming: true);
          },
          onError: (Object error, StackTrace stack) {
            if (finished) return;
            finished = true;
            _handleStreamEnd(generation, error);
          },
          onDone: () {
            if (finished) return;
            finished = true;
            _handleStreamEnd(
              generation,
              const ApiException('pane stream closed'),
            );
          },
          cancelOnError: true,
        );
  }

  void _handleStreamEnd(int generation, Object error) {
    if (_disposed || generation != _generation || _foreground != true) return;
    _streamSubscription = null;
    if (_data == null) {
      _error = error;
      state = PaneReadState(error: error);
    }
    _startFallback(generation);
    final delay = retryDelays[_retryAttempt.clamp(0, retryDelays.length - 1)];
    _retryAttempt = (_retryAttempt + 1).clamp(0, retryDelays.length - 1);
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () => _startStream(generation));
  }

  void _startFallback(int generation) {
    _fallbackTimer?.cancel();
    unawaited(refresh());
    _fallbackTimer = Timer.periodic(fallbackInterval, (_) {
      if (!_disposed && generation == _generation && _foreground == true) {
        unawaited(refresh());
      }
    });
  }

  Future<void> refresh() async {
    final api = _api ?? ref.read(apiProvider(paneKey.bridgeId));
    final generation = _generation;
    if (api == null ||
        _refreshGeneration == generation ||
        _foreground == false) {
      return;
    }
    final session =
        _session ?? ref.read(sessionFilterProvider(paneKey.bridgeId));
    final startedRevision = _data?.revision;
    _refreshGeneration = generation;
    try {
      final read = await api.readPane(
        paneKey.paneId,
        lines: 200,
        session: session,
      );
      if (!_disposed &&
          generation == _generation &&
          api == _api &&
          session == _session) {
        _accept(
          read,
          streaming: false,
          allowOlder: _data?.revision == startedRevision,
        );
      }
    } catch (error) {
      if (!_disposed &&
          generation == _generation &&
          api == _api &&
          session == _session) {
        _error = error;
        state = PaneReadState(data: _data, error: error);
      }
    } finally {
      if (_refreshGeneration == generation) {
        _refreshGeneration = null;
      }
    }
  }

  void _accept(
    PaneRead read, {
    required bool streaming,
    bool allowOlder = false,
  }) {
    final previous = _data;
    if (!allowOlder && previous != null && read.revision < previous.revision) {
      return;
    }
    if (previous != null &&
        previous.text == read.text &&
        previous.truncated == read.truncated &&
        previous.revision == read.revision) {
      if (_error == null && state.streaming == streaming) return;
    }
    _data = read;
    _error = null;
    state = PaneReadState(data: read, streaming: streaming);
  }

  Future<void> _cancelTransport() async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final subscription = _streamSubscription;
    _streamSubscription = null;
    await subscription?.cancel();
  }

  void _dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation += 1;
    unawaited(_cancelTransport());
  }
}

final paneReadProvider =
    NotifierProvider.family<PaneReadNotifier, PaneReadState, PaneReadKey>(
      PaneReadNotifier.new,
      isAutoDispose: true,
    );
