// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => 'HerdrGo';

  @override
  String get allBridges => '全部';

  @override
  String get settingsTooltip => '设置';

  @override
  String get switchSessionTooltip => '切换 session';

  @override
  String get defaultSession => '默认';

  @override
  String sessionSummary(String name, int blocked, int working) {
    return '$name（$blocked 待处理 / $working 工作中）';
  }

  @override
  String connectionsInterrupted(int count) {
    return '$count 台连接中断';
  }

  @override
  String get easyTierConnecting => '正在连接 EasyTier 网络…';

  @override
  String easyTierFailed(String error) {
    return 'EasyTier 连接失败（$error）';
  }

  @override
  String virtualIpTimeout(int seconds) {
    return '等待虚拟 IP 超时（${seconds}s）';
  }

  @override
  String get networkUnreachable => '网络不可达';

  @override
  String get connectionTimeout => '连接超时';

  @override
  String get sendTimeout => '发送超时';

  @override
  String get responseTimeout => '响应超时';

  @override
  String get transferTimeout => '传输超时';

  @override
  String get badCertificate => 'TLS 证书校验失败';

  @override
  String get serverError => '服务器错误';

  @override
  String get requestCancelled => '请求已取消';

  @override
  String get networkError => '网络错误';

  @override
  String get invalidJsonResponse => '响应不是 JSON 对象';

  @override
  String connectionInterrupted(String error) {
    return '连接中断，展示的是上次数据（$error）';
  }

  @override
  String get herdrOffline => 'herdr 离线（bridge 连不上 herdr server）';

  @override
  String get readOnlyMode => '当前设备未授权写操作（只读模式）';

  @override
  String get bridgeConnecting => '正在连接 bridge…';

  @override
  String get noAgents => '没有检测到 agent\n在电脑上的 herdr 里启动一个，这里就会出现';

  @override
  String get sectionPinned => '已置顶';

  @override
  String get sectionNeedsAttention => '需要你处理';

  @override
  String get sectionWorking => '工作中';

  @override
  String get sectionOther => '其他';

  @override
  String get statusBlocked => '待处理';

  @override
  String get statusWorking => '工作中';

  @override
  String get statusDone => '已完成';

  @override
  String get statusIdle => '空闲';

  @override
  String get statusUnknown => '未知';

  @override
  String get relativeJustNow => '刚刚';

  @override
  String relativeMinutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String relativeHoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String relativeDaysAgo(int count) {
    return '$count 天前';
  }

  @override
  String get pendingDialogTitle => '屏幕上有待处理的对话框';

  @override
  String get pendingDialogBody => '直接发送的回车可能选中对话框高亮的选项。如果是想回答它的自由文本项，可以继续。';

  @override
  String get commonCancel => '取消';

  @override
  String get sendAnyway => '仍发送';

  @override
  String get unknownError => '未知错误';

  @override
  String get sent => '已发送';

  @override
  String get screenChangedRetry => '界面已变化，请查看最新输出后重试';

  @override
  String get screenChangedShort => '界面已变化，请重试';

  @override
  String get screenChangedOpenDetails => '界面已变化，请打开详情确认';

  @override
  String get textDeliveredWarning => '文本已输入但回车未生效——请勿直接重发，先查看输出';

  @override
  String sendFailed(String error) {
    return '发送失败：$error';
  }

  @override
  String keyFailed(String error) {
    return '按键失败：$error';
  }

  @override
  String get imageUploaded => '图片已上传，路径已填入回复框';

  @override
  String uploadFailed(String error) {
    return '上传失败：$error';
  }

  @override
  String get uploadFailedShort => '上传失败';

  @override
  String get sendFailedShort => '发送失败';

  @override
  String get aliasCleared => '已清除别名';

  @override
  String get renamed => '已重命名';

  @override
  String renameFailed(String error) {
    return '重命名失败：$error';
  }

  @override
  String get renameFailedShort => '重命名失败';

  @override
  String get refreshTooltip => '刷新';

  @override
  String get renameTooltip => '重命名';

  @override
  String get historyTooltip => '历史';

  @override
  String outputRefreshFailed(String error) {
    return '输出刷新失败，显示的是旧数据（$error）';
  }

  @override
  String get readingOutput => '正在读取输出…';

  @override
  String get sendImageTooltip => '发图片';

  @override
  String get replyHint => '回复 agent…';

  @override
  String get renameAgentTitle => '重命名 agent';

  @override
  String get renameAgentHelper => '留空则清除别名，恢复默认名';

  @override
  String get commonConfirm => '确定';

  @override
  String get continueEnter => '继续 (Enter)';

  @override
  String get bridgeNotConfigured => '未配置 bridge 连接';

  @override
  String get unpinned => '已取消置顶';

  @override
  String get pinned => '已置顶';

  @override
  String get unpinTooltip => '取消置顶';

  @override
  String get pinTooltip => '置顶';

  @override
  String get readOnlyCannotRename => '只读模式，无法重命名';

  @override
  String get openDetails => '打开详情';

  @override
  String readFailed(String error) {
    return '读取失败：$error';
  }

  @override
  String historyTitle(String title) {
    return '历史 · $title';
  }

  @override
  String get historyDisabled => 'bridge 关闭了历史功能（COLLIE_TRANSCRIPT）';

  @override
  String get historyNoSession => '这个 agent 没有会话日志';

  @override
  String get historyNoLog => '找不到该会话的日志文件';

  @override
  String historyUnavailable(String reason) {
    return '历史不可用：$reason';
  }

  @override
  String loadFailed(String error) {
    return '加载失败：$error';
  }

  @override
  String get historyTruncated => '日志过大，只解析了尾部';

  @override
  String get loading => '加载中…';

  @override
  String get loadOlder => '加载更早';

  @override
  String get roleYou => '你';

  @override
  String get roleAgent => 'agent';

  @override
  String get roleSummary => '摘要';

  @override
  String get roleSystem => '系统';

  @override
  String get connectionSettings => '连接设置';

  @override
  String get remoteBridge => '远端 bridge（扫码配对）';

  @override
  String get scanToAdd => '扫码添加';

  @override
  String get notPaired =>
      '尚未配对。bridge 启动时会打印配对二维码（herdrgo-bridge 日志里找），扫码后即可通过 EasyTier 虚拟网连接。';

  @override
  String get deviceAlias => '设备别名';

  @override
  String get displayNameHint => '展示名';

  @override
  String get commonDelete => '删除';

  @override
  String get deleteConfigTitle => '删除配置';

  @override
  String deleteConfigBody(String label, String ip) {
    return '删除「$label」（$ip）？';
  }

  @override
  String profileAdded(String label) {
    return '已添加：$label';
  }

  @override
  String get editAliasTooltip => '编辑别名';

  @override
  String get deleteTooltip => '删除';

  @override
  String get bridgeEnableHelp => '开关控制是否连接该 bridge；多条同时开启即为多宿主机模式。';

  @override
  String get language => '语言';

  @override
  String get terminalAutoResize => '终端输出适配手机宽度';

  @override
  String get terminalAutoResizeHelp =>
      '打开 agent 期间临时控制共享 Herdr 终端，离开后归还控制权；关闭此选项可始终保持电脑端的终端宽度。';

  @override
  String get systemLanguage => '跟随系统';

  @override
  String get simplifiedChinese => '简体中文';

  @override
  String get english => 'English';

  @override
  String get scanPairingTitle => '扫描配对二维码';

  @override
  String get scanPairingHelp => '对准 bridge 启动时打印的配对二维码。';

  @override
  String get toggleFlashTooltip => '开关手电筒';

  @override
  String get switchCameraTooltip => '切换摄像头';

  @override
  String blockedNotificationTitle(String name) {
    return '$name 需要你处理';
  }

  @override
  String get blockedNotificationChannel => 'agent 待处理';

  @override
  String get blockedNotificationChannelDescription => 'agent 停下来等你回复时提醒你';

  @override
  String get newAgent => '新建 agent';

  @override
  String get createAgentTitle => '创建 agent';

  @override
  String get targetComputer => '电脑';

  @override
  String get herdrSession => 'Herdr 会话';

  @override
  String get agentType => 'Agent 类型';

  @override
  String get agentName => 'Agent 名称';

  @override
  String get agentNameHint => '小写字母、数字、- 或 _';

  @override
  String get workspace => '工作区';

  @override
  String get newWorkspace => '新建工作区';

  @override
  String get workingDirectory => '工作目录';

  @override
  String get workingDirectoryHint => '/项目的/绝对路径';

  @override
  String get recentDirectories => '最近目录';

  @override
  String get initialTask => '初始任务（可选）';

  @override
  String get initialTaskHint => '希望 agent 先做什么？';

  @override
  String get createAgentAction => '创建';

  @override
  String get creatingAgent => '正在创建 agent…';

  @override
  String get noWritableComputer => '当前没有可用于创建 agent 的已连接电脑。';

  @override
  String get noAgentTypes => 'Herdr 没有返回可用的 agent 类型。';

  @override
  String loadCreateAgentOptionsFailed(String error) {
    return '无法加载 agent 选项：$error';
  }

  @override
  String get invalidAgentName => '请输入 1–32 位：以小写字母开头，只能包含小写字母、数字、- 或 _。';

  @override
  String get absolutePathRequired => '请输入绝对路径。';

  @override
  String get agentCreatePartialTitle => '终端已创建，但初始化未完成';

  @override
  String agentCreatePartialBody(String paneId, String error) {
    return '已创建 pane $paneId。请先打开检查 agent 的实际状态，再决定是否重试。\n\n$error';
  }

  @override
  String get openTerminal => '打开终端';
}
