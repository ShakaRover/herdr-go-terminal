/// Rust bridge 的 HTTP 客户端（`/api/v1`，spec §3 契约）。
///
/// - 所有请求带 `x-requested-with: XMLHttpRequest`，让前置身份代理以状态码而非
///   302 重定向回应未认证请求。
/// - 所有请求带 `Origin: <baseUrl 的 scheme://authority>`：bridge 对非 loopback
///   来源的修改类端点强制校验 Origin（缺失 403 "origin required"），浏览器自动
///   携带，原生客户端必须显式设置，否则 LAN 地址下 reply/keys/upload 全部 403。
/// - `GET /api/v1/pane/:id` 支持 ETag：带 `if-none-match`，304 时回放上次的 body。
/// - 读 pane/历史带 `x-bridge-seen: 1`，让 bridge 把该 pane 标记为已见。
/// - 业务失败回真实状态码 + JSON `{error, code}`：409（prompt_changed）与
///   502 text_delivered 是正常拒绝/部分成功，转成 [ActionResult] 返回而不抛异常。
/// - 超时：GET 10s，修改类 20s，上传 60s。
library;

import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';

import '../l10n/generated/app_localizations.dart';
import '../model/history.dart';
import '../model/models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isAuth => statusCode == 401 || statusCode == 403;

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}

/// POST reply/keys/upload 的结果。对齐 bridge 的 JSON 错误信封。
class ActionResult {
  const ActionResult.ok()
    : success = true,
      error = null,
      textDelivered = false,
      promptChanged = false,
      path = null;

  const ActionResult.failure(
    this.error, {
    this.textDelivered = false,
    this.promptChanged = false,
  }) : success = false,
       path = null;

  const ActionResult.uploaded(this.path)
    : success = true,
      error = null,
      textDelivered = false,
      promptChanged = false;

  final bool success;
  final String? error;

  /// 文本已打进终端但回车失败——**不可重发**（重发会重复输入）。
  final bool textDelivered;

  /// bridge 因 expectedPrompt 不匹配而拒绝（界面已变，需要重新读取）。
  final bool promptChanged;

  /// upload 成功时返回的宿主机文件路径。
  final String? path;
}

class BridgeApi {
  BridgeApi({
    required String baseUrl,
    Map<String, String> headers = const {},
    AppLocalizations? localizations,
  }) : _localizations =
           localizations ?? lookupAppLocalizations(const Locale('en')),
       _dio = Dio(
         BaseOptions(
           baseUrl: _normalizeBaseUrl(baseUrl),
           headers: {
             'x-requested-with': 'XMLHttpRequest',
             'Origin': _originOf(baseUrl),
             ...headers,
           },
           connectTimeout: const Duration(seconds: 2),
           receiveTimeout: const Duration(seconds: 20),
         ),
       );

  final Dio _dio;
  final AppLocalizations _localizations;

  /// 归一化后的 baseUrl（诊断与测试用）。
  String get baseUrl => _dio.options.baseUrl;

  /// pane 读的 ETag 缓存：`session paneId -> (etag, body)`。
  /// 与 web 端一致：只在 body 完整解析后记录，容量 20，FIFO 淘汰。
  final Map<String, (String, PaneRead)> _paneCache = {};

  static const _getTimeout = Duration(seconds: 5);
  static const _mutationTimeout = Duration(seconds: 20);
  // Bridge 最坏链路：manifest 5s + create 5s + start 25s（Herdr 20s
  // + bridge 余量）+ prompt text/key 各 5s。客户端必须晚于 bridge 收口，
  // 否则 pane 已创建时只能得到无响应体超时，无法返回 created IDs。
  static const createAgentTimeout = Duration(seconds: 60);
  static const _uploadTimeout = Duration(seconds: 60);

  static String _normalizeBaseUrl(String raw) {
    var url = raw.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// bridge 的 Origin 校验只看 scheme://authority（与 Host 一致即同源）。
  static String _originOf(String baseUrl) {
    final uri = Uri.parse(_normalizeBaseUrl(baseUrl));
    return '${uri.scheme}://${uri.authority}';
  }

  ApiException _wrap(DioException e) {
    _logTransportFailure(e);
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? serverMsg;
    if (data is Map<String, dynamic> && data['error'] is String) {
      serverMsg = data['error'] as String;
    } else if (data is String && data.isNotEmpty) {
      serverMsg = data;
    }
    return ApiException(serverMsg ?? _transportReason(e), statusCode: status);
  }

  static void _logTransportFailure(DioException e) {
    if (e.response != null) return;
    final Object? inner = e.error;
    final detail = switch (inner) {
      SocketException() =>
        'SocketException(message=${inner.message}, '
            'address=${inner.address?.address}, port=${inner.port}, '
            'osError=${inner.osError?.message}, '
            'errno=${inner.osError?.errorCode})',
      OSError() =>
        'OSError(message=${inner.message}, errno=${inner.errorCode})',
      _ => '${inner ?? e.message}',
    };
    stderr.writeln(
      '[bridge-api] transport failure '
      'method=${e.requestOptions.method} uri=${e.requestOptions.uri} '
      'type=${e.type.name} error=$detail',
    );
  }

  /// 无响应 body 的传输层错误映射为简短原因，避免把 dio 冗长的英文
  /// 库文案（"The connection errored: ..."）直接露在横幅/toast 里。
  String _transportReason(DioException e) => switch (e.type) {
    DioExceptionType.connectionError => _localizations.networkUnreachable,
    DioExceptionType.connectionTimeout => _localizations.connectionTimeout,
    DioExceptionType.sendTimeout => _localizations.sendTimeout,
    DioExceptionType.receiveTimeout => _localizations.responseTimeout,
    DioExceptionType.transformTimeout => _localizations.transferTimeout,
    DioExceptionType.badCertificate => _localizations.badCertificate,
    DioExceptionType.badResponse => _localizations.serverError,
    DioExceptionType.cancel => _localizations.requestCancelled,
    DioExceptionType.unknown => e.message ?? _localizations.networkError,
  };

  Map<String, dynamic> _queryWithSession(String? session) =>
      session == null || session.trim().isEmpty
      ? const {}
      : {'session': session.trim()};

  // -------------------------------------------------------------------------
  // 只读端点
  // -------------------------------------------------------------------------

  Future<BridgeConfig> getConfig() async {
    try {
      final res = await _dio.get(
        '/api/v1/config',
        options: Options(receiveTimeout: _getTimeout),
      );
      return BridgeConfig.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Future<Snapshot> getSnapshot({
    String? session,
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _dio.get(
        '/api/v1/snapshot',
        queryParameters: _queryWithSession(session),
        cancelToken: cancelToken,
        options: Options(receiveTimeout: _getTimeout),
      );
      return Snapshot.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Future<List<String>> getAgentKinds({String? session}) async {
    try {
      final res = await _dio.get(
        '/api/v1/agents/kinds',
        queryParameters: _queryWithSession(session),
        options: Options(receiveTimeout: _getTimeout),
      );
      final data = res.data;
      if (data is! Map<String, dynamic> || data['agents'] is! List) {
        throw ApiException(
          _localizations.invalidJsonResponse,
          statusCode: res.statusCode,
        );
      }
      return (data['agents'] as List).whereType<String>().toList();
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// 读取 pane 近期输出。命中 304 时返回缓存 body（[PaneRead.notModified] = true）。
  Future<PaneRead> readPane(
    String paneId, {
    int? lines,
    String? session,
  }) async {
    final cacheKey = '${session ?? ''} $paneId';
    final cached = _paneCache[cacheKey];
    try {
      final res = await _dio.get(
        '/api/v1/pane/$paneId',
        queryParameters: {..._queryWithSession(session), 'lines': ?lines},
        options: Options(
          receiveTimeout: _getTimeout,
          headers: {
            'x-bridge-seen': '1',
            if (cached != null) 'if-none-match': cached.$1,
          },
          // 304 不是错误，交给下面的逻辑处理。
          validateStatus: (s) => s != null && (s < 400 || s == 304),
        ),
      );
      if (res.statusCode == 304 && cached != null) {
        return cached.$2.copyAsNotModified();
      }
      final read = PaneRead.fromJson(res.data as Map<String, dynamic>);
      final etag = res.headers.value('etag');
      if (etag != null) {
        _paneCache[cacheKey] = (etag, read);
        if (_paneCache.length > 20) {
          _paneCache.remove(_paneCache.keys.first);
        }
      }
      return read;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// 翻页读取对话历史：不给 before = 最新一页；before = 某条的 uuid 继续向更早翻。
  Future<PaneHistory> fetchHistory(
    String paneId, {
    int? limit,
    String? before,
    String? session,
  }) async {
    try {
      final res = await _dio.get(
        '/api/v1/pane/$paneId/history',
        queryParameters: {
          ..._queryWithSession(session),
          'limit': ?limit,
          'before': ?before,
        },
        options: Options(
          receiveTimeout: _getTimeout,
          headers: const {'x-bridge-seen': '1'},
        ),
      );
      return paneHistoryFromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  // -------------------------------------------------------------------------
  // 写端点
  // -------------------------------------------------------------------------

  /// 2xx 响应的判定：bridge 成功统一回 `{ok:true}`。
  ActionResult _actionFrom(Response<dynamic> res) {
    final data = res.data;
    if (data is! Map<String, dynamic>) {
      throw ApiException(
        _localizations.invalidJsonResponse,
        statusCode: res.statusCode,
      );
    }
    if (data['ok'] == true) return const ActionResult.ok();
    return ActionResult.failure(
      data['error'] is String
          ? data['error'] as String
          : _localizations.unknownError,
    );
  }

  /// 修改类 POST：只接 2xx，业务失败（非 2xx + `{error, code}`）由 dio 抛出的
  /// DioException 中恢复——409/prompt_changed 是正常拒绝（屏幕已变），
  /// text_delivered 表示文本已写入终端（不可重发），两者转成 ActionResult
  /// 返回而不抛异常，其余（含 502/404 的其它 code）照常抛出。
  Future<ActionResult> _postAction(
    String path,
    Object? body, {
    String? session,
  }) async {
    try {
      final res = await _dio.post(
        path,
        data: body,
        queryParameters: _queryWithSession(session),
        options: Options(receiveTimeout: _mutationTimeout),
      );
      return _actionFrom(res);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final data = e.response?.data;
      if (data is Map<String, dynamic>) {
        if (status == 409 || data['code'] == 'prompt_changed') {
          return ActionResult.failure(
            data['error'] as String? ?? 'prompt changed',
            promptChanged: true,
          );
        }
        if (data['code'] == 'text_delivered') {
          return ActionResult.failure(
            data['error'] as String? ?? _localizations.sendFailedShort,
            textDelivered: true,
          );
        }
      }
      throw _wrap(e);
    }
  }

  /// 发送回复文本。`submit` = 附带回车；`expectedPrompt` 用于 prompt-select
  /// 竞态防护（bridge 校验屏幕未变才写入）。
  Future<ActionResult> sendReply(
    String paneId,
    String text, {
    bool submit = true,
    String? session,
    String? expectedPrompt,
  }) => _postAction('/api/v1/pane/$paneId/reply', {
    'text': text,
    'submit': submit,
    'expectedPrompt': ?expectedPrompt,
  }, session: session);

  /// 发送特殊按键（esc / ctrl+c / up / down / tab / shift+tab ...）。
  Future<ActionResult> sendKeys(
    String paneId,
    List<String> keys, {
    String? session,
    String? expectedPrompt,
  }) => _postAction('/api/v1/pane/$paneId/keys', {
    'keys': keys,
    'expectedPrompt': ?expectedPrompt,
  }, session: session);

  /// Acquire or renew the controller lease that keeps this pane at the phone
  /// viewport size. A missing [leaseId] takes over from the current client.
  Future<String> holdPaneSize(
    String paneId, {
    required int cols,
    required int rows,
    String? session,
    String? leaseId,
  }) async {
    try {
      final res = await _dio.post(
        '/api/v1/pane/$paneId/resize',
        queryParameters: _queryWithSession(session),
        data: {'cols': cols, 'rows': rows, 'leaseId': ?leaseId},
        options: Options(receiveTimeout: _mutationTimeout),
      );
      final data = res.data;
      final returnedLease = data is Map<String, dynamic>
          ? data['leaseId']
          : null;
      if (returnedLease is! String || returnedLease.isEmpty) {
        throw ApiException(
          _localizations.invalidJsonResponse,
          statusCode: res.statusCode,
        );
      }
      return returnedLease;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// Release a phone-size controller lease. The bridge treats stale leases as
  /// already released, so this is safe during page teardown.
  Future<void> releasePaneSize(
    String paneId,
    String leaseId, {
    String? session,
  }) async {
    try {
      await _dio.delete(
        '/api/v1/pane/$paneId/resize/$leaseId',
        queryParameters: _queryWithSession(session),
        options: Options(receiveTimeout: _mutationTimeout),
      );
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Future<ActionResult> closePane(String paneId, {String? session}) =>
      _postAction('/api/v1/pane/$paneId/close', null, session: session);

  /// 设置 pane 标签；空白标签 = 清除。
  Future<ActionResult> renamePane(
    String paneId,
    String label, {
    String? session,
  }) => _postAction('/api/v1/pane/$paneId/rename', {
    'label': label,
  }, session: session);

  Future<CreateAgentResult> createAgent({
    required String name,
    required String kind,
    required String cwd,
    String? workspaceId,
    String? workspaceLabel,
    String? initialPrompt,
    String? session,
  }) async {
    try {
      final res = await _dio.post(
        '/api/v1/agents',
        data: {
          'name': name,
          'kind': kind,
          'cwd': cwd,
          'workspaceId': ?workspaceId,
          'workspaceLabel': ?workspaceLabel,
          'initialPrompt': ?initialPrompt,
        },
        queryParameters: _queryWithSession(session),
        options: Options(receiveTimeout: createAgentTimeout),
      );
      final data = res.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException(
          _localizations.invalidJsonResponse,
          statusCode: res.statusCode,
        );
      }
      final result = CreateAgentResult.fromJson(data);
      if (!result.success || !result.hasCreatedPane) {
        throw ApiException(
          _localizations.invalidJsonResponse,
          statusCode: res.statusCode,
        );
      }
      return result;
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map<String, dynamic> &&
          data['created'] is Map<String, dynamic> &&
          (data['created'] as Map<String, dynamic>)['paneId'] is String &&
          ((data['created'] as Map<String, dynamic>)['paneId'] as String)
              .isNotEmpty) {
        return CreateAgentResult.partial(
          data,
          data['error'] is String
              ? data['error'] as String
              : _localizations.unknownError,
        );
      }
      throw _wrap(e);
    }
  }

  /// 上传图片，返回宿主机路径供回复中引用。
  /// 413/415/400（超限/类型/坏请求）转成 failure 供 UI 提示，其余抛异常。
  Future<ActionResult> uploadImage(
    String paneId,
    String filePath, {
    String? session,
  }) async {
    try {
      final res = await _dio.post(
        '/api/v1/pane/$paneId/upload',
        data: FormData.fromMap({
          'file': await MultipartFile.fromFile(filePath),
        }),
        queryParameters: _queryWithSession(session),
        options: Options(
          receiveTimeout: _uploadTimeout,
          sendTimeout: _uploadTimeout,
        ),
      );
      final data = res.data;
      if (data is! Map<String, dynamic>) {
        throw ApiException(
          _localizations.invalidJsonResponse,
          statusCode: res.statusCode,
        );
      }
      if (data['ok'] == true && data['path'] is String) {
        return ActionResult.uploaded(data['path'] as String);
      }
      return ActionResult.failure(
        data['error'] is String
            ? data['error'] as String
            : _localizations.uploadFailedShort,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400 || status == 413 || status == 415) {
        final data = e.response?.data;
        return ActionResult.failure(
          data is Map<String, dynamic> && data['error'] is String
              ? data['error'] as String
              : _localizations.uploadFailedShort,
        );
      }
      throw _wrap(e);
    }
  }
}
