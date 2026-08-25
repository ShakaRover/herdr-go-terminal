use std::env;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::LazyLock;

use clap::{CommandFactory, Parser, Subcommand};

// 部分字段由后续任务（HTTP server、transcript 索引）消费，M1 阶段允许 dead_code。
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct Config {
    /// HTTP 直连模式的绑定地址（EasyTier 模式下不监听）。
    pub host: String,
    /// HTTP 直连模式的绑定端口（EasyTier 模式下不使用）。
    pub http_port: u16,
    pub socket_path: PathBuf,
    pub state_dir: PathBuf,
    pub poll_ms: u64,
    pub poll_idle_ms: u64,
    pub read_lines: u32,
    pub submit_keys: Vec<String>,
    pub allowed_origins: Vec<String>,
    pub public_hosts: Vec<String>,
    pub trusted_user: Option<String>,
    pub device_header: Option<String>,
    pub device_allowlist: Vec<String>,
    pub multi_session: bool,
    pub transcript: bool,
    pub transcript_roots: Vec<PathBuf>,
    pub codex_root: Option<PathBuf>,
    pub pi_root: Option<PathBuf>,
    pub opencode_root: Option<PathBuf>,
    pub easytier_server: Vec<String>,
    /// None = 显式关闭 EasyTier（--secret ""），走 HTTP 直连；Some = 纯 EasyTier 模式。
    pub easytier_secret: Option<String>,
    pub easytier_network_name: Option<String>,
    pub easytier_virtual_ip: Option<String>,
    /// EasyTier 被动监听端口（默认 22023，利于 p2p 打洞；配对二维码引用）。
    pub easytier_listen_port: u16,
    // 测试注入：在默认监听之外追加 passive listener（供对端实例直连回环端口）。
    #[doc(hidden)]
    pub easytier_test_listeners: Vec<String>,
}

/// herdr 的 REST 桥接服务（Rust / axum）
#[derive(Parser, Debug)]
#[command(name = "herdrgo-bridge", version = Config::build_id())]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<BridgeCommand>,

    /// 中继/发现服务器（可重复或逗号分隔，默认 txt://herdrgo.et-link.cc）
    #[arg(long, env = "HERDRGO_BRIDGE_SERVER", value_delimiter = ',')]
    pub server: Vec<String>,
    /// EasyTier 网络 secret；缺省自动生成并持久化到 state 目录，显式传空串关闭 EasyTier
    #[arg(long, env = "HERDRGO_BRIDGE_SECRET")]
    pub secret: Option<String>,
    /// EasyTier 被动监听端口（默认 22023，tcp://0.0.0.0 无条件监听）
    #[arg(long, env = "HERDRGO_BRIDGE_PORT")]
    pub port: Option<u16>,
    /// 显示全部高级选项后退出
    #[arg(long)]
    pub help_advance: bool,
    /// 绑定地址（仅 HTTP 直连模式；默认 EasyTier 模式下不监听）
    #[arg(long, env = "HERDRGO_BRIDGE_HOST", hide = true)]
    pub host: Option<String>,
    /// HTTP 直连模式的绑定端口（默认 8787；EasyTier 模式下不使用）
    #[arg(long, env = "HERDRGO_BRIDGE_HTTP_PORT", hide = true)]
    pub http_port: Option<u16>,
    /// herdr API socket
    #[arg(long, env = "HERDR_SOCKET_PATH", hide = true)]
    pub socket_path: Option<PathBuf>,
    /// 状态目录（audit、activity、上传）
    #[arg(long, env = "HERDRGO_BRIDGE_STATE_DIR", hide = true)]
    pub state_dir: Option<PathBuf>,
    /// 活跃轮询间隔 ms（min 250）
    #[arg(long, env = "HERDRGO_BRIDGE_POLL_MS", hide = true)]
    pub poll_ms: Option<u64>,
    /// 空闲轮询间隔 ms（min 1000）
    #[arg(long, env = "HERDRGO_BRIDGE_POLL_IDLE_MS", hide = true)]
    pub poll_idle_ms: Option<u64>,
    /// pane 读默认行数（min 1）
    #[arg(long, env = "HERDRGO_BRIDGE_READ_LINES", hide = true)]
    pub read_lines: Option<u32>,
    /// reply 提交键（可重复或逗号分隔）
    #[arg(long, env = "HERDRGO_BRIDGE_SUBMIT_KEYS", value_delimiter = ',', hide = true)]
    pub submit_keys: Vec<String>,
    /// 精确 origin 列表（可重复或逗号分隔）
    #[arg(long, env = "HERDRGO_BRIDGE_ALLOWED_ORIGINS", value_delimiter = ',', hide = true)]
    pub allowed_origins: Vec<String>,
    /// Host allowlist（可重复或逗号分隔）
    #[arg(long, env = "HERDRGO_BRIDGE_PUBLIC_HOSTS", value_delimiter = ',', hide = true)]
    pub public_hosts: Vec<String>,
    /// Tailscale 身份
    #[arg(long, env = "HERDRGO_BRIDGE_TRUSTED_USER", hide = true)]
    pub trusted_user: Option<String>,
    /// device gate 请求头名；设置后写端点要求该头（仅 HTTP 直连模式）
    #[arg(long, env = "HERDRGO_BRIDGE_DEVICE_HEADER", hide = true)]
    pub device_header: Option<String>,
    /// device 白名单（可重复或逗号分隔）；空 = 所有设备只读（fail-closed）
    #[arg(long, env = "HERDRGO_BRIDGE_DEVICE_ALLOWLIST", value_delimiter = ',', hide = true)]
    pub device_allowlist: Vec<String>,
    /// off 时只看 primary session（on/off/1/0/true/false）
    #[arg(long, env = "HERDRGO_BRIDGE_MULTI_SESSION", value_parser = parse_on_off, hide = true)]
    pub multi_session: Option<bool>,
    /// history 总开关（on/off/1/0/true/false）
    #[arg(long, env = "HERDRGO_BRIDGE_TRANSCRIPT", value_parser = parse_on_off, hide = true)]
    pub transcript: Option<bool>,
    /// claude 日志 root（可重复或逗号分隔）
    #[arg(long, env = "HERDRGO_BRIDGE_TRANSCRIPT_ROOT", value_delimiter = ',', hide = true)]
    pub transcript_roots: Vec<PathBuf>,
    /// codex 日志 root
    #[arg(long, env = "HERDRGO_BRIDGE_CODEX_ROOT", hide = true)]
    pub codex_root: Option<PathBuf>,
    /// pi 日志 root
    #[arg(long, env = "HERDRGO_BRIDGE_PI_ROOT", hide = true)]
    pub pi_root: Option<PathBuf>,
    /// opencode 数据目录
    #[arg(long, env = "HERDRGO_BRIDGE_OPENCODE_ROOT", hide = true)]
    pub opencode_root: Option<PathBuf>,
    /// 覆盖网络名；缺省用 state 目录持久化的 uuid
    #[arg(long, env = "HERDRGO_BRIDGE_EASYTIERSERWORKNAME", hide = true)]
    pub easytier_network_name: Option<String>,
    /// 静态虚拟 IPv4（CIDR，如 10.126.0.1/24）；缺省 10.126.0.1/24
    #[arg(long, env = "HERDRGO_BRIDGE_EASYTIERSERVIRTUALIP", hide = true)]
    pub easytier_virtual_ip: Option<String>,
    // 测试注入：在默认监听之外追加 passive listener（供对端实例直连回环端口）。
    #[doc(hidden)]
    #[arg(long, env = "HERDRGO_BRIDGE_EASYTIERSER_TEST_LISTENERS", value_delimiter = ',', hide = true)]
    pub easytier_test_listeners: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Subcommand)]
pub enum BridgeCommand {
    /// 显示手机扫码所需的二维码和配对 JSON 后退出
    Pair,
}

impl Cli {
    /// 仅从进程环境解析（忽略 argv）。供测试与库调用方使用。
    pub fn from_process_env() -> Self {
        sanitize_env();
        Self::parse_from(["herdrgo-bridge"])
    }

    /// 解析进程 argv。`--help` 只显示常用三项；`--help-advance` 打印完整
    /// 帮助（含隐藏的高级选项）后以 0 退出。
    pub fn parse_cli() -> Self {
        if let Err(error) = load_process_env_file() {
            eprintln!("load bridge environment file: {error:#}");
            std::process::exit(2);
        }
        sanitize_env();
        let cli = Self::parse();
        if cli.help_advance {
            let mut cmd = Self::command().mut_args(|a| {
                if a.is_hide_set() { a.hide(false) } else { a }
            });
            cmd.print_long_help().expect("print --help-advance");
            println!();
            std::process::exit(0);
        }
        cli
    }
}

/// 从服务管理器指定的配置文件补充进程环境。已存在的进程环境保持优先，
/// 文件按 dotenv 的 `KEY=value` 语法解析，不执行 shell 代码。
pub fn load_process_env_file() -> anyhow::Result<()> {
    let Some(path) = env::var_os("HERDRGO_BRIDGE_ENV_FILE")
        .map(PathBuf::from)
        .and_then(norm_path)
    else {
        return Ok(());
    };
    dotenvy::from_path(&path)
        .map_err(|_| anyhow::anyhow!("cannot parse {}", path.display()))?;
    Ok(())
}
/// 解析前规范化进程环境：env 值 trim 后为空视为未设置（兼容旧
/// env_string 语义，避免 `HERDRGO_BRIDGE_PORT=` 之类被 clap 硬报错）。
/// 覆盖本组件的 HERDRGO_BRIDGE_* 与上游接口 HERDR_SOCKET_PATH。
pub fn sanitize_env() {
    for (k, v) in std::env::vars_os() {
        let Some(name) = k.to_str() else { continue };
        if !name.starts_with("HERDRGO_BRIDGE_") && !name.starts_with("HERDR_") {
            continue;
        }
        let Ok(s) = v.into_string() else { continue };
        let t = s.trim();
        if t.is_empty() {
            std::env::remove_var(name);
        } else if t.len() != s.len() {
            std::env::set_var(name, t);
        }
    }
}

fn parse_on_off(s: &str) -> Result<bool, String> {
    match s {
        "on" | "1" | "true" => Ok(true),
        "off" | "0" | "false" => Ok(false),
        _ => Err(format!("invalid bool token: {s}")),
    }
}

/// 去除首尾空白；空白串视为未设置（与旧 env_string 语义一致）。
fn norm_string(s: String) -> Option<String> {
    let t = s.trim().to_string();
    (!t.is_empty()).then_some(t)
}

fn norm_list(items: Vec<String>) -> Vec<String> {
    items.into_iter().filter_map(norm_string).collect()
}

fn norm_path(p: PathBuf) -> Option<PathBuf> {
    match p.to_str() {
        Some(s) => {
            let t = s.trim();
            (!t.is_empty()).then(|| PathBuf::from(t))
        }
        // 非 UTF-8 路径原样保留
        None => Some(p),
    }
}

fn clamp_min(v: u64, min: u64, key: &str) -> u64 {
    if v < min {
        tracing::warn!("{key}={v} below minimum {min}, clamped");
        min
    } else {
        v
    }
}

pub fn home_dir() -> PathBuf {
    env::home_dir().expect("cannot determine home directory")
}

pub fn default_socket_path() -> PathBuf {
    let base = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".config"));
    base.join("herdr").join("herdr.sock")
}

pub fn default_state_dir() -> PathBuf {
    let base = env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".local").join("state"));
    base.join("herdrgo-bridge")
}

/// 默认 EasyTier 中继/发现服务器（--server 与 HERDRGO_BRIDGE_SERVER 均未设置时用）。
pub fn default_easytier_server() -> String {
    "txt://herdrgo.et-link.cc".to_string()
}

/// 默认静态虚拟 IPv4（未显式配置时用）。bridge 是虚拟网内唯一静态节点，
/// 手机端走 DHCP 自动避让；二维码里的拨号地址因此启动即确定。
pub fn default_easytier_virtual_ip() -> String {
    "10.126.0.1/24".to_string()
}

/// 读 state 目录里持久化的值；缺失或为空时用 `gen` 生成并原子写回（0600）。
/// 用于 secret / network id 这类"首次生成、之后稳定"的配置。跨进程
/// 文件锁保证 service 与 `pair` 同时首启时也只会提交一个值。
/// 生成且写盘失败时返回 None（调用方按报错处理，避免用每次不同的随机值组网）。
fn persist_or_generate(
    state_dir: &std::path::Path,
    name: &str,
    gen: impl FnOnce() -> String,
) -> Option<String> {
    std::fs::create_dir_all(state_dir).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(state_dir, std::fs::Permissions::from_mode(0o700)).ok()?;
    }

    let lock_path = state_dir.join(format!(".{name}.lock"));
    let mut lock_options = OpenOptions::new();
    lock_options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        lock_options.mode(0o600);
    }
    let lock_file = lock_options.open(lock_path).ok()?;
    lock_file.lock().ok()?;

    let path = state_dir.join(name);
    if let Ok(s) = std::fs::read_to_string(&path) {
        let s = s.trim().to_string();
        if !s.is_empty() {
            return Some(s);
        }
    }

    let v = gen();
    let temporary = state_dir.join(format!(".{name}.{}.tmp", uuid::Uuid::new_v4().simple()));
    let mut temporary_options = OpenOptions::new();
    temporary_options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        temporary_options.mode(0o600);
    }
    let write_result = (|| -> std::io::Result<()> {
        let mut temporary_file = temporary_options.open(&temporary)?;
        temporary_file.write_all(format!("{v}\n").as_bytes())?;
        temporary_file.sync_all()?;
        drop(temporary_file);
        std::fs::rename(&temporary, &path)
    })();
    if write_result.is_err() {
        std::fs::remove_file(&temporary).ok();
        return None;
    }
    Some(v)
}

impl Config {
    /// 单一来源：clap 同时消费 CLI 参数与同名环境变量（CLI 优先）。
    /// 非法值由 clap 硬报错退出（不再静默回退）；数值下限仍 clamp 并告警。
    /// secret 与 network id 一样做 state 目录持久化：显式传入优先，否则读
    /// 持久化值，首次运行生成随机值。显式传空串表示关闭 EasyTier（HTTP 直连）。
    pub fn from_cli(cli: &Cli) -> Self {
        let submit_keys = norm_list(cli.submit_keys.clone());
        let transcript_roots = if cli.transcript_roots.is_empty() {
            vec![home_dir().join(".claude").join("projects")]
        } else {
            cli.transcript_roots.iter().filter_map(|p| norm_path(p.clone())).collect()
        };
        let state_dir = cli.state_dir.clone().and_then(norm_path).unwrap_or_else(default_state_dir);
        let easytier_secret = match &cli.secret {
            // 显式传空串：关闭 EasyTier，走 HTTP 直连。
            Some(s) if s.trim().is_empty() => None,
            Some(s) => norm_string(s.clone()),
            None => persist_or_generate(&state_dir, "easytier_secret", || {
                uuid::Uuid::new_v4().simple().to_string()
            }),
        };
        let easytier_server = {
            let l = norm_list(cli.server.clone());
            if l.is_empty() { vec![default_easytier_server()] } else { l }
        };
        Config {
            host: cli.host.clone().and_then(norm_string).unwrap_or_else(|| "127.0.0.1".into()),
            http_port: clamp_min(cli.http_port.unwrap_or(8787).into(), 1, "http-port") as u16,
            socket_path: cli.socket_path.clone().and_then(norm_path).unwrap_or_else(default_socket_path),
            poll_ms: clamp_min(cli.poll_ms.unwrap_or(1500), 250, "poll-ms"),
            poll_idle_ms: clamp_min(cli.poll_idle_ms.unwrap_or(12000), 1000, "poll-idle-ms"),
            read_lines: clamp_min(cli.read_lines.unwrap_or(200).into(), 1, "read-lines") as u32,
            submit_keys: if submit_keys.is_empty() { vec!["Enter".into()] } else { submit_keys },
            allowed_origins: norm_list(cli.allowed_origins.clone()),
            public_hosts: norm_list(cli.public_hosts.clone()),
            trusted_user: cli.trusted_user.clone().and_then(norm_string),
            device_header: cli.device_header.clone().and_then(norm_string),
            device_allowlist: norm_list(cli.device_allowlist.clone()),
            multi_session: cli.multi_session.unwrap_or(true),
            transcript: cli.transcript.unwrap_or(true),
            transcript_roots,
            codex_root: cli.codex_root.clone().and_then(norm_path),
            pi_root: cli.pi_root.clone().and_then(norm_path),
            opencode_root: cli.opencode_root.clone().and_then(norm_path),
            easytier_server,
            easytier_secret,
            easytier_network_name: cli.easytier_network_name.clone().and_then(norm_string),
            easytier_virtual_ip: cli.easytier_virtual_ip.clone().and_then(norm_string)
                .or_else(|| Some(default_easytier_virtual_ip())),
            easytier_listen_port: clamp_min(
                cli.port.unwrap_or(22023).into(), 1, "port") as u16,
            easytier_test_listeners: norm_list(cli.easytier_test_listeners.clone()),
            state_dir,
        }
    }

    pub fn easytier_enabled(&self) -> bool {
        self.easytier_secret.is_some()
    }

    /// 网络名：配置覆盖优先；否则持久化在 state 目录的 uuid。
    pub fn easytier_network_id(&self) -> std::io::Result<String> {
        if let Some(n) = &self.easytier_network_name {
            return Ok(n.clone());
        }
        persist_or_generate(&self.state_dir, "easytier_network_id", || {
            uuid::Uuid::new_v4().to_string()
        }).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::Other, "persist easytier_network_id failed")
        })
    }

    pub fn build_id() -> &'static str {
        static BUILD_ID: LazyLock<String> = LazyLock::new(|| {
            match option_env!("HERDRGO_BRIDGE_GIT_HASH") {
                Some(h) => format!("{}+{}", env!("CARGO_PKG_VERSION"), h),
                None => env!("CARGO_PKG_VERSION").to_string(),
            }
        });
        &BUILD_ID
    }
}

// 每个用例串行跑（env 是全局态）：用一个锁。供各模块 tests 复用。
#[cfg(test)]
static TESTS_LOCK: LazyLock<std::sync::Mutex<()>> = LazyLock::new(|| std::sync::Mutex::new(()));

#[cfg(test)]
pub(crate) fn tests_lock() -> std::sync::MutexGuard<'static, ()> {
    match TESTS_LOCK.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::env;

    pub(crate) fn clear() {
        for k in [
            "HERDRGO_BRIDGE_HOST", "HERDRGO_BRIDGE_PORT", "HERDR_SOCKET_PATH",
            "HERDRGO_BRIDGE_HTTP_PORT", "HERDRGO_BRIDGE_SERVER",
            "HERDRGO_BRIDGE_SECRET",
            "HERDRGO_BRIDGE_ENV_FILE",
            "HERDRGO_BRIDGE_STATE_DIR", "HERDRGO_BRIDGE_POLL_MS",
            "HERDRGO_BRIDGE_POLL_IDLE_MS", "HERDRGO_BRIDGE_READ_LINES",
            "HERDRGO_BRIDGE_SUBMIT_KEYS", "HERDRGO_BRIDGE_ALLOWED_ORIGINS",
            "HERDRGO_BRIDGE_PUBLIC_HOSTS", "HERDRGO_BRIDGE_TRUSTED_USER",
            "HERDRGO_BRIDGE_DEVICE_HEADER", "HERDRGO_BRIDGE_DEVICE_ALLOWLIST",
            "HERDRGO_BRIDGE_MULTI_SESSION", "HERDRGO_BRIDGE_TRANSCRIPT",
            "HERDRGO_BRIDGE_TRANSCRIPT_ROOT", "HERDRGO_BRIDGE_CODEX_ROOT",
            "HERDRGO_BRIDGE_PI_ROOT", "HERDRGO_BRIDGE_OPENCODE_ROOT",
            "HERDRGO_BRIDGE_EASYTIERSERWORKNAME", "HERDRGO_BRIDGE_EASYTIERSERVIRTUALIP",
            "HERDRGO_BRIDGE_EASYTIERSER_TEST_LISTENERS",
        ] {
            env::remove_var(k);
        }
    }

    #[test]
    fn easytier_secret_generated_and_persisted_by_default() {
        let _g = tests_lock();
        clear();
        let dir = std::env::temp_dir().join(format!("herdr-test-{}", uuid::Uuid::new_v4()));
        env::set_var("HERDRGO_BRIDGE_STATE_DIR", &dir);
        // 默认（不设 secret）→ 自动生成并持久化，EasyTier 开启。
        let c = Config::from_cli(&Cli::from_process_env());
        assert!(c.easytier_enabled());
        let s1 = c.easytier_secret.clone().unwrap();
        assert!(uuid::Uuid::parse_str(&s1).is_ok(), "generated secret is a uuid");
        // 默认中继生效。
        assert_eq!(c.easytier_server, vec!["txt://herdrgo.et-link.cc"]);
        // 再次解析读回同一 secret（持久化稳定）。
        let c2 = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c2.easytier_secret.as_deref(), Some(s1.as_str()));
        // 显式 --secret 覆盖持久化值。
        env::set_var("HERDRGO_BRIDGE_SECRET", "explicit");
        let c3 = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c3.easytier_secret.as_deref(), Some("explicit"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn persisted_identity_is_stable_across_concurrent_process_equivalents() {
        let dir = std::env::temp_dir().join(format!("herdr-race-{}", uuid::Uuid::new_v4()));
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        let handles = (0..8)
            .map(|_| {
                let dir = dir.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    persist_or_generate(&dir, "identity", || {
                        std::thread::sleep(std::time::Duration::from_millis(50));
                        uuid::Uuid::new_v4().to_string()
                    })
                    .unwrap()
                })
            })
            .collect::<Vec<_>>();
        let values = handles.into_iter().map(|h| h.join().unwrap()).collect::<Vec<_>>();

        assert!(values.iter().all(|value| value == &values[0]));
        assert_eq!(
            std::fs::read_to_string(dir.join("identity")).unwrap().trim(),
            values[0]
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn process_env_file_fills_missing_values_without_overriding_env() {
        let _g = tests_lock();
        clear();
        let dir = std::env::temp_dir().join(format!("herdr-env-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("env");
        std::fs::write(
            &path,
            "HERDRGO_BRIDGE_SERVER=tcp://file.example:11010\n\
             HERDRGO_BRIDGE_PORT=23000\n",
        )
        .unwrap();
        env::set_var("HERDRGO_BRIDGE_ENV_FILE", &path);
        env::set_var("HERDRGO_BRIDGE_PORT", "24000");

        load_process_env_file().unwrap();

        assert_eq!(
            env::var("HERDRGO_BRIDGE_SERVER").unwrap(),
            "tcp://file.example:11010"
        );
        assert_eq!(env::var("HERDRGO_BRIDGE_PORT").unwrap(), "24000");
        clear();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn process_env_file_parse_error_does_not_echo_values() {
        let _g = tests_lock();
        clear();
        let dir = std::env::temp_dir().join(format!("herdr-env-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("env");
        std::fs::write(&path, "HERDRGO_BRIDGE_SECRET='do-not-log\n").unwrap();
        env::set_var("HERDRGO_BRIDGE_ENV_FILE", &path);

        let error = load_process_env_file().unwrap_err().to_string();

        assert!(error.contains(path.to_str().unwrap()));
        assert!(!error.contains("do-not-log"));
        clear();
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn pair_subcommand_is_parsed() {
        let cli = Cli::parse_from(["herdrgo-bridge", "pair"]);
        assert_eq!(cli.command, Some(BridgeCommand::Pair));
    }

    #[test]
    fn easytier_disabled_by_empty_secret() {
        let _g = tests_lock();
        clear();
        // 显式空串 → 关闭 EasyTier，走 HTTP 直连；sanitize_env 会移除空值，
        // 所以这里走 CLI argv 传入空串。
        let cli = Cli::parse_from(["herdrgo-bridge", "--secret", ""]);
        let c = Config::from_cli(&cli);
        assert!(!c.easytier_enabled());
        // HTTP 直连默认端口。
        assert_eq!(c.http_port, 8787);
    }

    #[test]
    fn easytier_virtual_ip_defaults_to_static() {
        let _g = tests_lock();
        clear();
        // 未显式配置时缺省固定静态地址，保证二维码里的拨号地址启动即确定。
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.easytier_virtual_ip.as_deref(), Some("10.126.0.1/24"));
        // 显式配置优先。
        env::set_var("HERDRGO_BRIDGE_EASYTIERSERVIRTUALIP", "10.126.0.9/24");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.easytier_virtual_ip.as_deref(), Some("10.126.0.9/24"));
    }

    #[test]
    fn easytier_config_parsed() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDRGO_BRIDGE_SERVER", "tcp://a.example:11010, tcp://b.example:11010");
        env::set_var("HERDRGO_BRIDGE_SECRET", "s3cret");
        env::set_var("HERDRGO_BRIDGE_EASYTIERSERVIRTUALIP", "10.126.0.1/24");
        let c = Config::from_cli(&Cli::from_process_env());
        assert!(c.easytier_enabled());
        assert_eq!(c.easytier_server, vec!["tcp://a.example:11010", "tcp://b.example:11010"]);
        assert_eq!(c.easytier_virtual_ip.as_deref(), Some("10.126.0.1/24"));
        assert_eq!(c.easytier_listen_port, 22023); // 默认监听端口
        env::set_var("HERDRGO_BRIDGE_PORT", "23000");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.easytier_listen_port, 23000);
    }

    #[test]
    fn easytier_test_listeners_parsed() {
        let _g = tests_lock();
        clear();
        let c = Config::from_cli(&Cli::from_process_env());
        assert!(c.easytier_test_listeners.is_empty());
        env::set_var("HERDRGO_BRIDGE_EASYTIERSER_TEST_LISTENERS", "tcp://127.0.0.1:15999, udp://127.0.0.1:16000");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(
            c.easytier_test_listeners,
            vec!["tcp://127.0.0.1:15999", "udp://127.0.0.1:16000"]
        );
    }

    #[test]
    fn easytier_network_id_persisted() {
        let _g = tests_lock();
        clear();
        let dir = std::env::temp_dir().join(format!("herdr-test-{}", uuid::Uuid::new_v4()));
        env::set_var("HERDRGO_BRIDGE_STATE_DIR", &dir);
        env::set_var("HERDRGO_BRIDGE_SECRET", "s3cret");
        let c = Config::from_cli(&Cli::from_process_env());
        let id1 = c.easytier_network_id().unwrap();
        assert!(uuid::Uuid::parse_str(&id1).is_ok());
        let id2 = c.easytier_network_id().unwrap();
        assert_eq!(id1, id2); // 持久化后稳定
        // 覆盖优先
        env::set_var("HERDRGO_BRIDGE_EASYTIERSERWORKNAME", "override-net");
        let c2 = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c2.easytier_network_id().unwrap(), "override-net");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn defaults() {
        let _g = tests_lock();
        clear();
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.host, "127.0.0.1");
        assert_eq!(c.http_port, 8787);
        assert_eq!(c.poll_ms, 1500);
        assert_eq!(c.poll_idle_ms, 12000);
        assert_eq!(c.read_lines, 200);
        assert_eq!(c.submit_keys, vec!["Enter".to_string()]);
        assert!(c.multi_session);
        assert!(c.transcript);
        assert!(c.device_header.is_none());
    }

    #[test]
    fn invalid_values_rejected() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDRGO_BRIDGE_PORT", "not-a-number");
        assert!(Cli::try_parse_from(["herdrgo-bridge"]).is_err());
        clear();
        env::set_var("HERDRGO_BRIDGE_MULTI_SESSION", "maybe");
        assert!(Cli::try_parse_from(["herdrgo-bridge"]).is_err());
        // 新语义下非法 env 会让任何后续解析硬报错，必须清理现场。
        clear();
    }

    #[test]
    fn numeric_below_min_clamped() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDRGO_BRIDGE_POLL_MS", "10"); // 低于 min 250
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.poll_ms, 250);
    }

    #[test]
    fn lists_and_device_gate() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDRGO_BRIDGE_ALLOWED_ORIGINS", "https://a.example, https://b.example");
        env::set_var("HERDRGO_BRIDGE_DEVICE_HEADER", "x-device");
        env::set_var("HERDRGO_BRIDGE_DEVICE_ALLOWLIST", " phone , tablet ");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.allowed_origins, vec!["https://a.example", "https://b.example"]);
        assert_eq!(c.device_header.as_deref(), Some("x-device"));
        assert_eq!(c.device_allowlist, vec!["phone", "tablet"]);
    }

    #[test]
    fn cli_overrides_env() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDRGO_BRIDGE_PORT", "9000");
        let cli = Cli::parse_from(["herdrgo-bridge", "--port", "9999"]);
        let c = Config::from_cli(&cli);
        assert_eq!(c.easytier_listen_port, 9999);
        assert_eq!(c.host, "127.0.0.1"); // 未指定的项回落 env/默认
    }

    #[test]
    fn env_used_when_no_cli() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDRGO_BRIDGE_PORT", "9000");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.easytier_listen_port, 9000);
        clear();
    }

    #[test]
    fn cli_bool_and_lists() {
        let _g = tests_lock();
        clear();
        let cli = Cli::parse_from([
            "herdrgo-bridge", "--multi-session", "off",
            "--allowed-origins", "https://a.example, https://b.example",
        ]);
        let c = Config::from_cli(&cli);
        assert!(!c.multi_session);
        assert_eq!(c.allowed_origins, vec!["https://a.example", "https://b.example"]);
    }
}
