/// prompt-select 识别语法 —— 从 collie `harness/claude/prompt-select.ts`
/// 与其 `markers.ts` 逐行移植（只取 prompt-select 需要的部分）。
///
/// 核心不变式：对话框的 footer 提示栏必须是缓冲区**最后一行非空行**
/// （tail anchor）。已滚上去的菜单下面有真实输出，footer 不在尾部就不匹配，
/// 这是防误报闸门。所有函数都是 `StyledLine[]` 上的纯函数。
library;

import '../ansi/ansi.dart';
import 'prompt_model.dart';

// ---------------------------------------------------------------------------
// markers.ts 移植部分
// ---------------------------------------------------------------------------

/// 整行都是横线/制表字形（忽略空白）：Unicode 制表符 U+2500–U+257F、
/// 方块条 U+2581–U+2584、各类破折号 U+2012–U+2015。ASCII 的 `-`/`=` 刻意
/// 排除，避免把 markdown/代码里的分隔线误判成 TUI 边框。
bool isHorizontalRule(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (compact.length < 3) return false;
  for (final rune in compact.runes) {
    final ok = (rune >= 0x2500 && rune <= 0x257F) ||
        (rune >= 0x2581 && rune <= 0x2584) ||
        (rune >= 0x2012 && rune <= 0x2015);
    if (!ok) return false;
  }
  return true;
}

final _stepGlyph = RegExp(r'[☐☒☑✔✅]');

/// 多问题 AskUserQuestion 的步进头（同一行 ≥2 个步进/勾选字形），例如
/// "←  ☒ Focus area  ☐ Scope  ✔ Submit  →"。单选对话框没有这行；
/// 检测到它必须 bail（一个数字+Enter 会提交只答了一半的表单）。
bool isMultiStepHeader(String text) => _stepGlyph.allMatches(text).length >= 2;

/// 把对话框底部的提示栏分类到 family；不认识则返回 null。
/// footer 是最稳定的判别依据，确认短语钉死按键配方：
/// - "Enter to select …"  → select（数字 THEN Enter）
/// - "Enter to confirm …" → trust（仅数字）
/// - "ctrl+g to edit …" 或 "~/.claude/plans/…" 路径 → plan（仅数字）
/// - "… Tab to amend …"   → permission（仅数字）
PromptFamily? classifyFooter(String text) {
  final t = text.toLowerCase();
  if (RegExp(r'\benter to select\b').hasMatch(t)) return PromptFamily.select;
  if (RegExp(r'\benter to confirm\b').hasMatch(t)) return PromptFamily.trust;
  if (RegExp(r'ctrl\+g to edit\b').hasMatch(t) ||
      RegExp(r'\.claude/plans/').hasMatch(t)) {
    return PromptFamily.plan;
  }
  if (RegExp(r'\btab to amend\b').hasMatch(t)) return PromptFamily.permission;
  return null;
}

// ---------------------------------------------------------------------------
// prompt-select.ts 移植
// ---------------------------------------------------------------------------

/// 选项上方的回看窗口：把对话框主题（问题上面展示的 diff/命令）纳入签名，
/// 区分两个同形不同主题的对话框。误报「变了」只是一次无害刷新，漏报「没变」
/// 会把按键打进错误的界面——所以宁宽勿窄。
const signatureLookback = 40;

/// 区域签名：[from … footer] 行文本拼接。
String regionSignature(List<String> texts, int from, int footer) =>
    texts.sublist(from < 0 ? 0 : from, footer + 1).join('\n');

final _optionRow = RegExp(r'^(?:❯\s*)?(\d+)\.\s+(.+)$');

class _OptionRow {
  const _OptionRow(this.index, this.n, this.label);
  final int index;
  final int n;
  final String label;
}

/// 解析编号菜单行（"❯ 2. Label" / "2. Label"）。行首可有 ❯ 指针；
/// 数字后的句点是真选项与 diff 行号/评分列表的分水岭。
(int, String)? parseOptionRow(String text) {
  final m = _optionRow.firstMatch(text.trim());
  if (m == null) return null;
  return (int.parse(m.group(1)!), m.group(2)!.trim());
}

/// 菜单是收集到的行中**尾部连续 1,2,…,m 的后缀**：正文里散落的编号行
/// （计划里的步骤列表等）排在它上方，被排除。
List<T> trailingMenuRows<T>(List<T> rows, int Function(T) numberOf) {
  if (rows.isEmpty) return const [];
  var s = rows.length - 1;
  while (s > 0 && numberOf(rows[s - 1]) == numberOf(rows[s]) - 1) {
    s--;
  }
  return numberOf(rows[s]) == 1 ? rows.sublist(s) : const [];
}

/// 自由文本逃生行（"Type something." / "Tell Claude what to change"）用
/// 打字回答而不是按键，不提升为按钮。
bool isFreeTextLabel(String label) =>
    RegExp(r'^type something\b', caseSensitive: false).hasMatch(label) ||
    RegExp(r'^tell claude what to change\b', caseSensitive: false)
        .hasMatch(label);

/// 选项离 footer 的扫描窗口：限制扫描范围，滚动历史里散落的 "N." 不会被
/// 误当菜单行。
const optionScanWindow = 24;

/// footer 必须紧贴最后一个选项（之间最多隔着提示子行/空行）。
const maxFooterGap = 3;

/// 问题在第一个选项上方不远处；限制向上搜索范围。
const questionScanLimit = 12;

class PromptRegion {
  const PromptRegion({required this.model, required this.startLine});

  final PromptModel model;

  /// 第一个选项行的下标——菜单区域是 [startLine … 尾部]，渲染时被按钮替换；
  /// 之上（问题与前言）保持原文。
  final int startLine;
}

/// 在 `lines` 尾部检测单选对话框。命中返回模型 + 起始行，否则 null。
PromptRegion? detectPromptSelectRegion(List<StyledLine> lines) {
  final texts = lines.map(lineText).toList();

  // 1. footer = 最后一行非空行，必须能分类为菜单 footer（tail anchor）。
  var fi = texts.length - 1;
  while (fi >= 0 && isBlankLine(texts[fi])) {
    fi--;
  }
  if (fi < 0) return null;
  final family = classifyFooter(texts[fi]);
  if (family == null) return null;

  // 2. footer 上方的编号选项行；菜单是尾部连续 1,2,…,m 的后缀。
  final from = fi - optionScanWindow < 0 ? 0 : fi - optionScanWindow;
  final rows = <_OptionRow>[];
  for (var i = from; i < fi; i++) {
    final parsed = parseOptionRow(texts[i]);
    if (parsed != null) rows.add(_OptionRow(i, parsed.$1, parsed.$2));
  }
  if (rows.length < 2) return null;
  final menu = trailingMenuRows(rows, (r) => r.n);
  if (menu.length < 2) return null;
  // 超过 9 个选项的菜单需要两位数按键（"10"），herdr 的 send_keys 拒绝——
  // 与其渲染一个发不出按键的按钮，不如回退到原始镜像 + 按键条。
  if (menu.length > 9) return null;
  final firstOpt = menu.first.index;
  final lastOpt = menu.last.index;
  if (fi - lastOpt > maxFooterGap) return null;

  // 多问题 AskUserQuestion bail：步进头意味着后面还有看不到的问题，
  // 只答第一题就提交会得到半张表单。wizard 语法（未移植）本应接管；
  // 这里 bail 是它的安全网（落到原始镜像 + 按键条）。
  if (family == PromptFamily.select) {
    final top = firstOpt - questionScanLimit < 0 ? 0 : firstOpt - questionScanLimit;
    for (var i = top; i < fi; i++) {
      if (isMultiStepHeader(texts[i])) return null;
    }
  }

  // 3. 问题 = 第一个选项上方最近的含 "?" 的行；遇到横线就停，防止越出对话框。
  var question = '';
  for (var i = firstOpt - 1, seen = 0;
      i >= 0 && seen < questionScanLimit;
      i--, seen++) {
    final t = texts[i];
    if (isHorizontalRule(t)) break;
    if (t.contains('?')) {
      question = t.trim();
      break;
    }
  }
  if (question.isEmpty) return null;

  // 4. 构造选项：收集描述续行，丢弃自由文本行。keys 保留选项原始编号，
  //    即使自由文本行不占按钮位，按下的数字仍然选对行。
  final options = <PromptOption>[];
  for (var r = 0; r < menu.length; r++) {
    final row = menu[r];
    if (isFreeTextLabel(row.label)) continue;
    final nextIdx = r + 1 < menu.length ? menu[r + 1].index : fi;
    final desc = <String>[];
    for (var i = row.index + 1; i < nextIdx; i++) {
      final t = texts[i];
      if (isBlankLine(t) || isHorizontalRule(t) || parseOptionRow(t) != null) {
        continue;
      }
      desc.add(t.trim());
    }
    options.add(PromptOption(
      label: row.label,
      description: desc.isEmpty ? null : desc.join(' '),
      keys: family == PromptFamily.select
          ? ['${row.n}', 'Enter']
          : ['${row.n}'],
    ));
  }
  if (options.isEmpty) return null;

  final signature =
      regionSignature(texts, firstOpt - signatureLookback, fi);
  return PromptRegion(
    model: PromptModel(
      question: question,
      options: options,
      family: family,
      signature: signature,
    ),
    startLine: firstOpt,
  );
}

/// 尾部单选对话框检测，只返回模型（竞态防护的重新派生路径用）。
PromptModel? detectPromptSelect(List<StyledLine> lines) =>
    detectPromptSelectRegion(lines)?.model;
