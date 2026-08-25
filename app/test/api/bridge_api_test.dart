/// bridge_api 客户端契约测试：对齐 Rust bridge 的 /api/v1 契约。
///
/// 用 loopback HttpServer 回放响应，断言真实发出的方法/路径/头/体：
/// - 端点全部在 /api/v1 下；
/// - reply/keys body 用 expectedPrompt（camelCase）；
/// - 读 pane/历史带 x-bridge-seen；
/// - 业务失败 = 真实状态码 + JSON {error, code}（409 prompt_changed、
///   502 text_delivered 转 ActionResult，其余抛 ApiException）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/model/history.dart';

class _Recorded {
  _Recorded(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final List<int> body;

  String get bodyText => utf8.decode(body);
  Map<String, dynamic> get bodyJson =>
      jsonDecode(bodyText) as Map<String, dynamic>;
}

class _Harness {
  _Harness(this._handler);

  final Future<void> Function(HttpRequest req) _handler;
  final requests = <_Recorded>[];
  HttpServer? server;

  /// 起 server 并返回指向它的客户端。
  Future<BridgeApi> start() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server = s;
    s.listen((req) async {
      final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      requests.add(_Recorded(req.method, req.uri, req.headers, body));
      try {
        await _handler(req);
      } catch (_) {
        req.response.statusCode = 500;
        await req.response.close();
      }
    });
    return BridgeApi(baseUrl: 'http://127.0.0.1:${s.port}');
  }

  Future<void> stop() async => server?.close();
}

Future<void> _json(HttpRequest req, int status, Object body) async {
  req.response.statusCode = status;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

/// 起 harness 并返回 (harness, api)。
Future<(_Harness, BridgeApi)> _start(
  Future<void> Function(HttpRequest req) handler,
) async {
  final h = _Harness(handler);
  final api = await h.start();
  return (h, api);
}

void main() {
  test('createAgent 客户端超时覆盖 bridge 的合法最坏执行时间', () {
    expect(
      BridgeApi.createAgentTimeout,
      greaterThan(const Duration(seconds: 50)),
    );
  });

  test('getConfig 走 /api/v1/config，带 Origin 与 x-requested-with', () async {
    final (h, api) = await _start(
      (req) => _json(req, 200, {
        'push': false,
        'vapidPublicKey': '',
        'build': 'b1234',
      }),
    );
    addTearDown(h.stop);
    final config = await api.getConfig();
    expect(h.requests.single.method, 'GET');
    expect(h.requests.single.uri.path, '/api/v1/config');
    expect(
      h.requests.single.headers.value('origin'),
      'http://127.0.0.1:${h.server!.port}',
    );
    expect(
      h.requests.single.headers.value('x-requested-with'),
      'XMLHttpRequest',
    );
    expect(config.build, 'b1234');
    expect(config.push, isFalse);
  });

  test('getSnapshot 带 session 查询参数并解析 device', () async {
    final (h, api) = await _start(
      (req) => _json(req, 200, {
        'bridge': 'connected',
        'agents': [
          {
            'paneId': 'w1:p1',
            'workspaceId': 'w1',
            'workspaceLabel': 'ws',
            'workspaceNumber': 1,
            'tabId': 'w1:t1',
            'agent': 'claude',
            'status': 'blocked',
            'cwd': '/repo',
            'focused': false,
          },
        ],
        'shellPanes': [],
        'workspaces': [],
        'tabs': [],
        'sessions': [],
        'ts': 123,
        'device': {'enforced': true, 'device': 'd1', 'authorized': false},
      }),
    );
    addTearDown(h.stop);
    final snap = await api.getSnapshot(session: 's2');
    expect(h.requests.single.uri.path, '/api/v1/snapshot');
    expect(h.requests.single.uri.queryParameters['session'], 's2');
    expect(snap.bridgeConnected, isTrue);
    expect(snap.agents, hasLength(1));
    expect(snap.agents.single.paneId, 'w1:p1');
    expect(snap.device?.enforced, isTrue);
    expect(snap.readOnly, isTrue);
  });

  test('getAgentKinds 带 session 并解析动态 agent 列表', () async {
    final (h, api) = await _start(
      (req) => _json(req, 200, {
        'agents': ['claude', 'codex'],
      }),
    );
    addTearDown(h.stop);

    final kinds = await api.getAgentKinds(session: 'work');

    expect(h.requests.single.uri.path, '/api/v1/agents/kinds');
    expect(h.requests.single.uri.queryParameters['session'], 'work');
    expect(kinds, ['claude', 'codex']);
  });

  test('createAgent 发送选择项并解析新 pane', () async {
    final (h, api) = await _start(
      (req) => _json(req, 201, {
        'ok': true,
        'agentName': 'codex-1',
        'workspaceId': 'w1',
        'tabId': 't2',
        'paneId': 'p3',
      }),
    );
    addTearDown(h.stop);

    final result = await api.createAgent(
      name: 'codex-1',
      kind: 'codex',
      cwd: '/repo',
      workspaceId: 'w1',
      initialPrompt: 'fix the test',
      session: 'work',
    );

    final req = h.requests.single;
    expect(req.method, 'POST');
    expect(req.uri.path, '/api/v1/agents');
    expect(req.uri.queryParameters['session'], 'work');
    expect(req.bodyJson, {
      'name': 'codex-1',
      'kind': 'codex',
      'cwd': '/repo',
      'workspaceId': 'w1',
      'initialPrompt': 'fix the test',
    });
    expect(result.success, isTrue);
    expect(result.agentName, 'codex-1');
    expect(result.workspaceId, 'w1');
    expect(result.tabId, 't2');
    expect(result.paneId, 'p3');
  });

  test('createAgent 初始化失败保留已创建 pane 且不抛异常', () async {
    final (h, api) = await _start(
      (req) => _json(req, 502, {
        'error': 'agent startup timed out',
        'code': 'agent_start_failed',
        'created': {'workspaceId': 'w1', 'tabId': 't1', 'paneId': 'p1'},
      }),
    );
    addTearDown(h.stop);

    final result = await api.createAgent(
      name: 'claude-1',
      kind: 'claude',
      cwd: '/repo',
    );

    expect(result.success, isFalse);
    expect(result.hasCreatedPane, isTrue);
    expect(result.paneId, 'p1');
    expect(result.error, 'agent startup timed out');
  });

  test('createAgent 创建前失败仍抛 ApiException', () async {
    final (h, api) = await _start(
      (req) => _json(req, 400, {
        'error': 'unsupported agent: unknown',
        'code': 'unsupported_agent_kind',
      }),
    );
    addTearDown(h.stop);

    await expectLater(
      api.createAgent(name: 'agent-1', kind: 'unknown', cwd: '/repo'),
      throwsA(
        isA<ApiException>()
            .having((error) => error.statusCode, 'statusCode', 400)
            .having(
              (error) => error.message,
              'message',
              'unsupported agent: unknown',
            ),
      ),
    );
  });

  test('readPane 带 x-bridge-seen，解析 body', () async {
    final (h, api) = await _start((req) async {
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.headers.set('etag', '"v1"');
      req.response.write(
        jsonEncode({
          'paneId': 'p1',
          'text': 'hello',
          'truncated': false,
          'revision': 7,
        }),
      );
      await req.response.close();
    });
    addTearDown(h.stop);
    final read = await api.readPane('p1');
    expect(h.requests.single.uri.path, '/api/v1/pane/p1');
    expect(h.requests.single.headers.value('x-bridge-seen'), '1');
    expect(h.requests.single.headers.value('if-none-match'), isNull);
    expect(read.text, 'hello');
    expect(read.revision, 7);
    expect(read.notModified, isFalse);
  });

  test('readPane 命中 304 时回放缓存 body', () async {
    var reads = 0;
    final (h, api) = await _start((req) async {
      reads++;
      if (reads == 1) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.headers.set('etag', '"v1"');
        req.response.write(
          jsonEncode({
            'paneId': 'p1',
            'text': 'fresh',
            'truncated': false,
            'revision': 9,
          }),
        );
      } else {
        req.response.statusCode = 304;
        req.response.headers.set('etag', '"v1"');
      }
      await req.response.close();
    });
    addTearDown(h.stop);
    final first = await api.readPane('p1', session: 's1');
    expect(first.notModified, isFalse);
    final second = await api.readPane('p1', session: 's1');
    expect(h.requests, hasLength(2));
    expect(h.requests.last.headers.value('if-none-match'), '"v1"');
    expect(second.notModified, isTrue);
    expect(second.text, 'fresh');
    expect(second.revision, 9);
  });

  test('fetchHistory 走 /api/v1/pane/:id/history 并带 seen 头', () async {
    final (h, api) = await _start(
      (req) => _json(req, 200, {
        'paneId': 'p1',
        'available': true,
        'entries': [
          {
            'uuid': 'u1',
            'ts': '2026-08-13T07:12:34.567Z',
            'role': 'user',
            'parts': [
              {'kind': 'text', 'text': '帮我修个 bug'},
            ],
          },
        ],
        'hasMore': false,
        'total': 1,
        'fileTruncated': false,
      }),
    );
    addTearDown(h.stop);
    final page = await api.fetchHistory('p1');
    expect(h.requests.single.uri.path, '/api/v1/pane/p1/history');
    expect(h.requests.single.headers.value('x-bridge-seen'), '1');
    expect(page, isA<HistoryPage>());
    final entries = (page as HistoryPage).entries;
    expect(entries, hasLength(1));
    expect(entries.single.uuid, 'u1');
  });

  test('sendReply 走 /api/v1，body 用 expectedPrompt', () async {
    final (h, api) = await _start((req) => _json(req, 200, {'ok': true}));
    addTearDown(h.stop);
    final res = await api.sendReply(
      'p1',
      'hi',
      session: 's1',
      expectedPrompt: '❯ 1. Yes',
    );
    expect(res.success, isTrue);
    final req = h.requests.single;
    expect(req.method, 'POST');
    expect(req.uri.path, '/api/v1/pane/p1/reply');
    expect(req.uri.queryParameters['session'], 's1');
    expect(req.bodyJson, {
      'text': 'hi',
      'submit': true,
      'expectedPrompt': '❯ 1. Yes',
    });
  });

  test('sendKeys 不带 expectedPrompt 时 body 无该键', () async {
    final (h, api) = await _start((req) => _json(req, 200, {'ok': true}));
    addTearDown(h.stop);
    final res = await api.sendKeys('p1', ['escape', 'up']);
    expect(res.success, isTrue);
    expect(h.requests.single.uri.path, '/api/v1/pane/p1/keys');
    expect(h.requests.single.bodyJson, {
      'keys': ['escape', 'up'],
    });
  });

  test('holdPaneSize 获取并续租手机终端尺寸', () async {
    final (h, api) = await _start(
      (req) => _json(req, 200, {'ok': true, 'leaseId': 'lease-1'}),
    );
    addTearDown(h.stop);

    final leaseId = await api.holdPaneSize(
      'w1:p1',
      cols: 48,
      rows: 31,
      session: 'work',
      leaseId: 'lease-1',
    );

    expect(leaseId, 'lease-1');
    final req = h.requests.single;
    expect(req.method, 'POST');
    expect(req.uri.path, '/api/v1/pane/w1:p1/resize');
    expect(req.uri.queryParameters['session'], 'work');
    expect(req.bodyJson, {'cols': 48, 'rows': 31, 'leaseId': 'lease-1'});
  });

  test('releasePaneSize 删除对应租约', () async {
    final (h, api) = await _start((req) => _json(req, 200, {'ok': true}));
    addTearDown(h.stop);

    await api.releasePaneSize('w1:p1', 'lease-1', session: 'work');

    final req = h.requests.single;
    expect(req.method, 'DELETE');
    expect(req.uri.path, '/api/v1/pane/w1:p1/resize/lease-1');
    expect(req.uri.queryParameters['session'], 'work');
  });

  test('409 prompt_changed 转为 promptChanged failure', () async {
    final (h, api) = await _start(
      (req) => _json(req, 409, {
        'error': 'prompt changed',
        'code': 'prompt_changed',
      }),
    );
    addTearDown(h.stop);
    final res = await api.sendReply('p1', 'hi', expectedPrompt: '旧屏幕');
    expect(res.success, isFalse);
    expect(res.promptChanged, isTrue);
    expect(res.textDelivered, isFalse);
    expect(res.error, 'prompt changed');
  });

  test('502 text_delivered 转为 textDelivered failure', () async {
    final (h, api) = await _start(
      (req) => _json(req, 502, {
        'error': 'herdr error',
        'code': 'text_delivered',
        'textDelivered': true,
      }),
    );
    addTearDown(h.stop);
    final res = await api.sendReply('p1', 'hi');
    expect(res.success, isFalse);
    expect(res.textDelivered, isTrue);
    expect(res.promptChanged, isFalse);
    expect(res.error, 'herdr error');
  });

  test('其它业务失败抛 ApiException，带状态码与服务端 error', () async {
    final (h, api) = await _start(
      (req) => _json(req, 400, {'error': 'no keys', 'code': 'bad_request'}),
    );
    addTearDown(h.stop);
    await expectLater(
      api.sendKeys('p1', []),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'no keys'),
      ),
    );
  });

  test('401 映射为 isAuth 的 ApiException', () async {
    final (h, api) = await _start(
      (req) => _json(req, 401, {'error': 'unauthorized', 'code': 'auth'}),
    );
    addTearDown(h.stop);
    await expectLater(
      api.getSnapshot(),
      throwsA(
        predicate<ApiException>((e) => e.isAuth && e.message == 'unauthorized'),
      ),
    );
  });

  test('closePane/renamePane 走 /api/v1 且 ok 成功', () async {
    final (h, api) = await _start((req) => _json(req, 200, {'ok': true}));
    addTearDown(h.stop);
    expect((await api.closePane('p1')).success, isTrue);
    expect((await api.renamePane('p1', 'lab')).success, isTrue);
    expect(h.requests[0].uri.path, '/api/v1/pane/p1/close');
    expect(h.requests[1].uri.path, '/api/v1/pane/p1/rename');
    expect(h.requests[1].bodyJson, {'label': 'lab'});
  });

  test('rename 400 抛 ApiException 而非 failure', () async {
    final (h, api) = await _start(
      (req) => _json(req, 400, {'error': 'bad label', 'code': 'bad_request'}),
    );
    addTearDown(h.stop);
    await expectLater(
      api.renamePane('p1', 'x'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'bad label'),
      ),
    );
  });

  test('uploadImage 成功返回宿主机路径', () async {
    final (h, api) = await _start(
      (req) =>
          _json(req, 200, {'ok': true, 'path': '/var/herdr/uploads/p1/a.png'}),
    );
    addTearDown(h.stop);
    final tmp = _tmpPng();
    final res = await api.uploadImage('p1', tmp.path);
    expect(res.success, isTrue);
    expect(res.path, '/var/herdr/uploads/p1/a.png');
    final req = h.requests.single;
    expect(req.uri.path, '/api/v1/pane/p1/upload');
    expect(req.headers.contentType!.mimeType, 'multipart/form-data');
    expect(req.bodyText, contains('name="file"'));
  });

  test('uploadImage 413 转 failure 并透传服务端 error', () async {
    final (h, api) = await _start(
      (req) => _json(req, 413, {
        'error': 'image too large (max 10 MB)',
        'code': 'payload_too_large',
      }),
    );
    addTearDown(h.stop);
    final res = await api.uploadImage('p1', _tmpPng().path);
    expect(res.success, isFalse);
    expect(res.error, 'image too large (max 10 MB)');
  });

  test('uploadImage 401 抛 isAuth ApiException', () async {
    final (h, api) = await _start(
      (req) => _json(req, 401, {'error': 'unauthorized', 'code': 'auth'}),
    );
    addTearDown(h.stop);
    await expectLater(
      api.uploadImage('p1', _tmpPng().path),
      throwsA(predicate<ApiException>((e) => e.isAuth)),
    );
  });
}

File _tmpPng() {
  final f = File(
    '${Directory.systemTemp.path}/bridge_api_test_${DateTime.now().microsecondsSinceEpoch}.png',
  )..writeAsBytesSync([1, 2, 3]);
  addTearDown(() => f.delete());
  return f;
}
