/// paneReadProvider family key 加 bridgeId 的测试。
///
/// fake api 按 bridge 脚本化 readPane 文本（apiProvider(bridgeId) family
/// override），验证：
/// - paneReadProvider((bridgeId:'b1',paneId:'w0')) 拉到的文本来自 b1 的 fake；
/// - 两个 bridge 的 key 互不串数据；
/// - readPane 带 sessionFilterProvider(bridgeId) 的当前值，两个 bridge 的
///   session 选择互不影响。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/api/bridge_api.dart';
import 'package:herdr_web/model/models.dart';
import 'package:herdr_web/state/bridges.dart';
import 'package:herdr_web/state/pane_read.dart';
import 'package:herdr_web/state/settings.dart';
import 'package:herdr_web/state/snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// fake BridgeApi：脚本化 readPane 文本，捕获 session 参数。
class FakeBridgeApi extends BridgeApi {
  FakeBridgeApi(this.text) : super(baseUrl: 'http://127.0.0.1:1');

  final String text;
  final seenSessions = <String?>[];

  @override
  Future<PaneRead> readPane(String paneId,
      {int? lines, String? session}) async {
    seenSessions.add(session);
    return PaneRead(paneId: paneId, text: text, truncated: false, revision: 1);
  }
}

Future<ProviderContainer> buildContainer(FakeBridgeApi b1, FakeBridgeApi b2) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    sharedPrefsProvider.overrideWithValue(prefs),
    apiProvider.overrideWith((ref, bridgeId) => switch (bridgeId) {
          'b1' => b1,
          'b2' => b2,
          _ => null,
        }),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// 等指定 key 的 pane read 拉取成功（state.data 非空）。
Future<PaneReadState> waitRead(
  ProviderContainer container,
  PaneReadKey key,
) {
  final c = Completer<PaneReadState>();
  final sub = container.listen(paneReadProvider(key), (_, next) {
    if (next.data != null && !c.isCompleted) c.complete(next);
  });
  addTearDown(sub.close);
  return c.future.timeout(const Duration(seconds: 5));
}

void main() {
  test('(b1,w0) 拉到 b1 的文本，(b2,w0) 拉到 b2 的文本，互不串数据', () async {
    final b1 = FakeBridgeApi('text from b1');
    final b2 = FakeBridgeApi('text from b2');
    final container = await buildContainer(b1, b2);

    const k1 = (bridgeId: 'b1', paneId: 'w0');
    const k2 = (bridgeId: 'b2', paneId: 'w0');
    final r1 = waitRead(container, k1);
    final r2 = waitRead(container, k2);
    // 常驻监听（autoDispose），触发首次拉取。
    container.listen(paneReadProvider(k1), (_, _) {});
    container.listen(paneReadProvider(k2), (_, _) {});

    expect((await r1).data!.text, 'text from b1');
    expect((await r2).data!.text, 'text from b2');
    expect(container.read(paneReadProvider(k1)).data!.text, 'text from b1');
    expect(container.read(paneReadProvider(k2)).data!.text, 'text from b2');
  });

  test('readPane 带 sessionFilterProvider(bridgeId) 的当前值，'
      '两个 bridge 的 session 选择互不影响', () async {
    final b1 = FakeBridgeApi('b1');
    final b2 = FakeBridgeApi('b2');
    final container = await buildContainer(b1, b2);

    container.read(sessionFilterProvider('b1').notifier).select('work');
    container.read(sessionFilterProvider('b2').notifier).select('ops');

    const k1 = (bridgeId: 'b1', paneId: 'w0');
    const k2 = (bridgeId: 'b2', paneId: 'w0');
    final r1 = waitRead(container, k1);
    final r2 = waitRead(container, k2);
    container.listen(paneReadProvider(k1), (_, _) {});
    container.listen(paneReadProvider(k2), (_, _) {});
    await r1;
    await r2;

    expect(b1.seenSessions, everyElement('work'));
    expect(b2.seenSessions, everyElement('ops'));
  });
}
