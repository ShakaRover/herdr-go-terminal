<div align="center">

# HerdrGo

**把整群 coding agent 装进口袋。**

[herdr](https://herdr.dev) agent 的原生手机客户端

`Flutter` · `Android` · `Rust bridge` · `EasyTier P2P`

**[English → README.md](README.md)**

</div>

---

在电脑上同时跑几个 codex / kimi / claude，人一旦离开工位就只能干等——生怕哪个
agent 卡在审批弹窗上没人点。HerdrGo 让你在手机上盯住整群 agent：谁在干活、谁
卡住了等你拍板，一眼看清；点进去就能回话、发键、批准操作，人在哪都能让它们
继续跑。

配对只要扫一个二维码。bridge 跑在宿主机上，启动即打印二维码，app 一扫就通过
EasyTier 虚拟网直连——不用配 TUN、不用 root、不用申请 VPN 权限，secret 自动生成
并持久化，零参数开箱即用。

## 截图

<p>
  <img src="assets/readme/dashboard.png" width="260" alt="Dashboard：待处理置顶">
  &nbsp;
  <img src="assets/readme/agent-detail.png" width="260" alt="agent 对话：ANSI 镜像 + 按键条">
  &nbsp;
  <img src="assets/readme/approval.png" width="260" alt="审批菜单：原生按钮">
</p>

*左：Dashboard 把卡住等你处理的 agent 置顶（「需要你处理」），其余按状态分组。
中：agent 对话是带 ANSI 颜色的终端镜像，底部有 Esc / Ctrl+C / 方向键 / 发送。
右：Claude 式审批菜单被识别成原生按钮，点一下即批准。*

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

## 工作原理

```
┌─────────────┐      扫码配对      ┌──────────────────────────────┐
│  HerdrGo    │ ◄─────────────── │  herdrgo-bridge（宿主机）     │
│  app（手机）│                    │  · 连本机 herdr socket        │
└──────┬──────┘                    │  · 对外提供 REST API          │
       │ EasyTier 虚拟网           │  · 内嵌 EasyTier（无 TUN）    │
       │ （P2P 加密，中继不可见）  └──────────────┬───────────────┘
       └──────────────────────────────────────────┘
                        data plane 虚拟 TCP
```

app 不直接连 herdr socket，一切读写都经过 bridge；bridge 内嵌 EasyTier 把
REST API 暴露到虚拟网络，app 侧同样内嵌 EasyTier 把本地端口转发进虚拟网络，
全程用户态。

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

app 内嵌 EasyTier（无 TUN，经 EasyTier 自带管理 RPC `PatchConfig`
端口转发 patch 把 `127.0.0.1:<port>` 转发到虚拟网络内的 bridge）。
原生产物（`libeasytier_android_jni.so` + Kotlin 绑定）由
`app/tool/sync_easytier.sh` 从 EasyTier 仓库构建并拷入
`app/android/app/src/main/`（jniLibs 与 `kotlin/com/easytier/jni/`）：

```bash
app/tool/sync_easytier.sh   # 幂等；EASYTIER_REPO 可覆盖 EasyTier 仓库路径
```

`EasyTierManager.kt`/`EasyTierVpnService.t.kt` 依赖 VpnService 与 moshi，
不同步。Dart 侧封装见 `app/lib/api/easytier_channel.dart`。

iOS 侧由 `app/tool/build_ios_easytier.sh`（仅 macOS）从同一 EasyTier 分支
构建薄的 `easytier-ios` C ABI 静态库，拷入 `app/ios/Frameworks/`。

## 部署 bridge

bridge 部署在 herdr 宿主机上：

```bash
cd bridge
cargo build --release
# 产物：bridge/target/release/herdrgo-bridge
```

常驻运行可用 `bridge/systemd/` 下的 systemd 单元。bridge **默认零配置即进入
EasyTier 模式**：自动生成并持久化网络 secret，经默认中继
`txt://herdrgo.et-link.cc` 组网，REST API 走 data plane 虚拟 TCP，不监听 OS
端口、不需要 TUN/root。启动时打印配对二维码，app 扫码即连（app 侧同样经
内嵌 EasyTier + 本地端口转发，不申请 VpnService）。常用选项只有
`--secret` / `--server` / `--port`（`--help`），高级选项见 `--help-advance`。
secret 即网络凭据，等同钥匙，只在宿主机终端就地展示、勿泄露。详见
`bridge/README.md`。

如需走 HTTP 直连（本机/前置代理调试），显式关闭 EasyTier：`herdrgo-bridge
--secret ""`，此时监听 `--host`/`--http-port`（默认 `127.0.0.1:8787`），并可用
`HERDRGO_BRIDGE_DEVICE_HEADER`（+`HERDRGO_BRIDGE_DEVICE_ALLOWLIST`）做 device
gate，app 首次启动填 bridge 地址并在「自定义请求头」里填对应 header（否则
为只读模式）。

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
