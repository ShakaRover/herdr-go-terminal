use std::env;
use std::path::PathBuf;

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
    // 测试注入：让内嵌 EasyTier 实例被动监听（默认不监听，只主动连中继）。
    #[doc(hidden)]
    pub easytier_test_listeners: Vec<String>,
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

fn env_string(key: &str) -> Option<String> {
    env::var(key).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn env_u64(key: &str, default: u64, min: u64) -> u64 {
    match env_string(key).and_then(|v| v.parse::<u64>().ok()) {
        Some(v) if v >= min => v,
        Some(v) => {
            tracing::warn!("{key}={v} below minimum {min}, clamped");
            min
        }
        None => {
            if env_string(key).is_some() {
                tracing::warn!("{key} invalid, using default {default}");
            }
            default
        }
    }
}

fn env_bool(key: &str, default: bool) -> bool {
    match env_string(key).as_deref() {
        Some("off") | Some("0") | Some("false") => false,
        Some("on") | Some("1") | Some("true") => true,
        Some(other) => {
            tracing::warn!("{key}={other} invalid, using default {default}");
            default
        }
        None => default,
    }
}

fn env_list(key: &str) -> Vec<String> {
    env_string(key)
        .map(|v| v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default()
}

fn env_path(key: &str) -> Option<PathBuf> {
    env_string(key).map(PathBuf::from)
}

impl Config {
    pub fn from_env() -> Self {
        let socket_path = env_path("HERDR_SOCKET_PATH").unwrap_or_else(default_socket_path);
        let state_dir = env_path("HERDR_BRIDGE_STATE_DIR").unwrap_or_else(default_state_dir);
        let submit_keys = env_list("HERDR_BRIDGE_SUBMIT_KEYS");
        let transcript_roots = env_string("HERDR_BRIDGE_TRANSCRIPT_ROOT")
            .map(|v| v.split(',').map(|s| PathBuf::from(s.trim())).collect())
            .unwrap_or_else(|| vec![home_dir().join(".claude").join("projects")]);
        Config {
            host: env_string("HERDR_BRIDGE_HOST").unwrap_or_else(|| "127.0.0.1".into()),
            port: env_u64("HERDR_BRIDGE_PORT", 8787, 1) as u16,
            socket_path,
            state_dir,
            poll_ms: env_u64("HERDR_BRIDGE_POLL_MS", 1500, 250),
            poll_idle_ms: env_u64("HERDR_BRIDGE_POLL_IDLE_MS", 12000, 1000),
            read_lines: env_u64("HERDR_BRIDGE_READ_LINES", 200, 1) as u32,
            submit_keys: if submit_keys.is_empty() { vec!["Enter".into()] } else { submit_keys },
            allowed_origins: env_list("HERDR_BRIDGE_ALLOWED_ORIGINS"),
            public_hosts: env_list("HERDR_BRIDGE_PUBLIC_HOSTS"),
            trusted_user: env_string("HERDR_BRIDGE_TRUSTED_USER"),
            device_header: env_string("HERDR_BRIDGE_DEVICE_HEADER"),
            device_allowlist: env_list("HERDR_BRIDGE_DEVICE_ALLOWLIST"),
            multi_session: env_bool("HERDR_BRIDGE_MULTI_SESSION", true),
            transcript: env_bool("HERDR_BRIDGE_TRANSCRIPT", true),
            transcript_roots,
            codex_root: env_path("HERDR_BRIDGE_CODEX_ROOT"),
            pi_root: env_path("HERDR_BRIDGE_PI_ROOT"),
            opencode_root: env_path("HERDR_BRIDGE_OPENCODE_ROOT"),
            easytier_server: env_list("HERDR_BRIDGE_EASYTIERSERVER"),
            easytier_secret: env_string("HERDR_BRIDGE_EASYTIERSERCRET"),
            easytier_network_name: env_string("HERDR_BRIDGE_EASYTIERSERWORKNAME"),
            easytier_virtual_ip: env_string("HERDR_BRIDGE_EASYTIERSERVIRTUALIP"),
            easytier_test_listeners: env_list("HERDR_BRIDGE_EASYTIERSER_TEST_LISTENERS"),
        }
    }

    pub fn easytier_enabled(&self) -> bool {
        self.easytier_secret.is_some()
    }

    /// 网络名：env 覆盖优先；否则持久化在 state 目录的 uuid。
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

    pub fn build_id() -> String {
        match option_env!("HERDR_BRIDGE_GIT_HASH") {
            Some(h) => format!("{}+{}", env!("CARGO_PKG_VERSION"), h),
            None => env!("CARGO_PKG_VERSION").to_string(),
        }
    }
}

// 每个用例串行跑（env 是全局态）：用一个锁。供各模块 tests 复用。
#[cfg(test)]
pub(crate) fn tests_lock() -> std::sync::MutexGuard<'static, ()> {
    use std::sync::{Mutex, MutexGuard, OnceLock};

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    let guard: MutexGuard<'static, ()> = ENV_LOCK.get_or_init(|| Mutex::new(())).lock().unwrap();
    tests::clear();
    guard
}

#[cfg(test)]
mod tests {
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
            "HERDR_BRIDGE_EASYTIERSERVER", "HERDR_BRIDGE_EASYTIERSERCRET",
            "HERDR_BRIDGE_EASYTIERSERWORKNAME", "HERDR_BRIDGE_EASYTIERSERVIRTUALIP",
            "HERDR_BRIDGE_EASYTIERSER_TEST_LISTENERS",
        ] {
            env::remove_var(k);
        }
    }

    #[test]
    fn easytier_disabled_by_default() {
        let _g = tests_lock();
        let c = Config::from_env();
        assert!(!c.easytier_enabled());
        assert!(c.easytier_server.is_empty());
        assert!(c.easytier_virtual_ip.is_none());
    }

    #[test]
    fn easytier_config_parsed() {
        let _g = tests_lock();
        env::set_var("HERDR_BRIDGE_EASYTIERSERVER", "tcp://a.example:11010, tcp://b.example:11010");
        env::set_var("HERDR_BRIDGE_EASYTIERSERCRET", "s3cret");
        env::set_var("HERDR_BRIDGE_EASYTIERSERVIRTUALIP", "10.126.0.1/24");
        let c = Config::from_env();
        assert!(c.easytier_enabled());
        assert_eq!(c.easytier_server, vec!["tcp://a.example:11010", "tcp://b.example:11010"]);
        assert_eq!(c.easytier_virtual_ip.as_deref(), Some("10.126.0.1/24"));
    }

    #[test]
    fn easytier_test_listeners_parsed() {
        let _g = tests_lock();
        let c = Config::from_env();
        assert!(c.easytier_test_listeners.is_empty());
        env::set_var("HERDR_BRIDGE_EASYTIERSER_TEST_LISTENERS", "tcp://127.0.0.1:15999, udp://127.0.0.1:16000");
        let c = Config::from_env();
        assert_eq!(
            c.easytier_test_listeners,
            vec!["tcp://127.0.0.1:15999", "udp://127.0.0.1:16000"]
        );
    }

    #[test]
    fn easytier_network_id_persisted() {
        let _g = tests_lock();
        let dir = std::env::temp_dir().join(format!("herdr-test-{}", uuid::Uuid::new_v4()));
        env::set_var("HERDR_BRIDGE_STATE_DIR", &dir);
        env::set_var("HERDR_BRIDGE_EASYTIERSERCRET", "s3cret");
        let c = Config::from_env();
        let id1 = c.easytier_network_id().unwrap();
        assert!(uuid::Uuid::parse_str(&id1).is_ok());
        let id2 = c.easytier_network_id().unwrap();
        assert_eq!(id1, id2); // 持久化后稳定
        // 覆盖优先
        env::set_var("HERDR_BRIDGE_EASYTIERSERWORKNAME", "override-net");
        let c2 = Config::from_env();
        assert_eq!(c2.easytier_network_id().unwrap(), "override-net");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn defaults() {
        let _g = tests_lock();
        let c = Config::from_env();
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
    fn invalid_values_fall_back() {
        let _g = tests_lock();
        env::set_var("HERDR_BRIDGE_PORT", "not-a-number");
        env::set_var("HERDR_BRIDGE_POLL_MS", "10"); // 低于 min 250
        env::set_var("HERDR_BRIDGE_MULTI_SESSION", "maybe");
        let c = Config::from_env();
        assert_eq!(c.port, 8787);
        assert_eq!(c.poll_ms, 250);
        assert!(c.multi_session); // 非 off 即 on
    }

    #[test]
    fn lists_and_device_gate() {
        let _g = tests_lock();
        env::set_var("HERDR_BRIDGE_ALLOWED_ORIGINS", "https://a.example, https://b.example");
        env::set_var("HERDR_BRIDGE_DEVICE_HEADER", "x-device");
        env::set_var("HERDR_BRIDGE_DEVICE_ALLOWLIST", " phone , tablet ");
        let c = Config::from_env();
        assert_eq!(c.allowed_origins, vec!["https://a.example", "https://b.example"]);
        assert_eq!(c.device_header.as_deref(), Some("x-device"));
        assert_eq!(c.device_allowlist, vec!["phone", "tablet"]);
    }
}
