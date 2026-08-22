import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_web/ansi/ansi.dart';

void main() {
  group('parseAnsi 基础', () {
    test('纯文本返回单个无样式段', () {
      final segs = parseAnsi('hello world');
      expect(segs, hasLength(1));
      expect(segs.single.text, 'hello world');
      expect(segs.single.fg, isNull);
      expect(segs.single.bold, isFalse);
    });

    test('空输入返回空列表', () {
      expect(parseAnsi(''), isEmpty);
    });

    test('SGR 被剥离，周围字符保留', () {
      final segs = parseAnsi('a\x1b[31mb\x1b[0mc');
      expect(segs.map((s) => s.text).join(), 'abc');
    });

    test('基础前景色 31 = 索引红（palette[1]）', () {
      final segs = parseAnsi('\x1b[31mred');
      expect(segs.single.fg, ansiPalette[1]);
    });

    test('背景色 42 = 索引绿底（palette[2]）', () {
      final segs = parseAnsi('\x1b[42mx');
      expect(segs.single.bg, ansiPalette[2]);
    });

    test('亮色系 91 = palette[9]', () {
      expect(parseAnsi('\x1b[91mx').single.fg, ansiPalette[9]);
    });

    test('粗体设置与 0 重置', () {
      final segs = parseAnsi('\x1b[1mbold\x1b[0mplain');
      expect(segs[0].bold, isTrue);
      expect(segs[1].bold, isFalse);
      expect(segs[1].fg, isNull);
    });

    test('斜体/下划线/删除线', () {
      final segs = parseAnsi('\x1b[3;4;9mx');
      expect(segs.single.italic, isTrue);
      expect(segs.single.underline, isTrue);
      expect(segs.single.strike, isTrue);
    });

    test('22/23/24/27/29 单独关闭对应样式', () {
      final segs = parseAnsi('\x1b[1;3;4;7;9mA\x1b[22mB\x1b[23mC\x1b[24mD\x1b[27mE\x1b[29mF');
      final byText = {for (final s in segs) s.text: s};
      expect(byText['B']!.bold, isFalse);
      expect(byText['C']!.italic, isFalse);
      expect(byText['D']!.underline, isFalse);
      // E 段 inverse 关闭 → 不再换色，fg/bg 还原为 null。
      expect(byText['E']!.fg, isNull);
      expect(byText['F']!.strike, isFalse);
    });
  });

  group('parseAnsi 扩展色', () {
    test('256 色立方体 38;5;46 = rgb(0,255,0)', () {
      expect(parseAnsi('\x1b[38;5;46mx').single.fg, const AnsiColor(0, 255, 0));
    });

    test('256 灰度 38;5;232 = rgb(8,8,8)', () {
      expect(parseAnsi('\x1b[38;5;232mx').single.fg, const AnsiColor(8, 8, 8));
    });

    test('24 位真彩 38;2;r;g;b', () {
      expect(parseAnsi('\x1b[38;2;10;20;30mx').single.fg,
          const AnsiColor(10, 20, 30));
    });

    test('索引色两种写法等价（31 ≡ 38;5;1）', () {
      expect(parseAnsi('\x1b[38;5;1mx').single.fg, ansiPalette[1]);
    });

    test('冒号形式 38:2:r:g:b 与分号形式一致', () {
      expect(parseAnsi('\x1b[38:2:10:20:30mx').single.fg,
          const AnsiColor(10, 20, 30));
    });

    test('冒号形式 38:5:n 与分号形式一致', () {
      expect(parseAnsi('\x1b[38:5:46mx').single.fg, const AnsiColor(0, 255, 0));
    });

    test('ISO 空 colorspace 形式 38:2::r:g:b', () {
      expect(parseAnsi('\x1b[38:2::10:20:30mx').single.fg,
          const AnsiColor(10, 20, 30));
    });

    test('冒号形式背景真彩 48:2:r:g:b', () {
      expect(parseAnsi('\x1b[48:2:1:2:3mx').single.bg, const AnsiColor(1, 2, 3));
    });
  });

  group('parseAnsi inverse video', () {
    test('7m 交换 fg/bg，未指定时用镜像底色/字色', () {
      final segs = parseAnsi('\x1b[7mx');
      expect(segs.single.fg, mirrorBg);
      expect(segs.single.bg, mirrorFg);
    });

    test('有显式颜色时互换', () {
      final segs = parseAnsi('\x1b[31;42m\x1b[7mx');
      expect(segs.single.fg, ansiPalette[2]); // 原 bg 绿 → fg
      expect(segs.single.bg, ansiPalette[1]); // 原 fg 红 → bg
    });
  });

  group('parseAnsi 非 SGR 序列', () {
    test('OSC（BEL 终止）不泄漏进文本', () {
      final segs = parseAnsi('a\x1b]0;window title\x07b');
      expect(segs.map((s) => s.text).join(), 'ab');
    });

    test('OSC（ST 终止）不泄漏进文本', () {
      final segs = parseAnsi('a\x1b]0;title\x1b\\b');
      expect(segs.map((s) => s.text).join(), 'ab');
    });

    test('光标移动/清屏等 CSI 不产生文本', () {
      final segs = parseAnsi('a\x1b[2J\x1b[1;1Hb');
      expect(segs.map((s) => s.text).join(), 'ab');
    });

    test('私有标记序列（>0c / =1h / <5m）不当 SGR 处理', () {
      expect(parseAnsi('\x1b[>0c').map((s) => s.text).join(), '');
      expect(parseAnsi('\x1b[=1h').map((s) => s.text).join(), '');
      expect(parseAnsi('\x1b[<5mx').map((s) => s.text).join(), 'x');
      expect(parseAnsi('\x1b[<5mx').single.fg, isNull);
    });

    test('ESC[m 空参数视为全量重置', () {
      final segs = parseAnsi('\x1b[31mR\x1b[mP');
      expect(segs[0].fg, ansiPalette[1]);
      expect(segs[1].fg, isNull);
    });
  });

  group('parseAnsi CR 语义', () {
    test('spinner：每帧 \\r 回滚到行首，只留最后一帧', () {
      final segs = parseAnsi('-\r\\\r|\r/');
      expect(segs.map((s) => s.text).join(), '/');
    });

    test('进度条：最后一个 \\r 之后的内容是可见结果', () {
      final segs = parseAnsi('10%\r50%\r100%');
      expect(segs.map((s) => s.text).join(), '100%');
    });

    test('多行文本中 \\r 只影响当前行', () {
      final segs = parseAnsi('first\nsecond\rSECOND');
      expect(segs.map((s) => s.text).join(), 'first\nSECOND');
    });

    test('SGR 状态跨过 \\r 保留', () {
      final segs = parseAnsi('\x1b[31mabc\rX');
      expect(segs.map((s) => s.text).join(), 'X');
      expect(segs.single.fg, ansiPalette[1]);
    });

    test('CRLF：\\r 紧邻 \\n 是行终止符，不覆盖', () {
      final segs = parseAnsi('hello\r\nworld');
      expect(segs.map((s) => s.text).join(), 'hello\nworld');
    });

    test('输入末尾的孤立 \\r 不覆盖', () {
      final segs = parseAnsi('hello\r');
      expect(segs.map((s) => s.text).join(), 'hello');
    });
  });

  group('muted（横线/制表符段）', () {
    test('纯横线段是 muted', () {
      expect(parseAnsi('──────').single.muted, isTrue);
    });

    test('普通文本不是 muted', () {
      expect(parseAnsi('hello').single.muted, isFalse);
    });

    test('单个横线字符（<2）不是 muted', () {
      expect(parseAnsi('─').single.muted, isFalse);
    });
  });

  group('splitLines', () {
    test('按 \\n 切行，拼接可还原', () {
      final lines = splitLines(parseAnsi('a\nb\nc'));
      expect(lines.map(lineText).toList(), ['a', 'b', 'c']);
    });

    test('跨行样式段被切开且两侧保留样式', () {
      final lines = splitLines(parseAnsi('\x1b[31ma\nb'));
      expect(lines, hasLength(2));
      expect(lines[0].segments.single.fg, ansiPalette[1]);
      expect(lines[1].segments.single.fg, ansiPalette[1]);
    });

    test('结尾换行产生收尾空行', () {
      final lines = splitLines(parseAnsi('a\n'));
      expect(lines.map(lineText).toList(), ['a', '']);
    });

    test('同一横向字形 ≥20 重复 → noWrap', () {
      final border = '─' * 40;
      final lines = splitLines(parseAnsi('x\n$border'));
      expect(lines[1].noWrap, isTrue);
      expect(lines[0].noWrap, isFalse);
    });

    test('混合线形字符不算 noWrap（与 collie 的回引用语义一致）', () {
      final mixed = '${'─' * 19}━';
      final lines = splitLines(parseAnsi(mixed));
      expect(lines[0].noWrap, isFalse);
    });

    test('短横线行（<20）不算 noWrap', () {
      final lines = splitLines(parseAnsi('─' * 10));
      expect(lines[0].noWrap, isFalse);
    });
  });

  group('trimTrailingBlank', () {
    test('去掉尾部空行，保留中间空行', () {
      final lines = splitLines(parseAnsi('a\n\nb\n\n\n'));
      final trimmed = trimTrailingBlank(lines);
      expect(trimmed.map(lineText).toList(), ['a', '', 'b']);
    });
  });
}
