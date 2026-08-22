import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/model/history.dart';

void main() {
  group('paneHistoryFromJson', () {
    test('available:true 完整解析', () {
      final h = paneHistoryFromJson({
        'paneId': 'w1:p1',
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
          {
            'uuid': 'u2',
            'ts': '',
            'role': 'assistant',
            'parts': [
              {'kind': 'thinking', 'text': '先看看…'},
              {
                'kind': 'tool',
                'name': 'Read',
                'summary': '读取 main.dart',
                'result': {'text': '文件内容', 'isError': false},
              },
              {'kind': 'text', 'text': '已修复'},
              {'kind': 'future-kind', 'text': '未知类型兜底'},
            ],
          },
        ],
        'hasMore': true,
        'total': 42,
        'fileTruncated': false,
      });

      expect(h, isA<HistoryPage>());
      final page = h as HistoryPage;
      expect(page.hasMore, isTrue);
      expect(page.total, 42);
      expect(page.entries, hasLength(2));
      expect(page.entries[0].role, TranscriptRole.user);
      expect(page.entries[1].parts[1], isA<ToolPart>());
      final tool = page.entries[1].parts[1] as ToolPart;
      expect(tool.name, 'Read');
      expect(tool.result!.text, '文件内容');
      // 未知 part 类型兜底为 TextPart。
      expect(page.entries[1].parts[3], isA<TextPart>());
    });

    test('available:false 解析 reason', () {
      final h = paneHistoryFromJson(
          {'paneId': 'w1:p1', 'available': false, 'reason': 'no-log'});
      expect(h, isA<HistoryUnavailable>());
      expect((h as HistoryUnavailable).reason, 'no-log');
    });

    test('宽容解析：entries 缺失/类型不符', () {
      final h = paneHistoryFromJson({'available': true});
      final page = h as HistoryPage;
      expect(page.entries, isEmpty);
      expect(page.hasMore, isFalse);
    });
  });
}
