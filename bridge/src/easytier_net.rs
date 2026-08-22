use std::{net::SocketAddr, sync::Arc, time::Duration};

use anyhow::Context as _;
use easytier::common::config::{ConfigLoader, NetworkIdentity, PeerConfig, TomlConfigLoader};
use easytier::instance::factory::create_native_instance;
use easytier_core::gateway::{DataPlaneTcpListener, DataPlaneTcpStream};

use crate::config::Config;

/// 持有运行中的 EasyTier 实例与其 data-plane TCP listener。
pub struct EasyTierNet {
    pub instance: Arc<easytier::instance::factory::NativeCoreInstance>,
    // 同一端口不能 bind 两次，listener 在启动时创建，移交所有权给 axum serve。
    listener: std::sync::Mutex<Option<DataPlaneTcpListener>>,
    pub virtual_addr: SocketAddr,
    /// 实例加入的网络名（env 覆盖或持久化 uuid），配对/测试组网用。
    pub network_name: String,
}

impl EasyTierNet {
    /// 取出 data-plane listener（只能取一次），交给 axum 服务。
    pub fn take_listener(&self) -> anyhow::Result<DataPlaneListener> {
        let inner = self
            .listener
            .lock()
            .unwrap()
            .take()
            .context("data-plane listener already taken")?;
        Ok(DataPlaneListener { inner })
    }
}

/// 适配 axum::serve 的 data-plane TCP listener。
pub struct DataPlaneListener {
    inner: DataPlaneTcpListener,
}

impl axum::serve::Listener for DataPlaneListener {
    type Io = DataPlaneTcpStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            match self.inner.accept().await {
                Ok(pair) => return pair,
                Err(e) => {
                    tracing::warn!(%e, "data-plane accept failed, retrying");
                    tokio::time::sleep(Duration::from_millis(200)).await;
                }
            }
        }
    }

    fn local_addr(&self) -> std::io::Result<SocketAddr> {
        Ok(self.inner.local_addr())
    }
}

/// 扫码配对的凭据载荷。server 取第一个 easytier_server，virtualIp 截掉 CIDR 后缀；
/// 两者缺失时报错（二维码要求显式配置，避免打印 DHCP 之后才确定的错误地址）。
pub fn pairing_payload(cfg: &Config) -> anyhow::Result<serde_json::Value> {
    let server = cfg
        .easytier_server
        .first()
        .context("easytier server not set (HERDR_BRIDGE_EASYTIERSERVER)")?;
    let secret = cfg
        .easytier_secret
        .clone()
        .context("easytier secret not set (HERDR_BRIDGE_EASYTIERSERCRET)")?;
    let virtual_ip = cfg
        .easytier_virtual_ip
        .as_deref()
        .and_then(|s| s.split('/').next())
        .filter(|s| !s.is_empty())
        .context("easytier virtual ip not set (HERDR_BRIDGE_EASYTIERSERVIRTUALIP)")?;
    let network_name = cfg.easytier_network_id().context("load network id")?;
    Ok(serde_json::json!({
        "v": 1,
        "server": server,
        "networkName": network_name,
        "secret": secret,
        "virtualIp": virtual_ip,
        "port": cfg.port,
    }))
}

/// 启动内嵌 EasyTier 实例，并在虚拟网络上绑定 data-plane TCP `cfg.port`。
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
    if cfg.easytier_test_listeners.is_empty() {
        config.set_listeners(Vec::new()); // 不被动监听，只主动连中继
    } else {
        // 测试注入：监听本地回环端口，供对端实例直连。
        let listeners: anyhow::Result<Vec<url::Url>> = cfg
            .easytier_test_listeners
            .iter()
            .map(|u| u.parse().with_context(|| format!("parse listener uri {u}")))
            .collect();
        config.set_listeners(listeners?);
    }
    let mut flags = config.get_flags();
    flags.no_tun = true;
    flags.disable_upnp = true;
    config.set_flags(flags);

    let instance = create_native_instance(config).context("create easytier instance")?;
    instance.start().await.context("start easytier instance")?;

    let listener = instance
        .data_plane_tcp_bind(cfg.port, Duration::from_secs(15))
        .await
        .map_err(|e| anyhow::anyhow!("data-plane bind {}: {e}", cfg.port))?;
    let virtual_addr = listener.local_addr();

    Ok(EasyTierNet {
        instance,
        listener: std::sync::Mutex::new(Some(listener)),
        virtual_addr,
        network_name,
    })
}

#[cfg(test)]
mod tests {
    // 验证 DataPlaneListener 满足 axum Listener 约束（编译期）。
    #[test]
    fn listener_impl_is_object_safe_enough() {
        fn assert_listener<T: axum::serve::Listener>() {}
        assert_listener::<super::DataPlaneListener>();
    }

    #[test]
    fn pairing_payload_shape() {
        let _g = crate::config::tests_lock();
        crate::config::tests::clear();
        std::env::set_var(
            "HERDR_BRIDGE_STATE_DIR",
            std::env::temp_dir().join(format!("herdr-qr-{}", uuid::Uuid::new_v4())),
        );
        std::env::set_var("HERDR_BRIDGE_EASYTIERSERCRET", "s3cret");
        std::env::set_var("HERDR_BRIDGE_EASYTIERSERVER", "tcp://et.example.com:11010");
        std::env::set_var("HERDR_BRIDGE_EASYTIERSERVIRTUALIP", "10.126.0.1/24");
        let cfg = crate::config::Config::from_cli(&crate::config::Cli::from_process_env());
        let v = super::pairing_payload(&cfg).unwrap();
        assert_eq!(v["v"], 1);
        assert_eq!(v["server"], "tcp://et.example.com:11010");
        assert_eq!(v["secret"], "s3cret");
        assert_eq!(v["virtualIp"], "10.126.0.1");
        assert_eq!(v["port"], 8787);
        assert!(uuid::Uuid::parse_str(v["networkName"].as_str().unwrap()).is_ok());
    }

    #[test]
    fn pairing_payload_requires_explicit_server_and_ip() {
        let _g = crate::config::tests_lock();
        std::env::set_var("HERDR_BRIDGE_EASYTIERSERCRET", "s3cret");
        // 缺 server / virtual ip 时必须报错（避免打印 DHCP 之后才确定的错误地址）
        assert!(super::pairing_payload(&crate::config::Config::from_cli(
            &crate::config::Cli::from_process_env())).is_err());
        std::env::set_var("HERDR_BRIDGE_EASYTIERSERVER", "tcp://et.example.com:11010");
        assert!(super::pairing_payload(&crate::config::Config::from_cli(
            &crate::config::Cli::from_process_env())).is_err());
    }
}
