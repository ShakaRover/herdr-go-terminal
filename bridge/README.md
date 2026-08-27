# herdrgo-bridge

herdr 的 REST 桥接服务（Rust / axum）：连接本机 herdr 的 Unix socket，
对外提供 HTTP API，供本仓库的 Flutter app（`app/`）消费。app 不直接
连 herdr socket，一切读写都经过 bridge。

默认**零配置启动即进入 EasyTier 模式**：自动生成并持久化网络 secret，
经默认中继 `txt://herdrgo.et-link.cc` 组网，REST API 走 EasyTier data
plane 虚拟 TCP，不监听任何 OS 端口、不需要 TUN/root；app 扫码即连。
无 push/websocket，app 侧轮询。

服务启动不会输出 secret。需要配对时在私有终端运行
`herdrgo-bridge pair`，它会读取现有 state，显示二维码和人类可读的
连接摘要后退出，不在终端打印明文 secret。仅调试或手工导入时使用
`herdrgo-bridge pair --json` 输出完整载荷。

## v1 端点

所有端点带 `/api/v1` 前缀；除 `config` 外都支持 `?session=` 选择 herdr
session（缺省为 primary）。写端点（POST）受 device gate 约束（见配置节）。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/config` | bridge 构建信息（`build` 等），无需鉴权 |
| GET | `/api/v1/snapshot` | dashboard 快照：`bridge` 连接态、`agents`、`shellPanes`、`workspaces`、`tabs`、`sessions`、`ts` |
| GET | `/api/v1/agents/kinds` | 从 Herdr 动态读取可用 agent 类型（需 Herdr 0.8.2+） |
| POST | `/api/v1/agents` | 在新建 workspace 或已有 workspace 的新 tab 中启动 agent，可选发送 `initialPrompt` |
| GET | `/api/v1/pane/{id}` | 读 pane 终端镜像（ANSI 文本），`?lines=`（默认 200，上限 10000）；带 ETag，支持 `If-None-Match` → 304 |
| GET | `/api/v1/pane/{id}/history` | 从 agent 自己的会话日志分页读历史，`?limit=&before=` 游标分页 |
| POST | `/api/v1/pane/{id}/reply` | 发送文本，body `{text?, submit?, expectedPrompt?}`；带 `expectedPrompt` 时先做 prompt-binding 校验，不匹配返回 409 `prompt_changed` |
| POST | `/api/v1/pane/{id}/keys` | 发送按键，body `{keys: [...], expectedPrompt?}`，同样支持 prompt-binding |
| POST | `/api/v1/pane/{id}/resize` | 用 `{cols, rows, leaseId?}` 获取或续期 terminal controller 租约；首次请求会 takeover，返回 `{leaseId}`，租约 20 秒未续期会自动释放 |
| DELETE | `/api/v1/pane/{id}/resize/{leaseId}` | 离开手机详情页或进入后台时释放 terminal controller，让电脑端恢复控制 |
| POST | `/api/v1/pane/{id}/close` | 关闭 pane |
| POST | `/api/v1/pane/{id}/rename` | 重命名 pane，body `{label: string|null}`（`null` 清除自定义名） |
| POST | `/api/v1/pane/{id}/upload` | multipart 上传图片（字段名 `file`，≤10MB），落盘到 state 目录并返回 `{ok, path}` |

错误统一为 JSON body：`{"error": <消息>, "code": <机读码>}`；reply 在文本
已送达但提交键失败时返回 502 且带 `textDelivered: true`。所有写级动作
追加审计到 `<state_dir>/audit.log`。
创建 agent 在终端已创建、但 agent 启动或初始任务发送失败时，
错误体额外返回 `created: {workspaceId, tabId, paneId}`；客户端不自动
删除这个 pane，避免启动超时后误杀仍在运行的 agent。

## 构建

```bash
cd bridge
cargo build --release
# 产物：bridge/target/release/herdrgo-bridge
```

## 推荐部署（Herdr plugin）

```bash
herdr plugin install herdr-go/herdr-go
herdr plugin action invoke herdrgo.setup
```

setup 会安装 systemd user service（Linux）或 LaunchAgent（macOS），启动后在
交互式 pane 显示二维码。重复 setup 会原子升级运行副本并保留配对状态。

## 手动部署（systemd user 单元）

```bash
install -Dm755 target/release/herdrgo-bridge ~/.local/bin/herdrgo-bridge
mkdir -p ~/.config/systemd/user
cp systemd/herdrgo-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now herdrgo-bridge
herdrgo-bridge pair                         # 在私有终端显示配对二维码
journalctl --user -u herdrgo-bridge -n 20   # 只包含服务日志，不包含配对凭据
```

单元内置了 socket 路径与 state 目录两个默认值；需要覆盖时写
`~/.config/herdrgo-bridge/env`（`EnvironmentFile=-` 可选加载，KEY=VALUE
每行一个），再 `systemctl --user restart herdrgo-bridge`。例如改用自建
中继、固定 EasyTier 监听端口：

```bash
mkdir -p ~/.config/herdrgo-bridge
printf 'HERDRGO_BRIDGE_SERVER=tcp://et.example.com:11010\nHERDRGO_BRIDGE_PORT=23000\n' \
  > ~/.config/herdrgo-bridge/env
systemctl --user restart herdrgo-bridge
```

## 从 herdr-bridge 迁移

本组件原名 `herdr-bridge`，改名后以下四处同时变化：

| 项 | 旧 | 新 |
| --- | --- | --- |
| 二进制 / systemd unit | `herdr-bridge` | `herdrgo-bridge` |
| state 目录 | `~/.local/state/herdr-bridge` | `~/.local/state/herdrgo-bridge` |
| env 文件 | `~/.config/herdr-bridge/env` | `~/.config/herdrgo-bridge/env` |
| 环境变量前缀 | `HERDR_BRIDGE_*` | `HERDRGO_BRIDGE_*` |

`HERDR_SOCKET_PATH` 与 `~/.config/herdr/herdr.sock` 属于上游 herdr 的接口，
不在此次改名范围，保持不变。

```bash
systemctl --user disable --now herdr-bridge
install -Dm755 target/release/herdrgo-bridge ~/.local/bin/herdrgo-bridge
mkdir -p ~/.config/herdrgo-bridge
sed 's/^HERDR_BRIDGE_/HERDRGO_BRIDGE_/' ~/.config/herdr-bridge/env \
  > ~/.config/herdrgo-bridge/env
# 保留 audit/activity/easytier_network_id 等历史状态（可选）
mv ~/.local/state/herdr-bridge ~/.local/state/herdrgo-bridge
systemctl --user daemon-reload
systemctl --user enable --now herdrgo-bridge
```

### CLI 选项语义变化（v2）

除改名外，本次还重构了 CLI 默认行为，**旧部署脚本里的参数需要对照调整**：

- **默认即 EasyTier 模式**：不再要求显式设置 secret。secret 缺省时自动生成
  并持久化到 `<state_dir>/easytier_secret`（0600），重启保持稳定。
- `--port` / `HERDRGO_BRIDGE_PORT` 的含义**从 HTTP 绑定端口（旧默认 8787）
  改为 EasyTier 被动监听端口（默认 22023）**。
- HTTP 直连绑定地址/端口改由 `--host` / `--http-port`（`HERDRGO_BRIDGE_HOST` /
  `HERDRGO_BRIDGE_HTTP_PORT`）控制，且仅在显式 `--secret ""`（关闭 EasyTier）
  时才监听。
- 中继服务器变量 `HERDRGO_BRIDGE_EASYTIERSERVER` → `HERDRGO_BRIDGE_SERVER`
  （默认 `txt://herdrgo.et-link.cc`）；secret 变量 `HERDRGO_BRIDGE_EASYTIERSERCRET`
  → `HERDRGO_BRIDGE_SECRET`；`HERDRGO_BRIDGE_EASYTIERLISTENPORT` 已并入 `--port`。
- 常用 `--help` 只显示 `--secret` / `--server` / `--port`；其余高级选项见
  `herdrgo-bridge --help-advance`。

## 配置（CLI 与环境变量）

权威来源是 `bridge/src/config.rs` 的 `Cli`（clap derive）。除启动前加载配置文件的
`HERDRGO_BRIDGE_ENV_FILE` 外，每个环境变量都有对应的 CLI 参数（kebab-case，如
`HERDRGO_BRIDGE_PORT` ↔ `--port`），优先级
**CLI > 进程环境变量 > `HERDRGO_BRIDGE_ENV_FILE` 指定的配置文件 > 默认值**。
配置文件使用 dotenv `KEY=value` 语法，不执行 shell 代码。列表类参数接受逗号分隔或重复传参；布尔参数
接受 `on/off`、`1/0`、`true/false`。类型或取值非法时启动即报错退出；
低于下限的数值 clamp 到下限并告警。环境变量值解析前会去除首尾空白，
空白值视为未设置。

日常只需关心三个常用选项（`--help` 只显示这三个），缺省即可零配置启动：

| 变量 / CLI 参数 | 默认 | 说明 |
| --- | --- | --- |
| `HERDRGO_BRIDGE_SECRET` / `--secret` | 自动生成并持久化到 `<state_dir>/easytier_secret`（0600） | EasyTier 网络 secret，**即访问凭据，等同钥匙，勿泄露**。显式传空串 `--secret ""` 关闭 EasyTier、走 HTTP 直连 |
| `HERDRGO_BRIDGE_SERVER` / `--server` | `txt://herdrgo.et-link.cc` | EasyTier 中继/发现服务器（可重复或逗号分隔） |
| `HERDRGO_BRIDGE_PORT` / `--port` | `22023` | EasyTier 被动监听端口（`tcp://0.0.0.0`，利于 p2p 打洞） |

```bash
herdrgo-bridge                          # 零配置：自动 secret + 默认中继，扫码即连
herdrgo-bridge --secret ""              # 关闭 EasyTier，走 HTTP 直连（见高级选项 --host/--http-port）
herdrgo-bridge --server tcp://et.example.com:11010 --port 23000
```

其余高级选项（HTTP 直连、device gate、轮询、transcript、各 agent 日志 root
等）见 `herdrgo-bridge --help-advance`，与环境变量一一对应；对应表：

| 变量 / CLI 参数 | 默认 | 说明 |
| --- | --- | --- |
| `HERDR_SOCKET_PATH` | `~/.config/herdr/herdr.sock`（遵循 `XDG_CONFIG_HOME`） | herdr API socket |
| `HERDR_BIN_PATH` / `--herdr-bin-path` | `herdr` | herdr CLI 路径；plugin setup 会固定为当前可执行文件的绝对路径 |
| `HERDRGO_BRIDGE_ENV_FILE` | 空 | 启动前读取的 dotenv 配置文件；现有进程环境优先，不执行 shell 代码 |
| `HERDRGO_BRIDGE_HOST` / `--host` | `127.0.0.1` | HTTP 直连绑定地址（仅 `--secret ""` 时监听） |
| `HERDRGO_BRIDGE_HTTP_PORT` / `--http-port` | `8787` | HTTP 直连绑定端口（仅 `--secret ""` 时监听） |
| `HERDRGO_BRIDGE_STATE_DIR` | `~/.local/state/herdrgo-bridge`（遵循 `XDG_STATE_HOME`） | 状态目录（audit、activity、上传、持久化 secret/network id） |
| `HERDRGO_BRIDGE_POLL_MS` | `1500`（min 250） | 活跃轮询间隔 |
| `HERDRGO_BRIDGE_POLL_IDLE_MS` | `12000`（min 1000） | 空闲轮询间隔 |
| `HERDRGO_BRIDGE_READ_LINES` | `200`（min 1） | pane 读默认行数 |
| `HERDRGO_BRIDGE_SUBMIT_KEYS` | `Enter` | reply 提交键（逗号分隔） |
| `HERDRGO_BRIDGE_ALLOWED_ORIGINS` | 空 | 精确 origin 列表（逗号分隔） |
| `HERDRGO_BRIDGE_PUBLIC_HOSTS` | 空 | Host allowlist（逗号分隔） |
| `HERDRGO_BRIDGE_TRUSTED_USER` | 空 | Tailscale 身份 |
| `HERDRGO_BRIDGE_DEVICE_HEADER` | 空 | device gate 请求头名；设置后写端点要求该头（仅 HTTP 直连模式） |
| `HERDRGO_BRIDGE_DEVICE_ALLOWLIST` | 空 | device 白名单（逗号分隔）；空 = 所有设备只读（fail-closed） |
| `HERDRGO_BRIDGE_MULTI_SESSION` | `on` | `off` 时只看 primary session |
| `HERDRGO_BRIDGE_TRANSCRIPT` | `on` | history 总开关 |
| `HERDRGO_BRIDGE_TRANSCRIPT_ROOT` | `~/.claude/projects`（逗号多 root） | claude 日志 root |
| `HERDRGO_BRIDGE_CODEX_ROOT` | `$CODEX_HOME/sessions` | codex 日志 root |
| `HERDRGO_BRIDGE_PI_ROOT` | `$PI_CODING_AGENT_DIR/sessions` | pi 日志 root |
| `HERDRGO_BRIDGE_OPENCODE_ROOT` | `$XDG_DATA_HOME/opencode` 或 `~/.local/share/opencode` | opencode 数据目录 |
| `HERDRGO_BRIDGE_EASYTIERSERWORKNAME` | 空 | 覆盖网络名；缺省用 state 目录持久化的 uuid（`<state_dir>/easytier_network_id`，0600） |
| `HERDRGO_BRIDGE_EASYTIERSERVIRTUALIP` | `10.126.0.1/24` | 静态虚拟 IPv4（CIDR）；缺省固定值，一般无需配置 |

布尔值接受 `on/off`、`1/0`、`true/false`；CLI 侧同理（如 `--multi-session off`）。

## EasyTier 模式（远程访问）

默认即 EasyTier 模式：secret 自动生成并持久化，bridge 内嵌 EasyTier 实例
加入一个独立网络（network_name = 持久化 uuid 或覆盖值），REST API 改从
EasyTier **data plane** 的虚拟 TCP listener（`--http-port`，默认 8787）接收
连接，不再监听 OS 端口；全程用户态，不需要 TUN/root。

EasyTier 被动监听 `--port`（默认 22023）用于 p2p 打洞与中继；中继地址默认
`txt://herdrgo.et-link.cc`（DNS TXT 解析，EasyTier 原生支持 `txt`/`srv`/
`http(s)` scheme 做 peer discovery）。

```bash
# ~/.config/herdrgo-bridge/env 示例：固定 secret / 自建中继（虚拟 IP 有缺省值，
# 一般无需配置）
HERDRGO_BRIDGE_SECRET=你指定的secret
HERDRGO_BRIDGE_SERVER=tcp://et.example.com:11010
```

执行 `herdrgo-bridge pair` 会打印配对二维码和可读连接摘要，不重复
打印明文 secret；`herdrgo-bridge pair --json` 才会输出含
server/networkName/secret/virtualIp/port 的完整载荷。普通 bridge 服务启动
不输出这些内容。**secret 即网络钥匙，二维码等同凭据，只在宿主机
私有终端就地展示，勿截图外泄。**

注意：bridge 是虚拟网内唯一静态节点（virtualIp 缺省 `10.126.0.1/24`，可用
`HERDRGO_BRIDGE_EASYTIERSERVIRTUALIP` 覆盖），手机端走 DHCP 自动避让，二维码
里的拨号地址因此启动即确定。加密由 EasyTier 传输层承担（密钥从
network_name+secret 派生），中继服务器看不到明文；EasyTier 模式下不设应用层
device gate（secret 即唯一凭据）。

## 与 collie 的关系

collie（`.toolchain/reference-collie/`）是 herdr 生态里更早的 Bun/TypeScript
版桥，服务面更宽（web 终端、push、wizard 等）。本 bridge 只实现 **app 实际消费
的那一面**，刻意不移植其余功能。协议上有意为之的差异：

- 端点统一加 `/api/v1` 前缀；
- 错误一律 JSON body（`{error, code}`），不复用 collie 的文本错误；
- 状态码语义化（400/409/413/415/502 等），prompt 失配用 409 +
  `prompt_changed`；
- 请求/响应字段全部 camelCase（如 `expectedPrompt`、`shellPanes`），
  seen 头为 `x-bridge-seen`。
