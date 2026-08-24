/// agent 状态的颜色与文案：dashboard 卡片 / 详情页 chip / 预览卡共用。
///
/// 从 dashboard_screen.dart 抽出——预览卡/详情页不再反向 import dashboard，
/// 避免单 pane 页面依赖聚合页。
library;

import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../model/models.dart';

Color statusColor(ColorScheme scheme, AgentStatus status) => switch (status) {
  AgentStatus.blocked => Colors.amber,
  AgentStatus.working => Colors.lightBlue,
  AgentStatus.done => Colors.green,
  AgentStatus.idle => scheme.outline,
  AgentStatus.unknown => scheme.outline,
};

String statusLabel(AppLocalizations l10n, AgentStatus status) =>
    switch (status) {
      AgentStatus.blocked => l10n.statusBlocked,
      AgentStatus.working => l10n.statusWorking,
      AgentStatus.done => l10n.statusDone,
      AgentStatus.idle => l10n.statusIdle,
      AgentStatus.unknown => l10n.statusUnknown,
    };
