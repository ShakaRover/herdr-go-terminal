/// prompt-select 的中性模型 —— 从 collie `harness/prompt-model.ts` 移植。
///
/// 单选对话框 = 问题 + 选项列表 + family（family 钉死按键配方：select 要
/// 数字+Enter，其余 family 只发数字）。
library;

enum PromptFamily { select, permission, trust, plan }

class PromptOption {
  const PromptOption({required this.label, this.description, required this.keys});

  final String label;
  final String? description;

  /// 依序发送的按键。select: ["N", "Enter"]；permission/trust/plan: ["N"]
  /// （这些对话框按数字即确认，尾随 Enter 会泄漏到下一个界面）。
  final List<String> keys;
}

class PromptModel {
  const PromptModel({
    required this.question,
    required this.options,
    required this.family,
    required this.signature,
  });

  final String question;
  final List<PromptOption> options;
  final PromptFamily family;

  /// 对话框区域的内容签名（从第一个选项上方一路到 footer 的文本）。
  /// herdr 的 revision 上游是桩（恒为 0），这个内容签名才是真正的新鲜度
  /// 校验：两个「同形不同主题」的对话框 signature 不同，陈旧点击不会误批。
  final String signature;
}

bool _sameKeys(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((x) => x);

/// 两次派生是否指向同一个屏幕上的对话框（不只是同形）。
bool promptsEqual(PromptModel a, PromptModel b) =>
    a.family == b.family &&
    a.question == b.question &&
    a.signature == b.signature &&
    a.options.length == b.options.length &&
    List.generate(
      a.options.length,
      (i) =>
          a.options[i].label == b.options[i].label &&
          _sameKeys(a.options[i].keys, b.options[i].keys),
    ).every((x) => x);
