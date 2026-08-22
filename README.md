# herdr-web

[herdr](https://herdr.dev) agent 的 Flutter 原生手机客户端（Android）。

通过本仓库自带的 Rust bridge（`bridge/` 目录）访问 herdr：
bridge 连 herdr socket，对外提供 REST API（snapshot / pane 读写 / 历史 /
上传），app 只做客户端，不直接连 herdr socket。

设计文档：[`docs/superpowers/specs/2026-08-13-herdr-flutter-client-design.md`](docs/superpowers/specs/2026-08-13-herdr-flutter-client-design.md)

## 功能

- **Dashboard triage**：blocked 置顶（「需要你处理」），working 其次，其余沉底；
  下拉刷新、断线/只读横幅、多 herdr session 切换。
- **agent 对话**：ANSI 彩色输出镜像（自动跟随底部）、回复框、特殊按键条
  （Esc / Ctrl+C / 方向键 / Tab / Shift+Tab / Enter）。
- **对话框按钮**：识别 Claude 式单选审批/提问菜单（prompt-select）为原生按钮；
  点击时经「新鲜读取 → 重新识别 → 结构相等 → expectedPrompt 绑定」防护链后才发键。
- **历史**：从 agent 自己的会话日志分页读完整对话（终端滚屏之外的部分）。
- **图片**：相册选图上传到宿主机，返回路径自动填入回复框。
- **通知**：WorkManager 后台周期轮询（≥15min），新增 blocked 发本地通知，
  点击直达对应 agent；app 前台使用时自动静默。

## 构建

工具链固定在仓库的 `.toolchain/`（Flutter 3.47.0 + Android SDK 36，
NDK 26 通过符号链接复用 `/opt/android-sdk`）：

```bash
source .toolchain/env.sh
cd app
flutter pub get
flutter test                 # 单测（含 pane 夹具黄金测试）
flutter build apk --release  # 产物：app/build/app/outputs/flutter-apk/app-release.apk
```

debug 构建把 `app-debug.apk` 直接 `adb install` 到模拟器/手机即可。

### EasyTier JNI 同步

app 内嵌 EasyTier（无 TUN，经本地 127.0.0.1 端口转发访问虚拟网络内的
bridge）。原生产物（`libeasytier_android_jni.so` + Kotlin 绑定）由
`app/tool/sync_easytier.sh` 从 EasyTier 仓库构建并拷入
`app/android/app/src/main/`（jniLibs 与 `kotlin/com/easytier/jni/`）：

```bash
app/tool/sync_easytier.sh   # 幂等；EASYTIER_REPO 可覆盖 EasyTier 仓库路径
```

`EasyTierManager.kt`/`EasyTierVpnService.t.kt` 依赖 VpnService 与 moshi，
不同步。Dart 侧封装见 `app/lib/api/easytier_channel.dart`。

## 配置

bridge 部署在 herdr 宿主机上：

```bash
cd bridge
cargo build --release
# 产物：bridge/target/release/herdr-bridge，默认监听 127.0.0.1:8787
```

常驻运行可用 `bridge/systemd/` 下的 systemd 单元。对外暴露有两种方式：

1. **EasyTier 远程访问（推荐）**：bridge 内嵌 EasyTier，设置
   `HERDR_BRIDGE_EASYTIERSERCRET`（+`HERDR_BRIDGE_EASYTIERSERVER` 中继、
   `HERDR_BRIDGE_EASYTIERSERVIRTUALIP` 静态虚拟 IP）后进入纯 EasyTier
   模式，REST API 走 data plane 虚拟 TCP，不监听 OS 端口、不需要
   TUN/root。`herdr-bridge --show-qr` 打印配对二维码，app 扫码即连
   （app 侧同样经内嵌 EasyTier + 本地端口转发，不申请 VpnService）。
   详见 `bridge/README.md` 的「EasyTier 模式」节与设计文档
   [`docs/superpowers/specs/2026-08-20-easytier-remote-access-design.md`](docs/superpowers/specs/2026-08-20-easytier-remote-access-design.md)。
   注意：二维码含完整网络凭据，等同钥匙，只在宿主机终端就地展示。
2. **前置代理**：bridge 侧设 `HERDR_BRIDGE_DEVICE_HEADER`（+
   `HERDR_BRIDGE_DEVICE_ALLOWLIST`），app 首次启动填 bridge 地址，并在
   「自定义请求头」里填对应 header（否则为只读模式）。

## 已知限制

- 后台 blocked 通知只监视 primary session；非 primary session 的 agent
  变 blocked 不会触发通知。
- 识别为按钮的对话框只有单选类（prompt-select）；wizard/multi-select/menu
  落到原始镜像 + 按键条操作（v1 明确不移植）。
- 对话框显示在屏幕上时从回复框发送文本会先弹确认（盲发 Enter 可能批准
  高亮选项）；自由文本项确认后仍可打字回答。
- 后台轮询最小周期 15 分钟（Android WorkManager 下限），通知可能延迟。

## 测试夹具

`app/test/fixtures/panes/*.txt` 是 vendored 的真实 pane 抓屏
（byte-faithful，含 CRLF；`.gitattributes` 已禁用文本归一化），
与外部仓库无运行时关系；prompt-select 语法的黄金测试基于这些夹具。
