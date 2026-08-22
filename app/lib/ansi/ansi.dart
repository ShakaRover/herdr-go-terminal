/// ANSI SGR 解析器 —— 从 collie `web/src/lib/ansi.ts` 逐行移植。
///
/// herdr 的 `pane.read(format:"ansi")` 只发 SGR 颜色/样式序列（collie 已对真实
/// pane 验证：无光标移动、无 OSC 泄漏），所以不需要终端模拟器，只解析 SGR；
/// 其他转义序列防御性跳过。
///
/// 与 UI 解耦：颜色用自有值类型 [AnsiColor]，Flutter 渲染层再映射到 Color。
library;

/// 24 位颜色值。
class AnsiColor {
  const AnsiColor(this.r, this.g, this.b);

  final int r;
  final int g;
  final int b;

  @override
  bool operator ==(Object other) =>
      other is AnsiColor && r == other.r && g == other.g && b == other.b;

  @override
  int get hashCode => Object.hash(r, g, b);

  @override
  String toString() => 'rgb($r,$g,$b)';
}

class AnsiSegment {
  const AnsiSegment({
    required this.text,
    this.fg,
    this.bg,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.muted = false,
  });

  final String text;
  final AnsiColor? fg;
  final AnsiColor? bg;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool strike;

  /// 整段只有制表/横线字形（TUI 边框或分隔线），渲染时做弱化处理。
  final bool muted;
}

/// 镜像的底色/字色（inverse video 未指明颜色时互换它们）。对齐 collie 的
/// MIRROR_BG / MIRROR_FG。
const mirrorBg = AnsiColor(0x0a, 0x0a, 0x0a);
const mirrorFg = AnsiColor(0xfa, 0xfa, 0xfa);

/// 16 个索引色槽（取自 collie index.css 的 --ansi-N，即 VS Code 深色主题）。
const ansiPalette = [
  AnsiColor(0x00, 0x00, 0x00), // 0
  AnsiColor(0xcd, 0x31, 0x31), // 1
  AnsiColor(0x0d, 0xbc, 0x79), // 2
  AnsiColor(0xe5, 0xe5, 0x10), // 3
  AnsiColor(0x24, 0x72, 0xc8), // 4
  AnsiColor(0xbc, 0x3f, 0xbc), // 5
  AnsiColor(0x11, 0xa8, 0xcd), // 6
  AnsiColor(0xe5, 0xe5, 0xe5), // 7
  AnsiColor(0x66, 0x66, 0x66), // 8
  AnsiColor(0xf1, 0x4c, 0x4c), // 9
  AnsiColor(0x23, 0xd1, 0x8b), // 10
  AnsiColor(0xf5, 0xf5, 0x43), // 11
  AnsiColor(0x3b, 0x8e, 0xea), // 12
  AnsiColor(0xd6, 0x70, 0xd6), // 13
  AnsiColor(0x29, 0xb8, 0xdb), // 14
  AnsiColor(0xff, 0xff, 0xff), // 15
];

AnsiColor _color256(int n) {
  if (n < 16) return ansiPalette[n];
  if (n >= 232) {
    final v = 8 + (n - 232) * 10;
    return AnsiColor(v, v, v);
  }
  final i = n - 16;
  final r = i ~/ 36;
  final g = (i % 36) ~/ 6;
  final b = i % 6;
  int c(int x) => x == 0 ? 0 : 55 + x * 40;
  return AnsiColor(c(r), c(g), c(b));
}

class _State {
  AnsiColor? fg;
  AnsiColor? bg;
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;
  bool strike = false;
  bool inverse = false;

  void reset() {
    fg = bg = null;
    bold = dim = italic = underline = strike = inverse = false;
  }
}

void _applySgr(_State state, List<int> codes) {
  for (var i = 0; i < codes.length; i++) {
    final c = codes[i];
    if (c == 0) {
      state.reset();
    } else if (c == 1) {
      state.bold = true;
    } else if (c == 2) {
      state.dim = true;
    } else if (c == 3) {
      state.italic = true;
    } else if (c == 4) {
      state.underline = true;
    } else if (c == 7) {
      state.inverse = true;
    } else if (c == 9) {
      state.strike = true;
    } else if (c == 22) {
      state.bold = state.dim = false;
    } else if (c == 23) {
      state.italic = false;
    } else if (c == 24) {
      state.underline = false;
    } else if (c == 27) {
      state.inverse = false;
    } else if (c == 29) {
      state.strike = false;
    } else if (c >= 30 && c <= 37) {
      state.fg = ansiPalette[c - 30];
    } else if (c == 39) {
      state.fg = null;
    } else if (c >= 40 && c <= 47) {
      state.bg = ansiPalette[c - 40];
    } else if (c == 49) {
      state.bg = null;
    } else if (c >= 90 && c <= 97) {
      state.fg = ansiPalette[8 + c - 90];
    } else if (c >= 100 && c <= 107) {
      state.bg = ansiPalette[8 + c - 100];
    } else if (c == 38 || c == 48) {
      final isFg = c == 38;
      final mode = i + 1 < codes.length ? codes[i + 1] : null;
      if (mode == 5) {
        final col = _color256(i + 2 < codes.length ? codes[i + 2] : 0);
        if (isFg) {
          state.fg = col;
        } else {
          state.bg = col;
        }
        i += 2;
      } else if (mode == 2) {
        final col = AnsiColor(
          i + 2 < codes.length ? codes[i + 2] : 0,
          i + 3 < codes.length ? codes[i + 3] : 0,
          i + 4 < codes.length ? codes[i + 4] : 0,
        );
        if (isFg) {
          state.fg = col;
        } else {
          state.bg = col;
        }
        i += 4;
      }
    }
  }
}

/// 制表符（U+2500–U+257F）与各类破折号（U+2012–U+2015）。
/// 注意这里**不含**方块条（U+2581–U+2584）：对齐 collie ansi.ts 的 muted
/// 判定（BOX_DRAWING + UNICODE_DASH 两类）；prompt_select 的 isHorizontalRule
/// 才使用含方块条的更宽集合，两处规则在原文里本就不同（最终审查 m1）。
bool _isRuleGlyph(int codeUnit) =>
    (codeUnit >= 0x2500 && codeUnit <= 0x257F) ||
    (codeUnit >= 0x2012 && codeUnit <= 0x2015);

/// 一段文字去掉空白后是否全是横线/制表字形（长度 ≥2 才算，避免误伤内容）。
bool checkMuted(String text) {
  final compact = text.replaceAll(RegExp(r'\s+'), '');
  if (compact.length < 2) return false;
  for (final rune in compact.runes) {
    if (!_isRuleGlyph(rune)) return false;
  }
  return true;
}

/// 解析 ANSI-SGR 文本为带样式的段序列。
///
/// CR 语义：**行内后发覆盖**——遇到 `\r` 时丢弃当前行已积累的段，回到第 0 列；
/// SGR 状态保留（真实终端也保留）。这会把进度条/旋转指示器的重绘折叠成最后一帧。
/// `\r\n` 或输入末尾的孤立 `\r` 只是行终止符，不覆盖。
List<AnsiSegment> parseAnsi(String input) {
  final segs = <AnsiSegment>[];
  final state = _State();
  var buf = StringBuffer();
  // 当前可视行在 segs 中的起始下标，供 \r 回滚。
  var lineSegStart = 0;

  void flush() {
    if (buf.isEmpty) return;
    final text = buf.toString();
    final fg = state.inverse ? (state.bg ?? mirrorBg) : state.fg;
    final bg = state.inverse ? (state.fg ?? mirrorFg) : state.bg;
    segs.add(AnsiSegment(
      text: text,
      fg: fg,
      bg: bg,
      bold: state.bold,
      dim: state.dim,
      italic: state.italic,
      underline: state.underline,
      strike: state.strike,
      muted: checkMuted(text),
    ));
    buf = StringBuffer();
  }

  for (var i = 0; i < input.length; i++) {
    final ch = input[i];

    if (ch == '\r') {
      final next = i + 1 < input.length ? input[i + 1] : null;
      if (next == null || next == '\n') continue;
      flush();
      segs.removeRange(lineSegStart, segs.length);
      buf = StringBuffer();
      continue;
    }

    if (ch == '\n') {
      buf.write('\n');
      flush();
      lineSegStart = segs.length;
      continue;
    }

    if (ch == '\x1b') {
      final next = i + 1 < input.length ? input[i + 1] : null;
      if (next == '[') {
        // CSI：ESC [ [private]* [params]* [intermediates]* <final>
        var j = i + 2;
        var hasPrivate = false;
        while (j < input.length && '<=>?'.contains(input[j])) {
          hasPrivate = true;
          j++;
        }
        while (j < input.length && RegExp(r'[0-9;:]').hasMatch(input[j])) {
          j++;
        }
        while (j < input.length &&
            input.codeUnitAt(j) >= 0x20 &&
            input.codeUnitAt(j) <= 0x2f) {
          j++;
        }
        final finalByte = j < input.length ? input[j] : null;
        if (finalByte == 'm' && !hasPrivate) {
          flush();
          final raw = input.substring(i + 2, j);
          final codes = raw
              .split(RegExp(r'[;:]'))
              .where((s) => s.isNotEmpty)
              .map((p) => int.tryParse(p) ?? 0)
              .toList();
          // 空参数（ESC[m）视为全量重置。
          _applySgr(state, codes.isEmpty ? [0] : codes);
        }
        i = j; // for 循环的 ++ 会越过 final 字节
        continue;
      }
      if (next == ']') {
        // OSC：ESC ] ...（BEL 或 ST 终止）——整体跳过
        var j = i + 2;
        while (j < input.length &&
            input[j] != '\x07' &&
            !(input[j] == '\x1b' &&
                j + 1 < input.length &&
                input[j + 1] == '\\')) {
          j++;
        }
        if (j < input.length && input[j] == '\x1b') j++;
        i = j;
        continue;
      }
      i += 1; // 未知 ESC + 单字符——跳过
      continue;
    }

    buf.write(ch);
  }
  flush();
  return segs;
}

// ---------------------------------------------------------------------------
// 行切分（移植自 collie blocks.ts 的通用部分）
// ---------------------------------------------------------------------------

/// 一个可视行：组成它的样式段（行尾的 "\n" 已剥离）。
class StyledLine {
  const StyledLine(this.segments, {this.noWrap = false});

  final List<AnsiSegment> segments;

  /// 终端全宽边框行：镜像换行时保持在一行（不随窄屏折行）。
  final bool noWrap;
}

/// 只有同一横向线形字形重复 ≥20 次（除终端 padding 空格外无其他字符）的行
/// 才视为全宽边框。阈值、字形表、"同一字符"的回引用语义都对齐 collie
/// blocks.ts 的 PURE_HORIZONTAL_BORDER。
StyledLine _styledLine(List<AnsiSegment> segments) {
  final text = segments.map((s) => s.text).join();
  final trimmed = text.trim();
  final runes = trimmed.runes.toList();
  final isBorder = runes.length >= 20 &&
      runes.every((r) => r == runes.first) &&
      _isPureHorizontalGlyph(runes.first);
  return isBorder ? StyledLine(segments, noWrap: true) : StyledLine(segments);
}

bool _isPureHorizontalGlyph(int rune) =>
    (rune >= 0x2500 && rune <= 0x257F && _isHorizontalBoxGlyph(rune)) ||
    (rune >= 0x2581 && rune <= 0x2584) ||
    (rune >= 0x2012 && rune <= 0x2015);

// 横向制表符：实线、虚线、双横线（不含角/交点/竖线）。
bool _isHorizontalBoxGlyph(int rune) =>
    rune == 0x2500 || // ─
    rune == 0x2501 || // ━
    (rune >= 0x2504 && rune <= 0x2509) || // ┄┅┈┉╌╍
    rune == 0x2550 || // ═
    (rune >= 0x2574 && rune <= 0x257A); // ╴╶╸╺╼╾

/// 在 "\n" 边界把段序列切成可视行。换行符成为行之间的分隔（丢弃），
/// `lines.map(lineText).join("\n")` 可逐字还原原文。
List<StyledLine> splitLines(List<AnsiSegment> segments) {
  final lines = <StyledLine>[];
  var current = <AnsiSegment>[];

  for (final seg in segments) {
    final t = seg.text;
    if (!t.contains('\n')) {
      current.add(seg);
      continue;
    }
    var start = 0;
    while (true) {
      final idx = t.indexOf('\n', start);
      final end = idx == -1 ? t.length : idx;
      if (end > start) {
        current.add(AnsiSegment(
          text: t.substring(start, end),
          fg: seg.fg,
          bg: seg.bg,
          bold: seg.bold,
          dim: seg.dim,
          italic: seg.italic,
          underline: seg.underline,
          strike: seg.strike,
          muted: seg.muted,
        ));
      }
      if (idx == -1) break;
      lines.add(_styledLine(current));
      current = <AnsiSegment>[];
      start = idx + 1;
    }
  }

  lines.add(_styledLine(current));
  return lines;
}

/// 一行的可见文本（段的 text 拼接）。
String lineText(StyledLine line) => line.segments.map((s) => s.text).join();

bool isBlankLine(String text) => text.trim().isEmpty;

/// 去掉尾部连续空行（让原始块贴着下方的按钮区）。
List<StyledLine> trimTrailingBlank(List<StyledLine> lines) {
  var end = lines.length;
  while (end > 0 && isBlankLine(lineText(lines[end - 1]))) {
    end--;
  }
  return end == lines.length ? lines : lines.sublist(0, end);
}
