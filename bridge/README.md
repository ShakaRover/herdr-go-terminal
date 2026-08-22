# herdr-bridge

herdr 的 REST 桥接服务（Rust / axum）：连接本机 herdr 的 Unix socket，
对外提供 HTTP API，供本仓库的 Flutter app（`app/`）消费。app 不直接
连 herdr socket，一切读写都经过 bridge。

默认监听 `127.0.0.1:8787`，无 push/websocket，app 侧轮询。

## v1 端点

所有端点带 `/api/v1` 前缀；除 `config` 外都支持 `?session=` 选择 herdr
session（缺省为 primary）。写端点（POST）受 device gate 约束（见配置节）。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/config` | bridge 构建信息（`build` 等），无需鉴权 |
| GET | `/api/v1/snapshot` | dashboard 快照：`bridge` 连接态、`agents`、`shellPanes`、`workspaces`、`tabs`、`sessions`、`ts` |
| GET | `/api/v1/pane/{id}` | 读 pane 终端镜像（ANSI 文本），`?lines=`（默认 200，上限 10000）；带 ETag，支持 `If-None-Match` → 304 |
| GET | `/api/v1/pane/{id}/history` | 从 agent 自己的会话日志分页读历史，`?limit=&before=` 游标分页 |
| POST | `/api/v1/pane/{id}/reply` | 发送文本，body `{text?, submit?, expectedPrompt?}`；带 `expectedPrompt` 时先做 prompt-binding 校验，不匹配返回 409 `prompt_changed` |
| POST | `/api/v1/pane/{id}/keys` | 发送按键，body `{keys: [...], expectedPrompt?}`，同样支持 prompt-binding |
| POST | `/api/v1/pane/{id}/close` | 关闭 pane |
| POST | `/api/v1/pane/{id}/rename` | 重命名 pane，body `{label: string|null}`（`null` 清除自定义名） |
| POST | `/api/v1/pane/{id}/upload` | multipart 上传图片（字段名 `file`，≤10MB），落盘到 state 目录并返回 `{ok, path}` |

错误统一为 JSON body：`{"error": <消息>, "code": <机读码>}`；reply 在文本
已送达但提交键失败时返回 502 且带 `textDelivered: true`。所有写级动作
追加审计到 `<state_dir>/audit.log`。

## 构建

```bash
cd bridge
cargo build --release
# 产物：bridge/target/release/herdr-bridge
```

## 部署（systemd user 单元）

```bash
install -Dm755 target/release/herdr-bridge ~/.local/bin/herdr-bridge
mkdir -p ~/.config/systemd/user
cp systemd/herdr-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now herdr-bridge
curl -s localhost:8787/api/v1/config
journalctl --user -u herdr-bridge -n 20
```

单元内置了 socket 路径、端口、state 目录三个默认值；需要覆盖时写
`~/.config/herdr-bridge/env`（`EnvironmentFile=-` 可选加载，KEY=VALUE
每行一个），再 `systemctl --user restart herdr-bridge`。例如本机 8787
被占用时：

```bash
mkdir -p ~/.config/herdr-bridge
printf 'HERDR_BRIDGE_PORT=8878\n' > ~/.config/herdr-bridge/env
systemctl --user restart herdr-bridge
```

## 配置（CLI 与环境变量）

权威来源是 `bridge/src/config.rs` 的 `Cli`（clap derive）。每个环境变量都
有对应的 CLI 参数（kebab-case，如 `HERDR_BRIDGE_PORT` ↔ `--port`），优先级
**CLI > 环境变量 > 默认值**。列表类参数接受逗号分隔或重复传参；布尔参数
接受 `on/off`、`1/0`、`true/false`。类型或取值非法时启动即报错退出；
低于下限的数值 clamp 到下限并告警。环境变量值解析前会去除首尾空白，
空白值视为未设置。

```bash
# CLI 传参
herdr-bridge --port 8878 --multi-session off
# 等价的环境变量方式（systemd 部署推荐）
HERDR_BRIDGE_PORT=8878 HERDR_BRIDGE_MULTI_SESSION=off herdr-bridge
```

全部参数见 `herdr-bridge --help`；与下表一一对应：

| 变量 / CLI 参数 | 默认 | 说明 |
| --- | --- | --- |
| `HERDR_SOCKET_PATH` | `~/.config/herdr/herdr.sock`（遵循 `XDG_CONFIG_HOME`） | herdr API socket |
| `HERDR_BRIDGE_HOST` | `127.0.0.1` | 绑定地址 |
| `HERDR_BRIDGE_PORT` | `8787` | 绑定端口（min 1） |
| `HERDR_BRIDGE_STATE_DIR` | `~/.local/state/herdr-bridge`（遵循 `XDG_STATE_HOME`） | 状态目录（audit、activity、上传） |
| `HERDR_BRIDGE_POLL_MS` | `1500`（min 250） | 活跃轮询间隔 |
| `HERDR_BRIDGE_POLL_IDLE_MS` | `12000`（min 1000） | 空闲轮询间隔 |
| `HERDR_BRIDGE_READ_LINES` | `200`（min 1） | pane 读默认行数 |
| `HERDR_BRIDGE_SUBMIT_KEYS` | `Enter` | reply 提交键（逗号分隔） |
| `HERDR_BRIDGE_ALLOWED_ORIGINS` | 空 | 精确 origin 列表（逗号分隔） |
| `HERDR_BRIDGE_PUBLIC_HOSTS` | 空 | Host allowlist（逗号分隔） |
| `HERDR_BRIDGE_TRUSTED_USER` | 空 | Tailscale 身份 |
| `HERDR_BRIDGE_DEVICE_HEADER` | 空 | device gate 请求头名；设置后写端点要求该头 |
| `HERDR_BRIDGE_DEVICE_ALLOWLIST` | 空 | device 白名单（逗号分隔）；空 = 所有设备只读（fail-closed） |
| `HERDR_BRIDGE_MULTI_SESSION` | `on` | `off` 时只看 primary session |
| `HERDR_BRIDGE_TRANSCRIPT` | `on` | history 总开关 |
| `HERDR_BRIDGE_TRANSCRIPT_ROOT` | `~/.claude/projects`（逗号多 root） | claude 日志 root |
| `HERDR_BRIDGE_CODEX_ROOT` | `$CODEX_HOME/sessions` | codex 日志 root |
| `HERDR_BRIDGE_PI_ROOT` | `$PI_CODING_AGENT_DIR/sessions` | pi 日志 root |
| `HERDR_BRIDGE_OPENCODE_ROOT` | `$XDG_DATA_HOME/opencode` 或 `~/.local/share/opencode` | opencode 数据目录 |
| `HERDR_BRIDGE_EASYTIERSERCRET` | 空 | EasyTier 网络 secret；**设置后进入纯 EasyTier 模式**（见下节），不再监听 `HOST:PORT` |
| `HERDR_BRIDGE_EASYTIERSERVER` | 空 | EasyTier 中继/发现服务器地址（逗号分隔，如 `tcp://et.example.com:11010`） |
| `HERDR_BRIDGE_EASYTIERSERWORKNAME` | 空 | 覆盖网络名；缺省用 state 目录持久化的 uuid（`<state_dir>/easytier_network_id`，0600） |
| `HERDR_BRIDGE_EASYTIERSERVIRTUALIP` | 空 | 静态虚拟 IPv4（CIDR，如 `10.126.0.1/24`）；缺省 DHCP |

布尔值接受 `on/off`、`1/0`、`true/false`；CLI 侧同理（如 `--multi-session off`）。

## EasyTier 模式（远程访问）

设置 `HERDR_BRIDGE_EASYTIERSERCRET` 后，bridge 内嵌 EasyTier 实例加入一个
独立网络（network_name = 上述 uuid 或覆盖值），REST API 改从 EasyTier
**data plane** 的虚拟 TCP listener（`HERDR_BRIDGE_PORT`，默认 8787）接收
连接，不再监听 OS 端口；全程用户态，不需要 TUN/root。

```bash
# ~/.config/herdr-bridge/env 示例
HERDR_BRIDGE_EASYTIERSERCRET=你指定的secret
HERDR_BRIDGE_EASYTIERSERVER=tcp://et.example.com:11010
HERDR_BRIDGE_EASYTIERSERVIRTUALIP=10.126.0.1/24
```

重启后生成配对二维码（含 server/networkName/secret/virtualIp/port，app
扫码即连；二维码即网络钥匙，只在宿主机终端展示）：

```bash
herdr-bridge --show-qr
```

注意：`--show-qr` 要求显式配置 SERVER 与 VIRTUALIP（DHCP 分配的地址无法
在二维码生成前确定）。加密由 EasyTier 传输层承担（密钥从
network_name+secret 派生），中继服务器看不到明文；应用层 device gate
照旧生效。

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

设计细节见 `docs/superpowers/specs/2026-08-16-herdr-bridge-rust-design.md`。
