import 'package:flutter/material.dart';

import '../../model/models.dart';

/// agent 重命名对话框：预填当前 paneLabel，留空 = 清除别名恢复默认名。
///
/// 返回 trim 后的输入；取消返回 `null`。调用方负责把结果交给
/// `BridgeApi.renamePane`（空白串在 bridge 端即清除，见 routes.rs rename_pane）。
Future<String?> showRenamePaneDialog(BuildContext context, PaneInfo pane) {
  final controller = TextEditingController(text: pane.paneLabel ?? '');
  final fallback = pane.sessionName ?? pane.agent;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名 agent'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 32,
        decoration: InputDecoration(
          hintText: fallback,
          helperText: '留空则清除别名，恢复默认名',
        ),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}
