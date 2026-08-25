# HerdrGo Bridge 插件化部署设计

状态：已实现，待发布首个 Release  
日期：2026-08-25

## 1. 背景

HerdrGo 手机端通过宿主机上的 `herdrgo-bridge` 访问 Herdr。bridge 已经具备零配置
EasyTier 组网、自动生成并持久化网络凭据、连接 Herdr socket 和提供 REST API 的能力，
但当前部署仍要求用户自行编译二进制、复制 systemd unit 并启动服务。

本设计将 bridge 发布为 Herdr plugin。Herdr 负责插件的发现、安装和操作入口，操作系统
的用户级服务管理器负责 bridge 的长期运行。最终用户不需要 Rust、EasyTier 源码或 root
权限。

## 2. 目标

- 用户通过 Herdr plugin 完成 bridge 的安装和管理。
- Linux 与 macOS 均使用用户级服务，不要求 `sudo`。
- `setup` 一次完成运行文件安装、服务注册、启动检查和二维码展示。
- bridge 崩溃后由操作系统自动拉起，并在用户登录后自动启动。
- 插件升级、重复执行 `setup` 或重装服务时保留已有 EasyTier 网络和配对凭据。
- 二进制下载可校验，构建输入可复现。
- 二维码和 EasyTier secret 不进入 systemd journal 或 launchd 日志。

## 3. 非目标

- 不为 Herdr core 新增 `[[services]]` 插件协议。
- 不使用长期占用的 plugin pane 运行 bridge。
- 不使用 `nohup`、PID 文件或自制守护器替代系统服务管理器。
- 第一版不支持 Windows、Docker、Homebrew 或 bridge 自动更新。
- 第一版不在 `herdr plugin install` 阶段自动启动远程控制服务。

## 4. 总体架构

```text
herdr plugin install
        │
        │ [[build]]：下载并校验当前平台的 bridge
        ▼
Herdr 管理的插件目录
        │
        │ 用户调用 setup action
        ▼
setup action
        │
        │ 插件内部打开 setup pane
        ▼
setup 控制脚本
        ├── 安装稳定运行副本到 HERDR_PLUGIN_STATE_DIR/runtime/
        ├── 安装 systemd user unit 或 LaunchAgent
        ├── 启动/重启并检查服务状态
        └── 在当前 setup pane 显示配对二维码
                         │
                         ▼
               herdrgo-bridge 用户服务
                    ├── Herdr Unix socket
                    └── EasyTier data plane ◄──► HerdrGo 手机端
```

plugin 是安装和操作入口，bridge 仍是独立进程。这样既沿用 Herdr plugin 的用户体验，
又让网络服务具备崩溃重启、登录自启和独立日志等标准守护能力。

## 5. 用户体验

首次安装只需要两步：

```bash
herdr plugin install KKRainbow/herdr-go
herdr plugin action invoke kkrainbow.herdrgo.setup
```

已经安装插件时只需执行第二条命令。`setup` action 是稳定的用户入口，它在插件内部
打开交互式 setup pane；用户不需要了解 pane entrypoint、placement 或 focus 参数。
setup 成功后直接在 pane 中显示二维码，用户用 HerdrGo 扫码即可。

action 本身只负责启动界面，不输出二维码或执行安装。实际 setup 仍在 pane 中运行，
因为 Herdr 会捕获普通 action 的标准输出，二维码和交互式错误信息不适合只留在
plugin log 中。内部 pane 是实现细节，不作为面向用户的命令接口。

日常操作统一通过 action 调用；需要交互或展示详细输出的 action 在内部打开 pane：

| 入口 | 类型 | 行为 |
| --- | --- | --- |
| `setup` | action → pane | 安装或更新运行副本、注册服务、启动并显示二维码 |
| `pair` | action → pane | 读取现有状态并重新显示二维码，不重启服务 |
| `status` | action → pane | 显示版本、服务状态、配置路径和诊断提示 |
| `start` | action | 启动已安装服务 |
| `stop` | action | 停止服务但保留安装和配对状态 |
| `restart` | action | 重启服务 |
| `uninstall-service` | action → pane | 停止并移除服务，默认保留配对状态 |

`herdr plugin uninstall kkrainbow.herdrgo` 只删除插件本身。用户应先运行
`herdr plugin action invoke kkrainbow.herdrgo.uninstall-service`；文档和卸载界面必须
明确这个顺序。

## 6. Plugin manifest

仓库根目录新增 `herdr-plugin.toml`，核心结构如下：

```toml
id = "kkrainbow.herdrgo"
name = "HerdrGo"
version = "<与 release tag 一致>"
min_herdr_version = "0.8.2"
description = "Native mobile remote control bridge for Herdr"
platforms = ["linux", "macos"]

[[build]]
command = ["bash", "plugin/install.sh"]

[[actions]]
id = "setup"
title = "Set up HerdrGo bridge"
contexts = ["workspace"]
command = ["bash", "plugin/herdrgo-action.sh", "setup-ui"]

[[panes]]
id = "setup-ui"
title = "HerdrGo Setup"
placement = "zoomed"
command = ["bash", "plugin/herdrgo-ctl.sh", "setup"]

[[actions]]
id = "pair"
title = "Pair HerdrGo"
contexts = ["workspace"]
command = ["bash", "plugin/herdrgo-action.sh", "pair-ui"]

[[panes]]
id = "pair-ui"
title = "Pair HerdrGo"
placement = "overlay"
command = ["bash", "plugin/herdrgo-ctl.sh", "pair"]

[[actions]]
id = "status"
title = "Show HerdrGo status"
contexts = ["workspace"]
command = ["bash", "plugin/herdrgo-action.sh", "status-ui"]

[[panes]]
id = "status-ui"
title = "HerdrGo Status"
placement = "overlay"
command = ["bash", "plugin/herdrgo-ctl.sh", "status"]

[[actions]]
id = "start"
title = "Start HerdrGo bridge"
contexts = ["workspace"]
command = ["bash", "plugin/herdrgo-ctl.sh", "start"]

[[actions]]
id = "stop"
title = "Stop HerdrGo bridge"
contexts = ["workspace"]
command = ["bash", "plugin/herdrgo-ctl.sh", "stop"]

[[actions]]
id = "restart"
title = "Restart HerdrGo bridge"
contexts = ["workspace"]
command = ["bash", "plugin/herdrgo-ctl.sh", "restart"]

[[actions]]
id = "uninstall-service"
title = "Uninstall HerdrGo bridge service"
contexts = ["workspace"]
command = ["bash", "plugin/herdrgo-action.sh", "uninstall-service-ui"]

[[panes]]
id = "uninstall-service-ui"
title = "Uninstall HerdrGo bridge service"
placement = "zoomed"
command = ["bash", "plugin/herdrgo-ctl.sh", "uninstall-service"]
```

`herdrgo-action.sh` 是很薄的界面启动器：它通过 `HERDR_BIN_PATH` 和
`HERDR_PLUGIN_ID` 调用 `herdr plugin pane open`，并把 manifest 中声明的 pane 布局留在
插件内部。用户文档只公开 action id，不公开内部 `*-ui` pane id。

插件最低要求 Herdr 0.8.2，与手机端创建 agent 所需的 Herdr API 版本保持一致。

## 7. 文件与目录

插件 checkout 会在重新安装时被替换，因此系统服务不能直接把
`$HERDR_PLUGIN_ROOT/bin/herdrgo-bridge` 写入 `ExecStart`。运行文件必须复制到不会随
checkout 变化的 plugin state 目录。

```text
$HERDR_PLUGIN_ROOT/
├── bin/herdrgo-bridge                 # [[build]] 下载的候选版本
└── plugin/
    ├── install.sh                     # 平台检测、下载和校验
    ├── herdrgo-action.sh              # action 到交互式 pane 的内部适配层
    └── herdrgo-ctl.sh                 # setup 与服务管理

$HERDR_PLUGIN_STATE_DIR/
├── runtime/herdrgo-bridge             # 系统服务使用的稳定运行副本
├── runtime/herdrgo-ctl.sh             # 插件误删后的恢复/卸载入口
├── easytier_secret                    # 0600，现有 bridge 状态
├── easytier_network_id                # 0600，现有 bridge 状态
├── audit.log
└── logs/                              # macOS stdout/stderr

$HERDR_PLUGIN_CONFIG_DIR/
└── env                                # 可选高级配置，0600
```

`setup` 使用同目录临时文件加原子 rename 更新运行副本，避免服务启动到半写入的
二进制。state 目录权限为 `0700`，凭据与配置文件权限为 `0600`。

## 8. `setup` 生命周期

`setup` 必须幂等。第一次运行和升级后重复运行走同一条路径：

1. 验证平台、CPU 架构、候选二进制和 Herdr socket。
2. 创建并收紧 plugin state/config 目录权限。
3. 获取控制锁，避免两个 setup 同时替换运行文件或操作服务。
4. 将候选 bridge 原子安装到稳定 runtime 路径。
5. 将控制脚本复制到稳定 runtime 路径，便于插件 checkout 已删除时恢复或卸载。
6. 根据平台生成并原子安装用户级服务定义。
7. reload 服务管理器并启动或重启 bridge。
8. 等待服务进入 running 状态；失败时打印短错误和明确的日志查看命令。
9. 调用稳定运行副本的配对输出逻辑，在当前 pane 显示二维码。

重复执行 setup 不删除 state 文件、不轮换 EasyTier secret、不改变 network id。只有用户
显式执行未来的“重置配对”操作时才允许生成新凭据；该操作不属于第一版。

## 9. Linux 服务

Linux 使用 systemd user unit：

```text
~/.config/systemd/user/herdrgo-bridge.service
```

关键约束：

- `ExecStart` 指向 `$HERDR_PLUGIN_STATE_DIR/runtime/herdrgo-bridge` 的绝对路径。
- `HERDR_SOCKET_PATH` 使用 Herdr 注入值；缺省回落到
  `~/.config/herdr/herdr.sock`。
- `HERDRGO_BRIDGE_STATE_DIR` 指向 `$HERDR_PLUGIN_STATE_DIR`。
- `HERDRGO_BRIDGE_ENV_FILE` 指向可选的 `$HERDR_PLUGIN_CONFIG_DIR/env`；由 bridge
  按 dotenv `KEY=value` 语法安全解析，不通过 shell 执行配置内容。
- `Restart=on-failure`、`RestartSec=5`、`StartLimitIntervalSec=0`。
- 保留 `NoNewPrivileges=yes` 与 `PrivateTmp=yes`。
- 通过 `systemctl --user enable --now` 安装和启动，不使用 system unit。

对于需要注销后仍工作的无人值守 Linux 主机，setup 只检测并提示
`loginctl enable-linger $USER`，不自行请求 root 或修改系统策略。

如果系统不存在可用的 systemd user manager，稳定 setup 明确失败并说明只支持前台
开发运行；不静默回落到 `nohup`。

## 10. macOS 服务

macOS 使用用户域 LaunchAgent：

```text
~/Library/LaunchAgents/kkrainbow.herdrgo.plist
```

关键约束：

- `ProgramArguments` 指向稳定 runtime 二进制。
- `RunAtLoad=true`。
- 仅在异常退出时由 `KeepAlive` 重启，用户主动 stop 后不立即复活。
- 环境变量与 Linux 保持同一语义，plist 只保存配置文件路径，不展开其中的 secret。
- stdout/stderr 写到 `$HERDR_PLUGIN_STATE_DIR/logs/`，文件中不得包含配对凭据。
- 通过 `launchctl bootstrap/bootout/kickstart` 操作 `gui/$(id -u)` 用户域。
- 不写 `/Library/LaunchDaemons`，不使用 `sudo`。

LaunchAgent 在用户登录后运行，不承诺 Mac 停留在登录窗口时提供服务。

## 11. 配对与凭据安全

当前 bridge 在启动时向 stdout 打印二维码和明文配对 JSON。进入系统服务后，这会把
EasyTier secret 长期写入 journal 或 launchd 日志，公开发行前必须改变。

设计要求：

- 服务模式启动时不输出二维码、secret 或完整配对 JSON。
- bridge 提供独立的配对输出入口，由 `setup` 和 `pair` 在交互式 pane 中调用。
  默认只显示二维码和可读连接摘要，不重复打印明文 secret；完整载荷只由
  显式 `pair --json` 输出。
- 配对入口复用 bridge 内部的配置解析和 `pairing_payload` 生成逻辑，不在 shell
  脚本中重复拼接协议字段。
- secret 只从 state 目录读取，不写入命令行参数、unit 文件或 plist。
- 二维码仍等同访问凭据；界面和文档继续提示用户不要截图或分享。

为了保持现有开发体验，前台手动运行 bridge 是否继续自动打印二维码可在实现时保留；
系统服务必须显式关闭该行为。

## 12. 安装与发布

`plugin/install.sh` 只负责把候选二进制放进插件 checkout，不注册或启动服务。脚本：

1. 从 manifest 读取插件版本。
2. 将 `uname` 映射到以下 release target：
   - `x86_64-unknown-linux-musl`
   - `aarch64-unknown-linux-musl`
   - `x86_64-apple-darwin`
   - `aarch64-apple-darwin`
3. 下载与插件版本完全一致的 GitHub Release 归档及 SHA256 文件。
4. 校验摘要后解压到 `$HERDR_PLUGIN_ROOT/bin/`。
5. 对不支持的平台明确失败，不从源码临时编译。

Release CI 为每个 tag 构建四个平台产物、SHA256 sidecar 和构建来源证明。发布前必须把
bridge 对 EasyTier 的本地相对路径依赖改为可公开获取且固定 revision 的依赖；不能让
release 构建依赖 CI 机器恰好存在 `../../EasyTier`。

第一版不依赖 cargo-dist。一个明确的四目标构建矩阵和简短下载脚本足够；未来如果要
增加独立于 Herdr plugin 的安装渠道，再评估 cargo-dist 或 Homebrew。

## 13. 升级与回滚

升级流程：

```bash
herdr plugin install KKRainbow/herdr-go --yes
herdr plugin action invoke kkrainbow.herdrgo.setup
```

第二次 setup 将新候选版本复制到稳定 runtime 路径并重启服务。state/config 目录位于
插件 checkout 之外，因此升级不改变配对关系。

更新失败时：

- 候选二进制下载或校验失败：不触碰当前运行副本。
- runtime 原子替换失败：当前副本保持可执行，服务不重启。
- 新服务启动失败：保留错误日志和上一版本备份路径，setup 给出恢复命令。
- 第一版不做静默自动更新，避免在无人值守时改变远程控制边界。

## 14. 卸载

`uninstall-service` 的默认行为：

1. 请求用户确认。
2. 停止并 disable/bootout 用户服务。
3. 删除 unit/plist 和稳定 runtime 文件。
4. reload 服务管理器。
5. 保留 plugin state/config，包括配对凭据和审计记录。

保留状态使用户重装后能够恢复原有配对。彻底删除 secret 的 purge 操作如果以后提供，
必须是单独、显式并再次确认的破坏性操作。

## 15. 失败处理原则

- 服务管理器不可用时明确失败，不增加第二套守护机制。
- Herdr 暂时离线时 bridge 保持运行并继续重连，不重装或重启服务。
- EasyTier 暂时离线时依赖 EasyTier 自身重连，不由 setup 建立额外恢复循环。
- `start`、`stop`、`restart` 只操作本插件创建的精确 service label/unit。
- 所有状态判断基于服务管理器的结构化结果和精确路径，不使用宽泛的进程名匹配。
- 错误信息必须同时给出原因和下一条可执行的诊断命令。

## 16. 验收标准

自动测试：

- 平台和架构到 release target 的映射。
- 下载失败、摘要不匹配和不支持平台时 fail closed。
- 使用 fake `systemctl` 验证 Linux setup/start/stop/restart/uninstall 调用。
- 使用 fake `launchctl` 验证 macOS 对应调用和 plist 内容。
- setup 连续运行两次不改变 secret/network id。
- 升级 runtime 二进制后服务定义仍引用稳定路径。
- 服务启动日志不包含 secret 或完整配对 JSON。
- `pair` 生成的载荷与 app 当前扫码协议兼容。
- `herdr plugin action invoke kkrainbow.herdrgo.setup` 能打开 setup pane，且用户无需传入
  pane 布局参数。

人工验收：

- 一台干净的 x86_64 Linux 主机。
- 一台 aarch64 Linux 主机。
- Apple Silicon macOS。
- Intel macOS（可由 CI 构建加至少一次真实安装验证）。
- 安装、扫码、手机连接、bridge 崩溃自动恢复、Herdr 重启恢复、主机重新登录恢复。
- 插件重装并再次 setup 后，原手机无需重新配对即可连接。
- 执行 uninstall-service 后 bridge 不再运行，重新 setup 后原配对状态恢复。

## 17. 实施顺序

1. 固定可复现的 EasyTier 依赖来源。
2. 增加 bridge 的安全配对输出入口，并禁止服务日志输出凭据。
3. 增加 plugin manifest、下载脚本和控制脚本。
4. 实现并测试 systemd user 与 LaunchAgent 安装。
5. 接入四平台 Release CI。
6. 更新中文/英文 README 的安装、升级和卸载说明。
7. 在 Linux 与 macOS 上完成真实 plugin 安装和手机扫码验收。

## 18. 实现落点

- `herdr-plugin.toml` 声明公开 action 和内部 pane。
- `plugin/install.sh` 下载与校验四平台 Release 产物。
- `plugin/herdrgo-action.sh` 把单行 action 调用转换为内部 pane。
- `plugin/herdrgo-ctl.sh` 管理稳定运行副本、systemd user unit 和 LaunchAgent。
- `herdrgo-bridge pair` 显示二维码和可读摘要，`pair --json` 显式输出完整载荷；
  普通服务启动不再输出二维码或配对 JSON。
- `.github/workflows/bridge-ci.yml` 运行 bridge 与 plugin 自动测试。
- `.github/workflows/bridge-release.yml` 构建四平台产物、SHA256 和来源记录。

公开安装命令生效前，还需要将实现推送到 GitHub 并创建与 manifest 版本一致的
`v0.1.0` tag，由 Release workflow 生成首批下载资产。发布不属于本地实现提交的一部分。
