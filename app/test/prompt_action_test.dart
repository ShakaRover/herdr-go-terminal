/// prompt_action 防护链测试：手写 fake BridgeApi（项目无 mockito；对齐
/// easytier_runtime_test.dart 的 fake 方式——不跑真网络，靠覆写基类方法）。
///
/// 覆盖六条路径：识别一致→sent；freshModel 为 null→changed；不一致→changed；
/// sendKeys promptChanged→changed；sendKeys 其它失败→failed；ApiException→failed。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/ansi/ansi.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/blocks/prompt_action.dart';
import 'package:herdrgo/blocks/prompt_select.dart';
import 'package:herdrgo/model/models.dart';

/// 含可识别 prompt 的 pane 文本（question 含 "?"，footer 可分类，
/// 菜单为尾部连续 1,2 后缀）。供 fake 的 readPane 返回。
const _samePromptText = '''
Proceed?

  1. Yes
  2. No

Tab to amend · Esc to cancel
''';

/// tapped 模型：与真实用法一致，从同一份文本派生（signature 才有意义）。
final _tapped = detectPromptSelect(splitLines(parseAnsi(_samePromptText)))!;
final _opt = _tapped.options.first;

/// fake BridgeApi：脚本化 readPane 的返回文本与 sendKeys 的结果/异常。
class _FakeBridgeApi extends BridgeApi {
  _FakeBridgeApi() : super(baseUrl: 'http://127.0.0.1:1');

  String readPaneText = _samePromptText;
  ActionResult sendKeysResult = const ActionResult.ok();
  Object? sendKeysError;
  Object? readPaneError;

  /// 记录 sendKeys 收到的 expectedPrompt，验证防护链把新鲜签名透传给 bridge。
  String? capturedExpectedPrompt;
  List<String>? capturedKeys;
  String? capturedPaneId;
  String? capturedSession;

  @override
  Future<PaneRead> readPane(String paneId, {int? lines, String? session}) async {
    final e = readPaneError;
    if (e != null) throw e;
    return PaneRead(
      paneId: paneId,
      text: readPaneText,
      truncated: false,
      revision: 1,
    );
  }

  @override
  Future<ActionResult> sendKeys(
    String paneId,
    List<String> keys, {
    String? session,
    String? expectedPrompt,
  }) async {
    capturedPaneId = paneId;
    capturedKeys = keys;
    capturedSession = session;
    capturedExpectedPrompt = expectedPrompt;
    final e = sendKeysError;
    if (e != null) throw e;
    return sendKeysResult;
  }
}

void main() {
  test('识别一致 → sent，且 expectedPrompt 透传新鲜签名', () async {
    final api = _FakeBridgeApi();
    final res = await tapPromptOption(
      api: api,
      paneId: 'p1',
      session: 's1',
      tapped: _tapped,
      opt: _opt,
    );
    expect(res.outcome, PromptTapOutcome.sent);
    expect(res.error, isNull);
    expect(api.capturedExpectedPrompt, _tapped.signature);
    expect(api.capturedKeys, ['1']);
    expect(api.capturedPaneId, 'p1');
    expect(api.capturedSession, 's1');
  });

  test('freshModel 为 null → changed，不发键', () async {
    final api = _FakeBridgeApi()..readPaneText = 'plain output, no menu';
    final res = await tapPromptOption(
      api: api,
      paneId: 'p1',
      session: 's1',
      tapped: _tapped,
      opt: _opt,
    );
    expect(res.outcome, PromptTapOutcome.changed);
    expect(res.error, isNull);
    expect(api.capturedKeys, isNull);
  });

  test('freshModel 与 tapped 不一致 → changed，不发键', () async {
    // 选项标签不同（"Abort" 替换 "No"）→ 结构不等。
    final api = _FakeBridgeApi()
      ..readPaneText = '''
Proceed?

  1. Yes
  2. Abort

Tab to amend · Esc to cancel
''';
    final res = await tapPromptOption(
      api: api,
      paneId: 'p1',
      session: 's1',
      tapped: _tapped,
      opt: _opt,
    );
    expect(res.outcome, PromptTapOutcome.changed);
    expect(api.capturedKeys, isNull);
  });

  test('sendKeys promptChanged → changed', () async {
    final api = _FakeBridgeApi()
      ..sendKeysResult =
          const ActionResult.failure('prompt changed', promptChanged: true);
    final res = await tapPromptOption(
      api: api,
      paneId: 'p1',
      session: 's1',
      tapped: _tapped,
      opt: _opt,
    );
    expect(res.outcome, PromptTapOutcome.changed);
    expect(res.error, isNull);
  });

  test('sendKeys 其它失败 → failed，透传 error', () async {
    final api = _FakeBridgeApi()
      ..sendKeysResult = const ActionResult.failure('bridge 内部错误');
    final res = await tapPromptOption(
      api: api,
      paneId: 'p1',
      session: 's1',
      tapped: _tapped,
      opt: _opt,
    );
    expect(res.outcome, PromptTapOutcome.failed);
    expect(res.error, 'bridge 内部错误');
  });

  test('sendKeys 抛 ApiException → failed，error 为 e.toString()', () async {
    final api = _FakeBridgeApi()
      ..sendKeysError = const ApiException('网络不可达', statusCode: 502);
    final res = await tapPromptOption(
      api: api,
      paneId: 'p1',
      session: 's1',
      tapped: _tapped,
      opt: _opt,
    );
    expect(res.outcome, PromptTapOutcome.failed);
    expect(res.error, const ApiException('网络不可达', statusCode: 502).toString());
  });

  test('readPane 抛 ApiException → failed', () async {
    final api = _FakeBridgeApi()
      ..readPaneError = const ApiException('unauthorized', statusCode: 401);
    final res = await tapPromptOption(
      api: api,
      paneId: 'p1',
      session: 's1',
      tapped: _tapped,
      opt: _opt,
    );
    expect(res.outcome, PromptTapOutcome.failed);
    expect(res.error, contains('unauthorized'));
  });
}
