import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/l10n/generated/app_localizations.dart';
import 'package:herdrgo/model/history.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/ui/history/history_screen.dart';

class _FakeHistoryApi extends BridgeApi {
  _FakeHistoryApi(this.pages) : super(baseUrl: 'http://127.0.0.1:1');

  final List<HistoryPage> pages;
  int _nextPage = 0;

  @override
  Future<PaneHistory> fetchHistory(
    String paneId, {
    int? limit,
    String? before,
    String? session,
  }) async => pages[_nextPage++];
}

class _DelayedHistoryApi extends BridgeApi {
  _DelayedHistoryApi() : super(baseUrl: 'http://127.0.0.1:1');

  final response = Completer<PaneHistory>();

  @override
  Future<PaneHistory> fetchHistory(
    String paneId, {
    int? limit,
    String? before,
    String? session,
  }) => response.future;
}

List<TranscriptEntry> _entries(String prefix, int count) => List.generate(
  count,
  (i) => TranscriptEntry(
    uuid: '$prefix-$i',
    ts: '2026-08-24T12:${i.toString().padLeft(2, '0')}:00Z',
    role: i.isEven ? TranscriptRole.user : TranscriptRole.assistant,
    parts: [TextPart(List.filled(3, '$prefix message $i').join('\n'))],
  ),
);

Future<void> _pumpHistory(WidgetTester tester, BridgeApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWith(
          (ref, bridgeId) => bridgeId == 'b1' ? api : null,
        ),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: HistoryScreen(bridgeId: 'b1', paneId: 'p1', title: 'agent'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('历史页异步加载后锚定最新消息并显示滚动条', (tester) async {
    final entries = _entries('history', 20);
    final api = _DelayedHistoryApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWith(
            (ref, bridgeId) => bridgeId == 'b1' ? api : null,
          ),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HistoryScreen(bridgeId: 'b1', paneId: 'p1', title: 'agent'),
        ),
      ),
    );
    await tester.pump();

    api.response.complete(
      HistoryPage(
        entries: entries,
        hasMore: false,
        total: entries.length,
        fileTruncated: false,
      ),
    );
    await tester.pumpAndSettle();

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    expect(scrollbar.interactive, isTrue);

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.reverse, isTrue);
    expect(listView.controller, same(scrollbar.controller));
    final position = listView.controller!.position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, moreOrLessEquals(0, epsilon: 0.1));
    expect(
      find.textContaining('history message 19').hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('加载更早记录后保持原消息的阅读位置', (tester) async {
    final latest = _entries('latest', 12);
    final older = _entries('older', 8);
    final api = _FakeHistoryApi([
      HistoryPage(
        entries: latest,
        hasMore: true,
        total: latest.length + older.length,
        fileTruncated: false,
      ),
      HistoryPage(
        entries: older,
        hasMore: false,
        total: latest.length + older.length,
        fileTruncated: false,
      ),
    ]);
    await _pumpHistory(tester, api);

    final listView = tester.widget<ListView>(find.byType(ListView));
    final controller = listView.controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pump();
    final oldPixels = controller.position.pixels;

    await tester.tap(find.text('加载更早'));
    await tester.pumpAndSettle();

    expect(controller.position.maxScrollExtent, greaterThan(oldPixels));
    expect(
      controller.position.pixels,
      moreOrLessEquals(oldPixels, epsilon: 0.1),
    );
  });
}
