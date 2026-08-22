/// agent 状态的颜色与文案：dashboard 卡片 / 详情页 chip / 预览卡共用。
///
/// 从 dashboard_screen.dart 抽出——预览卡/详情页不再反向 import dashboard，
/// 避免单 pane 页面依赖聚合页。
library;

import 'package:flutter/material.dart';

import '../model/models.dart';

Color statusColor(ColorScheme scheme, AgentStatus status) => switch (status) {
  AgentStatus.blocked => Colors.amber,
  AgentStatus.working => Colors.lightBlue,
  AgentStatus.done => Colors.green,
  AgentStatus.idle => scheme.outline,
  AgentStatus.unknown => scheme.outline,
};

String statusLabel(AgentStatus status) => switch (status) {
  AgentStatus.blocked => '待处理',
  AgentStatus.working => '工作中',
  AgentStatus.done => '已完成',
  AgentStatus.idle => '空闲',
  AgentStatus.unknown => '未知',
};
