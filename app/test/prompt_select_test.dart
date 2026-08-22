import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdrgo/ansi/ansi.dart';
import 'package:herdrgo/blocks/prompt_model.dart';
import 'package:herdrgo/blocks/prompt_select.dart';

// 黄金测试：夹具是 collie 仓库 web/src/fixtures/panes/*.txt 的原样拷贝
// （真实 ESC 字节的 pane 抓屏），与 collie 的 prompt-select.test.ts 一一对应。

String fixtureText(String name) =>
    File('test/fixtures/panes/$name').readAsStringSync();

List<StyledLine> fixtureLines(String name) =>
    splitLines(parseAnsi(fixtureText(name)));

void main() {
  group('五个 blocked 态夹具', () {
    test('folder-trust → trust family，仅数字键', () {
      final model = detectPromptSelect(fixtureLines('claude--trust-prompt.txt'));
      expect(model, isNotNull);
      expect(model!.family, PromptFamily.trust);
      expect(model.question, contains('Is this a project you created or one you trust?'));
      expect(model.options.map((o) => o.label).toList(),
          ['Yes, I trust this folder', 'No, exit']);
      expect(model.options.map((o) => o.keys).toList(), [
        ['1'],
        ['2'],
      ]);
    });

    test('AskUserQuestion select → select family，数字+Enter，自由文本行被丢弃', () {
      final model = detectPromptSelect(fixtureLines('claude--select-menu.txt'));
      expect(model, isNotNull);
      expect(model!.family, PromptFamily.select);
      expect(model.question, 'Which color theme should the dashboard use?');
      // "4. Type something." 是自由文本逃生行 → 不提升为按钮。
      expect(model.options.map((o) => o.label).toList(),
          ['Red', 'Green', 'Blue', 'Chat about this']);
      expect(model.options.map((o) => o.keys).toList(), [
        ['1', 'Enter'],
        ['2', 'Enter'],
        ['3', 'Enter'],
        ['5', 'Enter'], // "Chat about this" 保留原始编号 5，而非渲染位置
      ]);
      expect(model.options[0].description, contains('warm'));
      expect(model.options[3].description, isNull);
    });

    test('edit 审批 → permission family，仅数字键', () {
      final model =
          detectPromptSelect(fixtureLines('claude--permission-edit.txt'));
      expect(model, isNotNull);
      expect(model!.family, PromptFamily.permission);
      expect(model.question, 'Do you want to create hello.txt?');
      expect(model.options.map((o) => o.label).toList(), [
        'Yes',
        'Yes, allow all edits during this session (shift+tab)',
        'No',
      ]);
      expect(model.options.map((o) => o.keys).toList(), [
        ['1'],
        ['2'],
        ['3'],
      ]);
    });

    test('bash 审批 → permission family，仅数字键', () {
      final model =
          detectPromptSelect(fixtureLines('claude--permission-bash.txt'));
      expect(model, isNotNull);
      expect(model!.family, PromptFamily.permission);
      expect(model.question, 'Do you want to proceed?');
      expect(model.options, hasLength(3));
      expect(model.options[0].label, 'Yes');
      expect(model.options[1].label, contains('ask again'));
      expect(model.options[1].label, contains('mkfifo fixture-fifo'));
      expect(model.options[2].label, 'No');
      expect(model.options.map((o) => o.keys).toList(), [
        ['1'],
        ['2'],
        ['3'],
      ]);
    });

    test('plan 审批 → plan family，仅数字键，自由文本行被丢弃', () {
      final model =
          detectPromptSelect(fixtureLines('claude--plan-approval.txt'));
      expect(model, isNotNull);
      expect(model!.family, PromptFamily.plan);
      expect(model.question, contains('Would you like to proceed?'));
      expect(model.options.map((o) => o.label).toList(), [
        'Yes, and use auto mode',
        'Yes, manually approve edits',
        'No, refine with Ultraplan on Claude Code on the web',
      ]);
      expect(model.options.map((o) => o.keys).toList(), [
        ['1'],
        ['2'],
        ['3'],
      ]);
    });
  });

  group('正文带编号列表时仍提取真实菜单（后缀提取）', () {
    test('plan 审批 + 编号步骤正文', () {
      final model = detectPromptSelect(
          fixtureLines('claude--plan-approval--numbered-body.txt'));
      expect(model, isNotNull);
      expect(model!.family, PromptFamily.plan);
      expect(model.question, contains('ready to execute'));
      expect(model.options.map((o) => o.label).toList(), [
        'Yes, and use auto mode',
        'Yes, manually approve edits',
        'No, refine with Ultraplan on Claude Code on the web',
      ]);
    });
  });

  group('family → 按键配方（回归守护）', () {
    final cases = <String, (PromptFamily, bool)>{
      'claude--trust-prompt.txt': (PromptFamily.trust, false),
      'claude--select-menu.txt': (PromptFamily.select, true),
      'claude--permission-edit.txt': (PromptFamily.permission, false),
      'claude--plan-approval.txt': (PromptFamily.plan, false),
    };
    for (final entry in cases.entries) {
      test('${entry.key} → ${entry.value.$2 ? '数字+Enter' : '仅数字'}', () {
        final model = detectPromptSelect(fixtureLines(entry.key));
        expect(model, isNotNull);
        expect(model!.family, entry.value.$1);
        for (final o in model.options) {
          expect(RegExp(r'^\d+$').hasMatch(o.keys[0]), isTrue,
              reason: '第一个键总是数字');
          if (entry.value.$2) {
            expect(o.keys, hasLength(2));
            expect(o.keys[1], 'Enter');
          } else {
            expect(o.keys, hasLength(1));
            expect(o.keys, isNot(contains('Enter')));
          }
        }
      });
    }
  });

  group('误报闸门（尾部没有菜单）', () {
    for (final name in [
      'claude--working.txt',
      'claude--fresh-idle.txt',
      'claude--done.txt',
    ]) {
      test('$name 零检出', () {
        expect(detectPromptSelect(fixtureLines(name)), isNull);
      });
    }

    test('多问题 AskUserQuestion（步进头）bail', () {
      expect(detectPromptSelect(fixtureLines('claude--select-multi.txt')),
          isNull);
    });

    test('单问题 multiSelect（复选框）不被 prompt-select 认领', () {
      expect(
          detectPromptSelect(
              fixtureLines('claude--select-multiselect-single.txt')),
          isNull);
    });

    test('超过 9 行的菜单 bail（"10" 是发不出的按键）', () {
      final rows =
          List.generate(10, (i) => '  ${i + 1}. Option ${i + 1}').join('\n');
      final buf = 'Which option should we use?\n\n$rows\n\nEnter to select · Esc to cancel';
      expect(detectPromptSelect(splitLines(parseAnsi(buf))), isNull);
      // 对照：9 行仍可检出（证明是守护而非形状在拒绝）。
      final nine =
          List.generate(9, (i) => '  ${i + 1}. Option ${i + 1}').join('\n');
      final nineBuf =
          'Which option should we use?\n\n$nine\n\nEnter to select · Esc to cancel';
      final model = detectPromptSelect(splitLines(parseAnsi(nineBuf)));
      expect(model, isNotNull);
      expect(model!.options, hasLength(9));
    });

    test('不在尾部的菜单形状不匹配', () {
      final withTail =
          '${fixtureText('claude--select-menu.txt')}\n● Wrote the file\n  ⎿  done\n';
      expect(detectPromptSelect(splitLines(parseAnsi(withTail))), isNull);
    });

    test('空缓冲区与纯空白缓冲区不匹配', () {
      expect(detectPromptSelect(splitLines(parseAnsi(''))), isNull);
      expect(detectPromptSelect(splitLines(parseAnsi('\n\n   \n'))), isNull);
    });
  });

  group('detectPromptSelectRegion 渲染边界', () {
    test('菜单区域从第一个选项行开始（问题与前言留在上方原文）', () {
      final lines = fixtureLines('claude--select-menu.txt');
      final region = detectPromptSelectRegion(lines);
      expect(region, isNotNull);
      expect(lineText(lines[region!.startLine]).trim(),
          matches(RegExp(r'^❯?\s*1\.\s+Red$')));
      expect(lineText(lines[region.startLine - 1]).trim(), '');
      expect(promptsEqual(region.model, detectPromptSelect(lines)!), isTrue);
    });
  });

  group('promptsEqual', () {
    test('同一夹具两次派生相等；改一个选项标签后不等', () {
      final a = detectPromptSelect(fixtureLines('claude--select-menu.txt'))!;
      final b = detectPromptSelect(fixtureLines('claude--select-menu.txt'))!;
      expect(promptsEqual(a, b), isTrue);

      final tampered = PromptModel(
        question: a.question,
        family: a.family,
        signature: a.signature,
        options: [
          const PromptOption(label: 'Blue', keys: ['1', 'Enter']),
          ...a.options.skip(1),
        ],
      );
      expect(promptsEqual(a, tampered), isFalse);
    });

    test('signature 不同则不等（同形不同主题）', () {
      final a = detectPromptSelect(fixtureLines('claude--select-menu.txt'))!;
      final b = PromptModel(
        question: a.question,
        family: a.family,
        signature: '${a.signature}\nextra',
        options: a.options,
      );
      expect(promptsEqual(a, b), isFalse);
    });
  });
}
