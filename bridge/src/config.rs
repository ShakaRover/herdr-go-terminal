use std::env;
use std::path::PathBuf;
use std::sync::LazyLock;

use clap::Parser;

// 部分字段由后续任务（HTTP server、transcript 索引）消费，M1 阶段允许 dead_code。
#[allow(dead_code)]
#[derive(Debug, Clone)]
pub struct Config {
    pub host: String,
    pub port: u16,
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
#[command(name = "herdr-bridge", version = Config::build_id())]
pub struct Cli {
    /// 绑定地址
    #[arg(long, env = "HERDR_BRIDGE_HOST")]
    pub host: Option<String>,
    /// 绑定端口
    #[arg(long, env = "HERDR_BRIDGE_PORT")]
    pub port: Option<u16>,
    /// herdr API socket
    #[arg(long, env = "HERDR_SOCKET_PATH")]
    pub socket_path: Option<PathBuf>,
    /// 状态目录（audit、activity、上传）
    #[arg(long, env = "HERDR_BRIDGE_STATE_DIR")]
    pub state_dir: Option<PathBuf>,
    /// 活跃轮询间隔 ms（min 250）
    #[arg(long, env = "HERDR_BRIDGE_POLL_MS")]
    pub poll_ms: Option<u64>,
    /// 空闲轮询间隔 ms（min 1000）
    #[arg(long, env = "HERDR_BRIDGE_POLL_IDLE_MS")]
    pub poll_idle_ms: Option<u64>,
    /// pane 读默认行数（min 1）
    #[arg(long, env = "HERDR_BRIDGE_READ_LINES")]
    pub read_lines: Option<u32>,
    /// reply 提交键（可重复或逗号分隔）
    #[arg(long, env = "HERDR_BRIDGE_SUBMIT_KEYS", value_delimiter = ',')]
    pub submit_keys: Vec<String>,
    /// 精确 origin 列表（可重复或逗号分隔）
    #[arg(long, env = "HERDR_BRIDGE_ALLOWED_ORIGINS", value_delimiter = ',')]
    pub allowed_origins: Vec<String>,
    /// Host allowlist（可重复或逗号分隔）
    #[arg(long, env = "HERDR_BRIDGE_PUBLIC_HOSTS", value_delimiter = ',')]
    pub public_hosts: Vec<String>,
    /// Tailscale 身份
    #[arg(long, env = "HERDR_BRIDGE_TRUSTED_USER")]
    pub trusted_user: Option<String>,
    /// device gate 请求头名；设置后写端点要求该头
    #[arg(long, env = "HERDR_BRIDGE_DEVICE_HEADER")]
    pub device_header: Option<String>,
    /// device 白名单（可重复或逗号分隔）；空 = 所有设备只读（fail-closed）
    #[arg(long, env = "HERDR_BRIDGE_DEVICE_ALLOWLIST", value_delimiter = ',')]
    pub device_allowlist: Vec<String>,
    /// off 时只看 primary session（on/off/1/0/true/false）
    #[arg(long, env = "HERDR_BRIDGE_MULTI_SESSION", value_parser = parse_on_off)]
    pub multi_session: Option<bool>,
    /// history 总开关（on/off/1/0/true/false）
    #[arg(long, env = "HERDR_BRIDGE_TRANSCRIPT", value_parser = parse_on_off)]
    pub transcript: Option<bool>,
    /// claude 日志 root（可重复或逗号分隔）
    #[arg(long, env = "HERDR_BRIDGE_TRANSCRIPT_ROOT", value_delimiter = ',')]
    pub transcript_roots: Vec<PathBuf>,
    /// codex 日志 root
    #[arg(long, env = "HERDR_BRIDGE_CODEX_ROOT")]
    pub codex_root: Option<PathBuf>,
    /// pi 日志 root
    #[arg(long, env = "HERDR_PI_ROOT")]
    pub pi_root: Option<PathBuf>,
    /// opencode 数据目录
    #[arg(long, env = "HERDR_OPENCODE_ROOT")]
    pub opencode_root: Option<PathBuf>,
    /// EasyTier 中继/发现服务器地址（可重复或逗号分隔，如 tcp://et.example.com:11010）
    #[arg(long, env = "HERDR_BRIDGE_EASYTIERSERVER", value_delimiter = ',')]
    pub easytier_server: Vec<String>,
    /// EasyTier 网络 secret；设置后进入纯 EasyTier 模式，不再监听 HOST:PORT
    #[arg(long, env = "HERDR_BRIDGE_EASYTIERSERCRET")]
    pub easytier_secret: Option<String>,
    /// 覆盖网络名；缺省用 state 目录持久化的 uuid
    #[arg(long, env = "HERDR_BRIDGE_EASYTIERSERWORKNAME")]
    pub easytier_network_name: Option<String>,
    /// 静态虚拟 IPv4（CIDR，如 10.126.0.1/24）；缺省 DHCP
    #[arg(long, env = "HERDR_BRIDGE_EASYTIERSERVIRTUALIP")]
    pub easytier_virtual_ip: Option<String>,
    /// EasyTier 被动监听端口（默认 22023，tcp://0.0.0.0 无条件监听）
    #[arg(long, env = "HERDR_BRIDGE_EASYTIERLISTENPORT")]
    pub easytier_listen_port: Option<u16>,
    // 测试注入：在默认监听之外追加 passive listener（供对端实例直连回环端口）。
    #[doc(hidden)]
    #[arg(long, env = "HERDR_BRIDGE_EASYTIERSER_TEST_LISTENERS", value_delimiter = ',')]
    pub easytier_test_listeners: Vec<String>,
}

impl Cli {
    /// 仅从进程环境解析（忽略 argv）。供测试与库调用方使用。
    pub fn from_process_env() -> Self {
        sanitize_env();
        Self::parse_from(["herdr-bridge"])
    }
}
/// 解析前规范化进程环境：env 值 trim 后为空视为未设置（兼容旧
/// env_string 语义，避免 `HERDR_BRIDGE_PORT=` 之类被 clap 硬报错）。
pub fn sanitize_env() {
    for (k, v) in std::env::vars_os() {
        let Some(name) = k.to_str() else { continue };
        if !name.starts_with("HERDR_") {
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
    base.join("herdr-bridge")
}

impl Config {
    /// 单一来源：clap 同时消费 CLI 参数与同名环境变量（CLI 优先）。
    /// 非法值由 clap 硬报错退出（不再静默回退）；数值下限仍 clamp 并告警。
    pub fn from_cli(cli: &Cli) -> Self {
        let submit_keys = norm_list(cli.submit_keys.clone());
        let transcript_roots = if cli.transcript_roots.is_empty() {
            vec![home_dir().join(".claude").join("projects")]
        } else {
            cli.transcript_roots.iter().filter_map(|p| norm_path(p.clone())).collect()
        };
        Config {
            host: cli.host.clone().and_then(norm_string).unwrap_or_else(|| "127.0.0.1".into()),
            port: clamp_min(cli.port.unwrap_or(8787).into(), 1, "port") as u16,
            socket_path: cli.socket_path.clone().and_then(norm_path).unwrap_or_else(default_socket_path),
            state_dir: cli.state_dir.clone().and_then(norm_path).unwrap_or_else(default_state_dir),
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
            easytier_server: norm_list(cli.easytier_server.clone()),
            easytier_secret: cli.easytier_secret.clone().and_then(norm_string),
            easytier_network_name: cli.easytier_network_name.clone().and_then(norm_string),
            easytier_virtual_ip: cli.easytier_virtual_ip.clone().and_then(norm_string),
            easytier_listen_port: clamp_min(
                cli.easytier_listen_port.unwrap_or(22023).into(), 1, "easytier-listen-port") as u16,
            easytier_test_listeners: norm_list(cli.easytier_test_listeners.clone()),
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
        let path = self.state_dir.join("easytier_network_id");
        if let Ok(s) = std::fs::read_to_string(&path) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return Ok(s);
            }
        }
        let id = uuid::Uuid::new_v4().to_string();
        std::fs::create_dir_all(&self.state_dir)?;
        std::fs::write(&path, format!("{id}\n"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(id)
    }

    pub fn build_id() -> &'static str {
        static BUILD_ID: LazyLock<String> = LazyLock::new(|| {
            match option_env!("HERDR_BRIDGE_GIT_HASH") {
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
            "HERDR_BRIDGE_HOST", "HERDR_BRIDGE_PORT", "HERDR_SOCKET_PATH",
            "HERDR_BRIDGE_STATE_DIR", "HERDR_BRIDGE_POLL_MS",
            "HERDR_BRIDGE_POLL_IDLE_MS", "HERDR_BRIDGE_READ_LINES",
            "HERDR_BRIDGE_SUBMIT_KEYS", "HERDR_BRIDGE_ALLOWED_ORIGINS",
            "HERDR_BRIDGE_PUBLIC_HOSTS", "HERDR_BRIDGE_TRUSTED_USER",
            "HERDR_BRIDGE_DEVICE_HEADER", "HERDR_BRIDGE_DEVICE_ALLOWLIST",
            "HERDR_BRIDGE_MULTI_SESSION", "HERDR_BRIDGE_TRANSCRIPT",
            "HERDR_BRIDGE_TRANSCRIPT_ROOT", "HERDR_BRIDGE_CODEX_ROOT",
            "HERDR_BRIDGE_PI_ROOT", "HERDR_BRIDGE_OPENCODE_ROOT",
            "HERDR_BRIDGE_EASYTIERSERVER", "HERDR_BRIDGE_EASYTIERSERCRET",
            "HERDR_BRIDGE_EASYTIERSERWORKNAME", "HERDR_BRIDGE_EASYTIERSERVIRTUALIP",
            "HERDR_BRIDGE_EASYTIERLISTENPORT",
            "HERDR_BRIDGE_EASYTIERSER_TEST_LISTENERS",
        ] {
            env::remove_var(k);
        }
    }

    #[test]
    fn easytier_disabled_by_default() {
        let _g = tests_lock();
        clear();
        let c = Config::from_cli(&Cli::from_process_env());
        assert!(!c.easytier_enabled());
        assert!(c.easytier_server.is_empty());
        assert!(c.easytier_virtual_ip.is_none());
    }

    #[test]
    fn easytier_config_parsed() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDR_BRIDGE_EASYTIERSERVER", "tcp://a.example:11010, tcp://b.example:11010");
        env::set_var("HERDR_BRIDGE_EASYTIERSERCRET", "s3cret");
        env::set_var("HERDR_BRIDGE_EASYTIERSERVIRTUALIP", "10.126.0.1/24");
        let c = Config::from_cli(&Cli::from_process_env());
        assert!(c.easytier_enabled());
        assert_eq!(c.easytier_server, vec!["tcp://a.example:11010", "tcp://b.example:11010"]);
        assert_eq!(c.easytier_virtual_ip.as_deref(), Some("10.126.0.1/24"));
        assert_eq!(c.easytier_listen_port, 22023); // 默认监听端口
        env::set_var("HERDR_BRIDGE_EASYTIERLISTENPORT", "23000");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.easytier_listen_port, 23000);
    }

    #[test]
    fn easytier_test_listeners_parsed() {
        let _g = tests_lock();
        clear();
        let c = Config::from_cli(&Cli::from_process_env());
        assert!(c.easytier_test_listeners.is_empty());
        env::set_var("HERDR_BRIDGE_EASYTIERSER_TEST_LISTENERS", "tcp://127.0.0.1:15999, udp://127.0.0.1:16000");
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
        env::set_var("HERDR_BRIDGE_STATE_DIR", &dir);
        env::set_var("HERDR_BRIDGE_EASYTIERSERCRET", "s3cret");
        let c = Config::from_cli(&Cli::from_process_env());
        let id1 = c.easytier_network_id().unwrap();
        assert!(uuid::Uuid::parse_str(&id1).is_ok());
        let id2 = c.easytier_network_id().unwrap();
        assert_eq!(id1, id2); // 持久化后稳定
        // 覆盖优先
        env::set_var("HERDR_BRIDGE_EASYTIERSERWORKNAME", "override-net");
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
        assert_eq!(c.port, 8787);
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
        env::set_var("HERDR_BRIDGE_PORT", "not-a-number");
        assert!(Cli::try_parse_from(["herdr-bridge"]).is_err());
        clear();
        env::set_var("HERDR_BRIDGE_MULTI_SESSION", "maybe");
        assert!(Cli::try_parse_from(["herdr-bridge"]).is_err());
        // 新语义下非法 env 会让任何后续解析硬报错，必须清理现场。
        clear();
    }

    #[test]
    fn numeric_below_min_clamped() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDR_BRIDGE_POLL_MS", "10"); // 低于 min 250
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.poll_ms, 250);
    }

    #[test]
    fn lists_and_device_gate() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDR_BRIDGE_ALLOWED_ORIGINS", "https://a.example, https://b.example");
        env::set_var("HERDR_BRIDGE_DEVICE_HEADER", "x-device");
        env::set_var("HERDR_BRIDGE_DEVICE_ALLOWLIST", " phone , tablet ");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.allowed_origins, vec!["https://a.example", "https://b.example"]);
        assert_eq!(c.device_header.as_deref(), Some("x-device"));
        assert_eq!(c.device_allowlist, vec!["phone", "tablet"]);
    }

    #[test]
    fn cli_overrides_env() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDR_BRIDGE_PORT", "9000");
        let cli = Cli::parse_from(["herdr-bridge", "--port", "9999"]);
        let c = Config::from_cli(&cli);
        assert_eq!(c.port, 9999);
        assert_eq!(c.host, "127.0.0.1"); // 未指定的项回落 env/默认
    }

    #[test]
    fn env_used_when_no_cli() {
        let _g = tests_lock();
        clear();
        env::set_var("HERDR_BRIDGE_PORT", "9000");
        let c = Config::from_cli(&Cli::from_process_env());
        assert_eq!(c.port, 9000);
        clear();
    }

    #[test]
    fn cli_bool_and_lists() {
        let _g = tests_lock();
        clear();
        let cli = Cli::parse_from([
            "herdr-bridge", "--multi-session", "off",
            "--allowed-origins", "https://a.example, https://b.example",
        ]);
        let c = Config::from_cli(&cli);
        assert!(!c.multi_session);
        assert_eq!(c.allowed_origins, vec!["https://a.example", "https://b.example"]);
    }
}
