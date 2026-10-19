import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/state/sent_history.dart';
import 'package:herdrgo/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _keyA = (bridgeId: 'b1', session: null, paneId: 'w1:p1');
const _keyB = (bridgeId: 'b1', session: 'work', paneId: 'w1:p1');

void main() {
  test('updatedSentHistory 去重置顶并限制条数', () {
    var history = <String>[];
    for (var i = 0; i < sentHistoryLimit + 5; i++) {
      history = updatedSentHistory(history, 'cmd-$i');
    }
    expect(history.length, sentHistoryLimit);
    expect(history.first, 'cmd-${sentHistoryLimit + 4}');
    expect(history.last, 'cmd-5');

    final deduped = updatedSentHistory(['a', 'b', 'c'], 'b');
    expect(deduped, ['b', 'a', 'c']);
    expect(updatedSentHistory(['a'], '   '), ['a']);
  });

  test('按 bridge/session/pane 隔离持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await container.read(sentHistoryProvider(_keyA).notifier).add('one');
    await container.read(sentHistoryProvider(_keyA).notifier).add('two');
    await container.read(sentHistoryProvider(_keyB).notifier).add('work');

    expect(container.read(sentHistoryProvider(_keyA)), ['two', 'one']);
    expect(container.read(sentHistoryProvider(_keyB)), ['work']);
    expect(readSentHistory(prefs, _keyA), ['two', 'one']);
  });
}
