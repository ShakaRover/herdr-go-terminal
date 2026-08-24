/// AgentPreviewSheet（长按预览卡）widget 测试：手写 fake BridgeApi + provider
/// override（项目无 mockito；对齐 easytier_runtime_test.dart / prompt_action_test.dart
/// 的 fake 方式）。
///
/// 覆盖：
/// - pane 文本可识别 prompt-select → 底部渲染选项按钮；点选项走防护链发键
///   （fake 捕获 keys），成功后关卡 + 「已发送」SnackBar；
/// - 未识别 → 渲染通用动作行（继续(Enter)/Ctrl+C/↑/↓）；点「继续」盲发 Enter
///   （不带 expectedPrompt），成功后关卡；
/// - 「打开详情」关卡并 push AgentScreen。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/blocks/prompt_select.dart';
import 'package:herdrgo/l10n/generated/app_localizations.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/ansi/ansi.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:herdrgo/ui/agent/agent_screen.dart';
import 'package:herdrgo/ui/dashboard/agent_preview_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 含可识别 prompt 的 pane 文本（与 prompt_action_test 同款形状）。
const _promptText = '''
Proceed?

  1. Yes
  2. No

Tab to amend · Esc to cancel
''';

const _plainText = 'plain output, no menu\nworking on it...\n';

/// fake BridgeApi：脚本化 readPane 文本与 sendKeys 结果，捕获发键参数。
class _FakeBridgeApi extends BridgeApi {
  _FakeBridgeApi() : super(baseUrl: 'http://127.0.0.1:1');

  String readPaneText = _promptText;
  int readPaneCount = 0;

  List<String>? capturedKeys;
  String? capturedExpectedPrompt;
  String? capturedSession;

  @override
  Future<PaneRead> readPane(
    String paneId, {
    int? lines,
    String? session,
  }) async {
    readPaneCount++;
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
    capturedKeys = keys;
    capturedSession = session;
    capturedExpectedPrompt = expectedPrompt;
    return const ActionResult.ok();
  }
}

const _pane = PaneInfo(
  paneId: 'w0.1',
  workspaceId: 'w0',
  workspaceLabel: 'ws0',
  workspaceNumber: 0,
  tabId: 'w0:t0',
  agent: 'claude',
  status: AgentStatus.blocked,
  cwd: '/repo',
  focused: false,
  tabLabel: 't0',
);

/// 以按钮形式弹出预览卡（ProviderScope 齐 prefs + api family override）。
///
/// api 只对 bridgeId 'b1' 注入——sheet 若路由到别的 bridgeId 会拿到 null，
/// 渲染/发键路径随即失败，从而断言 bridgeId 真的传进了取数链路。
Future<void> _pumpSheet(
  WidgetTester tester,
  _FakeBridgeApi api, {
  bool pinned = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWith(
          (ref, bridgeId) => bridgeId == 'b1' ? api : null,
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              child: const Text('open'),
              onPressed: () => AgentPreviewSheet.show(
                context,
                bridgeId: 'b1',
                pane: _pane,
                pinned: pinned,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  // FutureBuilder 的读盘 + sheet 动画。
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('识别到 prompt-select → 渲染选项按钮', (tester) async {
    await _pumpSheet(tester, _FakeBridgeApi());
    expect(find.text('Yes'), findsOneWidget);
    expect(find.text('No'), findsOneWidget);
    // 渲染选项按钮时不出现通用动作行。
    expect(find.text('继续 (Enter)'), findsNothing);
    expect(find.text('Ctrl+C'), findsNothing);
  });

  testWidgets('未识别 → 渲染通用动作行', (tester) async {
    await _pumpSheet(tester, _FakeBridgeApi()..readPaneText = _plainText);
    expect(find.text('继续 (Enter)'), findsOneWidget);
    expect(find.text('Ctrl+C'), findsOneWidget);
    expect(find.text('↑'), findsOneWidget);
    expect(find.text('↓'), findsOneWidget);
  });

  testWidgets('长内容首次打开时定位到最新输出', (tester) async {
    final api = _FakeBridgeApi()
      ..readPaneText = List.generate(60, (i) => 'output line $i').join('\n');
    await _pumpSheet(tester, api);

    final preview = find.descendant(
      of: find.byType(AgentPreviewSheet),
      matching: find.byType(SingleChildScrollView),
    );
    final scrollView = tester.widget<SingleChildScrollView>(preview);
    expect(scrollView.controller, isNotNull);
    final position = scrollView.controller!.position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(
      position.pixels,
      moreOrLessEquals(position.maxScrollExtent, epsilon: 0.1),
    );
  });

  testWidgets('点选项 → 防护链发键 → 关卡 + 「已发送」', (tester) async {
    final api = _FakeBridgeApi();
    await _pumpSheet(tester, api);

    await tester.tap(find.text('Yes'));
    await tester.pumpAndSettle();

    // 防护链：新鲜读取（防 stale）后带 expectedPrompt 发键。keys 依 family
    // 配方（permission 只发数字，select 会尾随 Enter），从真实模型派生。
    final expected = detectPromptSelect(splitLines(parseAnsi(_promptText)))!
        .options
        .first
        .keys;
    expect(api.readPaneCount, greaterThanOrEqualTo(2));
    expect(api.capturedKeys, expected);
    expect(api.capturedExpectedPrompt, isNotNull);
    // 发送成功 → 卡已关，「已发送」SnackBar 挂在根 Scaffold 上。
    expect(find.byType(AgentPreviewSheet), findsNothing);
    expect(find.text('已发送'), findsOneWidget);
  });

  testWidgets('通用动作「继续 (Enter)」→ 盲发 Enter（不带 expectedPrompt）→ 关卡', (
    tester,
  ) async {
    final api = _FakeBridgeApi()..readPaneText = _plainText;
    await _pumpSheet(tester, api);

    await tester.tap(find.text('继续 (Enter)'));
    await tester.pumpAndSettle();

    expect(api.capturedKeys, ['Enter']);
    expect(api.capturedExpectedPrompt, isNull);
    expect(find.byType(AgentPreviewSheet), findsNothing);
  });

  testWidgets('「打开详情」→ 关卡并 push AgentScreen', (tester) async {
    await _pumpSheet(tester, _FakeBridgeApi());

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(find.byType(AgentPreviewSheet), findsNothing);
    expect(find.byType(AgentScreen), findsOneWidget);
  });
}
