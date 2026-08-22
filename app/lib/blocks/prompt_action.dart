/// prompt-select 点按防护链 —— 「识别 → 防护链 → 发键」的共用 helper。
///
/// 逻辑对齐 agent_screen.dart 的 _tapPromptOption：新鲜读取 pane →
/// 重新识别 → 与 tapped 结构相等 → 带 expectedPrompt 发键。供详情页与
/// 长按预览卡共用，session 传当前 sessionFilter。
library;

import '../ansi/ansi.dart';
import '../api/bridge_api.dart';
import 'prompt_model.dart';
import 'prompt_select.dart';

/// 点按 prompt-select 选项的防护链结果。
enum PromptTapOutcome { sent, changed, failed }

class PromptTapResult {
  const PromptTapResult(this.outcome, [this.error]);

  final PromptTapOutcome outcome;
  final String? error;
}

/// 防护链：新鲜读取 pane → 重新识别 → 与 tapped 结构相等 → 带
/// expectedPrompt 发键。
///
/// - 新鲜模型识别不出（`null`）或与 tapped 结构不等 → [PromptTapOutcome.changed]；
/// - `sendKeys` 返回 `success` → [PromptTapOutcome.sent]；
/// - `sendKeys` 返回 `promptChanged` → [PromptTapOutcome.changed]；
/// - 其它 `ActionResult.failure` → [PromptTapOutcome.failed]（透传 error）；
/// - `ApiException` → [PromptTapOutcome.failed]（error 为 `e.toString()`）。
Future<PromptTapResult> tapPromptOption({
  required BridgeApi api,
  required String paneId,
  required String? session,
  required PromptModel tapped,
  required PromptOption opt,
}) async {
  try {
    final fresh = await api.readPane(paneId, lines: 200, session: session);
    final freshModel =
        detectPromptSelect(splitLines(parseAnsi(fresh.text)));
    if (freshModel == null || !promptsEqual(freshModel, tapped)) {
      return const PromptTapResult(PromptTapOutcome.changed);
    }
    final res = await api.sendKeys(paneId, opt.keys,
        session: session, expectedPrompt: freshModel.signature);
    if (res.success) {
      return const PromptTapResult(PromptTapOutcome.sent);
    }
    if (res.promptChanged) {
      return const PromptTapResult(PromptTapOutcome.changed);
    }
    return PromptTapResult(PromptTapOutcome.failed, res.error);
  } on ApiException catch (e) {
    return PromptTapResult(PromptTapOutcome.failed, e.toString());
  }
}
