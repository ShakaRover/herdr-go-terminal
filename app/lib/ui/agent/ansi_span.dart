/// ANSI 模型 → Flutter TextSpan 的映射。渲染只发生在这里。
library;

import 'package:flutter/painting.dart';

import '../../ansi/ansi.dart';

Color toColor(AnsiColor c) => Color.fromARGB(255, c.r, c.g, c.b);

const _mirrorBgColor = Color.fromARGB(255, 0x0a, 0x0a, 0x0a);
const _mirrorFgColor = Color.fromARGB(255, 0xfa, 0xfa, 0xfa);

TextStyle segmentStyle(AnsiSegment seg, {double fontSize = 12.5}) {
  final fg = seg.fg != null ? toColor(seg.fg!) : _mirrorFgColor;
  // muted（边框/分隔线）弱化；dim 降不透明度（对齐 collie 的 opacity: 0.6）。
  final alpha = (seg.muted ? 0.45 : 1.0) * (seg.dim ? 0.6 : 1.0);
  return TextStyle(
    color: fg.withValues(alpha: alpha),
    backgroundColor: seg.bg != null ? toColor(seg.bg!) : null,
    fontWeight: seg.bold ? FontWeight.w600 : null,
    fontStyle: seg.italic ? FontStyle.italic : null,
    decoration: switch ((seg.underline, seg.strike)) {
      (true, true) => TextDecoration.combine(
          [TextDecoration.underline, TextDecoration.lineThrough]),
      (true, false) => TextDecoration.underline,
      (false, true) => TextDecoration.lineThrough,
      _ => null,
    },
    fontFamily: 'monospace',
    fontSize: fontSize,
    height: 1.25,
  );
}

/// 把整个镜像文本（多行）合成一个 TextSpan 树，保持可选择复制。
InlineSpan linesToSpan(List<StyledLine> lines, {double fontSize = 12.5}) {
  final children = <InlineSpan>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    for (final seg in line.segments) {
      children.add(TextSpan(
        text: seg.text,
        style: segmentStyle(seg, fontSize: fontSize),
      ));
    }
    if (i < lines.length - 1) {
      children.add(TextSpan(
          text: '\n', style: TextStyle(fontSize: fontSize, height: 1.25)));
    }
  }
  return TextSpan(children: children);
}

/// 镜像底色（Scaffold/容器背景用）。
Color get mirrorBackground => _mirrorBgColor;
