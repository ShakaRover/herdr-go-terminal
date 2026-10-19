use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::Context as _;
use easytier::common::config::{ConfigLoader, NetworkIdentity, PeerConfig, TomlConfigLoader};
use easytier::instance::factory::create_native_instance;
use easytier_core::gateway::{
    DataPlaneErrorKind, DataPlaneTcpListener, DataPlaneTcpStream,
};

use crate::config::Config;

/// 持有运行中的 EasyTier 实例，供 data-plane listener 在 net 代际更换后重 bind。
pub struct EasyTierNet {
    pub instance: Arc<easytier::instance::factory::NativeCoreInstance>,
    /// 首个 data-plane TCP listener（启动时已 bind）。
    first_listener: std::sync::Mutex<Option<DataPlaneTcpListener>>,
    /// bridge REST 在虚拟网内的监听端口（重 bind 用）。
    port: u16,
    pub virtual_addr: SocketAddr,
    /// 实例加入的网络名（env 覆盖或持久化 uuid），配对/测试组网用。
    pub network_name: String,
}

impl EasyTierNet {
    /// 取出可自愈的 data-plane listener（只能取一次），交给 axum 服务。
    pub fn take_listener(&self) -> anyhow::Result<DataPlaneListener> {
        let inner = self
            .first_listener
            .lock()
            .unwrap()
            .take()
            .context("data-plane listener already taken")?;
        Ok(DataPlaneListener {
            current: inner,
            instance: self.instance.clone(),
            port: self.port,
        })
    }
}

/// 适配 axum::serve 的 data-plane TCP listener。
///
/// 断网/虚拟网变化时 EasyTier 会关闭旧 net，listener 的 accept 随之永久返回
/// 永久错误（NetworkChanged/HandleClosed/InstanceStopped → BrokenPipe）。
/// 检测到这类错误时对同一端口重新 `data_plane_tcp_bind` 拿新一代 listener
/// 继续 accept，bridge 进程无需重启即可自愈；其余 accept 错误按临时失败重试。
pub struct DataPlaneListener {
    current: DataPlaneTcpListener,
    instance: Arc<easytier::instance::factory::NativeCoreInstance>,
    port: u16,
}

/// 该 accept 错误是否表示底层 net 已永久关闭（需重 bind 而非重试）。
fn is_dead_listener(e: &std::io::Error) -> bool {
    e.get_ref()
        .and_then(|inner| inner.downcast_ref::<easytier_core::gateway::DataPlaneError>())
        .is_some_and(|de| {
            matches!(
                de.kind(),
                DataPlaneErrorKind::NetworkChanged
                    | DataPlaneErrorKind::HandleClosed
                    | DataPlaneErrorKind::InstanceStopped
            )
        })
}

impl DataPlaneListener {
    /// 重新 bind 当前这代 net 的同一端口，换掉死掉的 listener。
    async fn rebind(&mut self) -> anyhow::Result<()> {
        let fresh = self
            .instance
            .data_plane_tcp_bind(self.port, Duration::from_secs(15))
            .await
            .map_err(|e| anyhow::anyhow!("data-plane rebind {}: {e}", self.port))?;
        tracing::info!(%self.port, "data-plane listener rebound after net change");
        self.current = fresh;
        Ok(())
    }
}

impl axum::serve::Listener for DataPlaneListener {
    type Io = DataPlaneTcpStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            match self.current.accept().await {
                Ok(pair) => return pair,
                Err(e) => {
                    if is_dead_listener(&e) {
                        tracing::warn!(%e, "data-plane listener dead (net changed), rebinding");
                        // 重 bind 失败（net 尚未就绪）退避重试，直到成功。
                        loop {
                            match self.rebind().await {
                                Ok(()) => break,
                                Err(re) => {
                                    tracing::warn!(error=%format!("{re:#}"), "data-plane rebind failed, retrying");
                                    tokio::time::sleep(Duration::from_millis(500)).await;
                                }
                            }
                        }
                        continue;
                    }
                    tracing::warn!(%e, "data-plane accept failed, retrying");
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<SocketAddr> {
        Ok(self.current.local_addr())
    }
}

/// 扫码配对的凭据载荷。server 是地址数组：首项为本机内网监听地址
/// `tcp://<内网IP>:<listen_port>`（UDP connect 探测失败时跳过该项），
/// 其后追加全部 easytier_server 中继。secret/virtual_ip/network_id 必填；
/// virtual_ip 未显式配置时由 config 缺省为固定静态值（bridge 静态、app
/// DHCP 避让），二维码里的拨号地址因此启动即确定。
pub fn pairing_payload(cfg: &Config) -> anyhow::Result<serde_json::Value> {
    let mut servers: Vec<String> = Vec::new();
    if let Some(ip) = lan_ipv4() {
        servers.push(format!("tcp://{ip}:{}", cfg.easytier_listen_port));
    } else {
        tracing::warn!("lan ipv4 probe failed, pairing payload carries relays only");
    }
    servers.extend(cfg.easytier_server.iter().cloned());
    let secret = cfg
        .easytier_secret
        .clone()
        .context("easytier secret not set (HERDRGOT_BRIDGE_SECRET)")?;
    let virtual_ip = cfg
        .easytier_virtual_ip
        .as_deref()
        .and_then(|s| s.split('/').next())
        .filter(|s| !s.is_empty())
        .context("easytier virtual ip not set (HERDRGOT_BRIDGE_EASYTIERSERVIRTUALIP)")?;
    let network_name = cfg.easytier_network_id().context("load network id")?;
    Ok(serde_json::json!({
        "v": 1,
        "server": servers,
        "networkName": network_name,
        "secret": secret,
        "virtualIp": virtual_ip,
        "port": cfg.http_port,
    }))
}

/// 生成人工展示用的二维码与可读摘要。
///
/// 用户明确要求终端同时显示可直接粘贴到 app 的配对字符串，因此这里会
/// 打印含 secret 的 compact JSON；二维码与字符串都等同凭据，只在宿主机
/// 私有终端展示。
pub fn pairing_output(cfg: &Config) -> anyhow::Result<String> {
    let payload = pairing_payload(cfg)?;
    let code = qrcode::QrCode::new(payload.to_string()).context("encode pairing qr")?;
    let image = code
        .render::<qrcode::render::unicode::Dense1x2>()
        .build();
    let virtual_ip = payload["virtualIp"].as_str().context("pairing virtual ip")?;
    let port = payload["port"].as_u64().context("pairing port")?;
    let network_name = payload["networkName"].as_str().context("pairing network name")?;
    let servers = payload["server"].as_array().context("pairing servers")?;
    let mut details = format!(
        "{image}\n\nPairing details\n  Bridge:  {virtual_ip}:{port}\n  Network: {network_name}\n  Routes:\n"
    );
    for server in servers {
        let server = server.as_str().context("pairing server")?;
        details.push_str(&format!("    - {server}\n"));
    }
    details.push_str("\nPairing string (paste into HerdrGoT):\n");
    details.push_str(&payload.to_string());
    details.push_str("\n\nThis string contains the network secret. Treat it like a password.\n");
    Ok(details)
}

/// 输出可直接粘贴到 app 的单行配对字符串（compact JSON）。
pub fn pairing_string_output(cfg: &Config) -> anyhow::Result<String> {
    let payload = pairing_payload(cfg)?;
    Ok(format!("{}\n", payload))
}

/// 输出机器可读的完整配对载荷。包含 secret，只供显式
/// `pair --json` 调试或手工导入使用。
pub fn pairing_json_output(cfg: &Config) -> anyhow::Result<String> {
    let payload = pairing_payload(cfg)?;
    let json = serde_json::to_string_pretty(&payload).context("encode pairing json")?;
    Ok(format!("{json}\n"))
}

/// 探测本机内网 IPv4：向 8.8.8.8:80 发 UDP connect（不产生实际流量），
/// 读回内核选路的本地源地址。返回 None 表示无可用非回环 IPv4。
pub fn lan_ipv4() -> Option<std::net::Ipv4Addr> {
    let sock = std::net::UdpSocket::bind((std::net::Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    sock.connect((std::net::Ipv4Addr::new(8, 8, 8, 8), 80)).ok()?;
    match sock.local_addr().ok()?.ip() {
        std::net::IpAddr::V4(v4) if !v4.is_loopback() => Some(v4),
        _ => None,
    }
}

/// 启动内嵌 EasyTier 实例，并在虚拟网络上绑定 data-plane TCP `cfg.http_port`。
pub async fn start_easytier(cfg: &Config) -> anyhow::Result<EasyTierNet> {
    let secret = cfg.easytier_secret.clone().context("easytier secret not set")?;
    let network_name = cfg.easytier_network_id().context("load network id")?;

    let config = TomlConfigLoader::default();
    config.set_network_identity(NetworkIdentity::new(network_name.clone(), secret));
    match &cfg.easytier_virtual_ip {
        Some(cidr) => config.set_ipv4(Some(cidr.parse().context("parse virtual ip")?)),
        None => config.set_dhcp(true),
    }
    if !cfg.easytier_server.is_empty() {
        let peers: anyhow::Result<Vec<PeerConfig>> = cfg
            .easytier_server
            .iter()
            .map(|u| {
                Ok(PeerConfig {
                    uri: u.parse().with_context(|| format!("parse peer uri {u}"))?,
                    peer_public_key: None,
                })
            })
            .collect();
        config.set_peers(peers?);
    }
    // 默认无条件监听 tcp://0.0.0.0:<listen_port>：被动监听利于 p2p 打洞，
    // 对端扫到的内网地址即指向该端口。easytier_test_listeners 作为额外注入。
    let default_listener = format!("tcp://0.0.0.0:{}", cfg.easytier_listen_port);
    let listeners: anyhow::Result<Vec<url::Url>> = std::iter::once(&default_listener)
        .chain(cfg.easytier_test_listeners.iter())
        .map(|u| u.parse().with_context(|| format!("parse listener uri {u}")))
        .collect();
    config.set_listeners(listeners?);
    let mut flags = config.get_flags();
    flags.no_tun = true;
    flags.disable_upnp = true;
    config.set_flags(flags);

    let instance = create_native_instance(config).context("create easytier instance")?;
    instance.start().await.context("start easytier instance")?;

    let listener = instance
        .data_plane_tcp_bind(cfg.http_port, Duration::from_secs(15))
        .await
        .map_err(|e| anyhow::anyhow!("data-plane bind {}: {e}", cfg.http_port))?;
    let virtual_addr = listener.local_addr();

    Ok(EasyTierNet {
        instance,
        first_listener: std::sync::Mutex::new(Some(listener)),
        port: cfg.http_port,
        virtual_addr,
        network_name,
    })
}

#[cfg(test)]
mod tests {
    use clap::Parser as _;

    // 验证 DataPlaneListener 满足 axum Listener 约束（编译期）。
    #[test]
    fn listener_impl_is_object_safe_enough() {
        fn assert_listener<T: axum::serve::Listener>() {}
        assert_listener::<super::DataPlaneListener>();
    }

    /// 清环境后构建 Config；relays 非空时写入 HERDRGOT_BRIDGE_SERVER。
    fn fresh_cfg(relays: &str) -> crate::config::Config {
        crate::config::tests::clear();
        if !relays.is_empty() {
            std::env::set_var("HERDRGOT_BRIDGE_SERVER", relays);
        }
        std::env::set_var(
            "HERDRGOT_BRIDGE_STATE_DIR",
            std::env::temp_dir().join(format!("herdr-qr-{}", uuid::Uuid::new_v4())),
        );
        std::env::set_var("HERDRGOT_BRIDGE_SECRET", "s3cret");
        std::env::set_var("HERDRGOT_BRIDGE_EASYTIERSERVIRTUALIP", "10.126.0.1/24");
        crate::config::Config::from_cli(&crate::config::Cli::from_process_env())
    }

    #[test]
    fn pairing_payload_shape() {
        let _g = crate::config::tests_lock();
        let cfg = fresh_cfg("tcp://et.example.com:11010");
        let v = super::pairing_payload(&cfg).unwrap();
        assert_eq!(v["v"], 1);
        // server 为数组：内网监听地址在前（若探测成功），中继在后。
        let servers = v["server"].as_array().unwrap();
        assert_eq!(servers.last().unwrap(), "tcp://et.example.com:11010");
        assert!(servers.len() <= 2);
        if let Some(ip) = super::lan_ipv4() {
            assert_eq!(
                servers.first().unwrap().as_str().unwrap(),
                format!("tcp://{ip}:22024")
            );
            assert_eq!(servers.len(), 2);
        } else {
            assert_eq!(servers.len(), 1);
        }
        assert_eq!(v["secret"], "s3cret");
        assert_eq!(v["virtualIp"], "10.126.0.1");
        assert_eq!(v["port"], 8787);
        assert!(uuid::Uuid::parse_str(v["networkName"].as_str().unwrap()).is_ok());
    }

    #[test]
    fn pairing_output_is_human_readable_and_includes_string() {
        let _g = crate::config::tests_lock();
        let cfg = fresh_cfg("tcp://et.example.com:11010");
        let output = super::pairing_output(&cfg).unwrap();
        assert!(output.contains('█'));
        assert!(output.contains("Pairing details"));
        assert!(output.contains("Bridge:  10.126.0.1:8787"));
        assert!(output.contains("Network:"));
        assert!(output.contains("- tcp://et.example.com:11010"));
        assert!(output.contains("Pairing string (paste into HerdrGoT)"));
        assert!(output.contains("\"secret\":\"s3cret\""));
        assert!(output.contains("Treat it like a password"));
    }

    #[test]
    fn pairing_string_output_is_single_line_json() {
        let _g = crate::config::tests_lock();
        let cfg = fresh_cfg("tcp://et.example.com:11010");
        let output = super::pairing_string_output(&cfg).unwrap();
        let trimmed = output.trim();
        assert!(trimmed.starts_with('{'));
        assert!(trimmed.ends_with('}'));
        assert!(!trimmed.contains('\n'));
        let v: serde_json::Value = serde_json::from_str(trimmed).unwrap();
        assert_eq!(v["v"], 1);
        assert_eq!(v["secret"], "s3cret");
    }

    #[test]
    fn pairing_json_output_contains_raw_payload() {
        let _g = crate::config::tests_lock();
        let cfg = fresh_cfg("tcp://et.example.com:11010");
        let output = super::pairing_json_output(&cfg).unwrap();
        assert!(output.contains("\"secret\": \"s3cret\""));
        assert!(output.contains("\"networkName\""));
        assert!(!output.contains('█'));
    }

    #[test]
    fn pairing_payload_server_list_variants() {
        let _g = crate::config::tests_lock();
        // 未显式指定中继：回落默认 txt://herdrgo.et-link.cc，追加在内网 IP 项后。
        let cfg = fresh_cfg("");
        let v = super::pairing_payload(&cfg).unwrap();
        let servers = v["server"].as_array().unwrap();
        let lan = super::lan_ipv4();
        let mut expect: Vec<String> = lan
            .map(|ip| vec![format!("tcp://{ip}:22024")])
            .unwrap_or_default();
        expect.push("txt://herdrgo.et-link.cc".to_string());
        assert_eq!(*servers, expect);
        // 多个中继：全部追加在内网 IP 项之后。
        let cfg = fresh_cfg("tcp://et1.example.com:11010,tcp://et2.example.com:11010");
        let v = super::pairing_payload(&cfg).unwrap();
        let servers: Vec<&str> = v["server"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s.as_str().unwrap())
            .collect();
        let mut expect: Vec<String> = lan
            .map(|ip| vec![format!("tcp://{ip}:22024")])
            .unwrap_or_default();
        expect.extend([
            "tcp://et1.example.com:11010".to_string(),
            "tcp://et2.example.com:11010".to_string(),
        ]);
        assert_eq!(servers, expect);
    }

    #[test]
    fn pairing_payload_requires_secret_and_defaults_ip() {
        let _g = crate::config::tests_lock();
        crate::config::tests::clear();
        std::env::set_var(
            "HERDRGOT_BRIDGE_STATE_DIR",
            std::env::temp_dir().join(format!("herdr-qr-{}", uuid::Uuid::new_v4())),
        );
        // 显式关闭 EasyTier（--secret ""）时报错。
        let off = crate::config::Cli::parse_from(["herdrgot-bridge", "--secret", ""]);
        assert!(super::pairing_payload(&crate::config::Config::from_cli(&off)).is_err());
        // 缺 virtual ip 时回退默认静态值，不再报错。
        std::env::set_var("HERDRGOT_BRIDGE_SECRET", "s3cret");
        let v = super::pairing_payload(&crate::config::Config::from_cli(
            &crate::config::Cli::from_process_env()))
        .unwrap();
        assert_eq!(v["virtualIp"], "10.126.0.1");
        // 显式配置优先。
        std::env::set_var("HERDRGOT_BRIDGE_EASYTIERSERVIRTUALIP", "10.126.0.9/24");
        let v = super::pairing_payload(&crate::config::Config::from_cli(
            &crate::config::Cli::from_process_env()))
        .unwrap();
        assert_eq!(v["virtualIp"], "10.126.0.9");
    }

    #[test]
    fn lan_ipv4_returns_non_loopback_v4() {
        let _g = crate::config::tests_lock();
        // 无外网路由的环境（CI 容器）允许返回 None；有值则必须非回环。
        if let Some(ip) = super::lan_ipv4() {
            assert!(!ip.is_loopback());
            assert!(!ip.is_unspecified());
        }
    }
}
