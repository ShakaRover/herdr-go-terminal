import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/model/models.dart';
import 'package:herdrgo/state/snapshot.dart';

PaneInfo pane(String id, AgentStatus status, {int? lastActiveAt}) => PaneInfo(
      paneId: id,
      workspaceId: 'w1',
      workspaceLabel: 'ws',
      workspaceNumber: 1,
      tabId: 'w1:t1',
      agent: 'claude',
      status: status,
      cwd: '/repo',
      focused: false,
      lastActiveAt: lastActiveAt,
    );

void main() {
  test('triageSorted 按 blocked > working > unknown > idle > done 排序', () {
    final sorted = triageSorted([
      pane('idle1', AgentStatus.idle),
      pane('done1', AgentStatus.done),
      pane('blocked1', AgentStatus.blocked),
      pane('working1', AgentStatus.working),
      pane('unknown1', AgentStatus.unknown),
    ]);
    expect(
      sorted.map((p) => p.paneId).toList(),
      ['blocked1', 'working1', 'unknown1', 'idle1', 'done1'],
    );
  });

  test('同级按 lastActiveAt 新的在前，缺失视为最旧', () {
    final sorted = triageSorted([
      pane('old', AgentStatus.blocked, lastActiveAt: 1000),
      pane('none', AgentStatus.blocked),
      pane('new', AgentStatus.blocked, lastActiveAt: 2000),
    ]);
    expect(
      sorted.map((p) => p.paneId).toList(),
      ['new', 'old', 'none'],
    );
  });

  test('输入列表不被修改', () {
    final input = [pane('a', AgentStatus.idle), pane('b', AgentStatus.blocked)];
    triageSorted(input);
    expect(input.map((p) => p.paneId).toList(), ['a', 'b']);
  });
}
