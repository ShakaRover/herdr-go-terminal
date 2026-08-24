import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/api/bridge_api.dart';
import 'package:herdrgo/model/history.dart';
import 'package:herdrgo/state/bridges.dart';
import 'package:herdrgo/ui/history/history_screen.dart';

class _FakeHistoryApi extends BridgeApi {
  _FakeHistoryApi(this.pages) : super(baseUrl: 'http://127.0.0.1:1');

  final List<HistoryPage> pages;
  int _nextPage = 0;

  @override
  Future<PaneHistory> fetchHistory(String paneId,
          {int? limit, String? before, String? session}) async =>
      pages[_nextPage++];
}

List<TranscriptEntry> _entries(String prefix, int count) => List.generate(
      count,
      (i) => TranscriptEntry(
        uuid: '$prefix-$i',
        ts: '2026-08-24T12:${i.toString().padLeft(2, '0')}:00Z',
        role: i.isEven ? TranscriptRole.user : TranscriptRole.assistant,
        parts: [
          TextPart(List.filled(3, '$prefix message $i').join('\n')),
        ],
      ),
    );

Future<void> _pumpHistory(WidgetTester tester, BridgeApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWith(
            (ref, bridgeId) => bridgeId == 'b1' ? api : null),
      ],
      child: const MaterialApp(
        home: HistoryScreen(
          bridgeId: 'b1',
          paneId: 'p1',
          title: 'agent',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('历史页首次加载后定位到最新消息', (tester) async {
    final entries = _entries('history', 20);
    final api = _FakeHistoryApi([
      HistoryPage(
        entries: entries,
        hasMore: false,
        total: entries.length,
        fileTruncated: false,
      ),
    ]);
    await _pumpHistory(tester, api);

    final listView = tester.widget<ListView>(find.byType(ListView));
    expect(listView.controller, isNotNull);
    final position = listView.controller!.position;
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, moreOrLessEquals(
      position.maxScrollExtent,
      epsilon: 0.1,
    ));
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
    controller.jumpTo(0);
    await tester.pump();
    final oldMaxExtent = controller.position.maxScrollExtent;

    await tester.tap(find.text('加载更早'));
    await tester.pumpAndSettle();

    final addedExtent = controller.position.maxScrollExtent - oldMaxExtent;
    expect(addedExtent, greaterThan(0));
    expect(controller.position.pixels, moreOrLessEquals(
      addedExtent,
      epsilon: 0.1,
    ));
  });
}
