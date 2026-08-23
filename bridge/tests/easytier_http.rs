//! 双 EasyTier 实例 data-plane 端到端：bridge 端经 `start_easytier` 起服务
//! （静态 10.126.99.1/24 + 测试注入的 tcp listener），client 端直接用
//! easytier API 组网（10.126.99.2/24，add_connector 指向 bridge 端 listener），
//! 随后 `data_plane_tcp_connect` 打通 TCP 并发原始 HTTP 请求，验证真实
//! router 的 /api/v1/config 往返。
//!
//! 本测试进程独占 easytier 相关 env（其余集成测试不读这些变量），
//! 无需全局 env 锁。

use std::time::Duration;

use easytier::common::config::{ConfigLoader, NetworkIdentity, TomlConfigLoader};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

// 监听侧必须是 0.0.0.0：client 手动连接器会把 bind_device 的 socket 绑到
// 非 loopback 接口地址上（本机实测经 eth0 地址回环），listener 只挂 127.0.0.1
// 收不到这些连接；peer 地址用同一个 listener URL，与 EasyTier 自带
// portable_core_instances_connect_through_core_tcp_listener 范例的
// add_connector(running_listeners().pop()) 形态一致。
const BRIDGE_IP: &str = "10.126.99.1";
const NETWORK_SECRET: &str = "testsecret";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn http_over_data_plane() {
    // 端口全部动态挑选：本机可能跑着真实 bridge 服务，固定端口必然冲突。
    // 注意默认被动监听与测试 listener 必须是两个端口（都会进 listeners）。
    let listen_port = std::net::TcpListener::bind("0.0.0.0:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let test_port = std::net::TcpListener::bind("0.0.0.0:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let http_port = std::net::TcpListener::bind("0.0.0.0:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let bridge_listener = format!("tcp://0.0.0.0:{test_port}");

    // bridge 端：静态虚拟 IP + 测试 listener（Config::from_env 读取）
    let state_dir = tempfile::tempdir().unwrap();
    std::env::set_var("HERDRGO_BRIDGE_STATE_DIR", state_dir.path());
    std::env::set_var("HERDRGO_BRIDGE_SECRET", NETWORK_SECRET);
    std::env::set_var("HERDRGO_BRIDGE_PORT", listen_port.to_string());
    std::env::set_var("HERDRGO_BRIDGE_HTTP_PORT", http_port.to_string());
    std::env::set_var("HERDRGO_BRIDGE_EASYTIERSERVIRTUALIP", format!("{BRIDGE_IP}/24"));
    std::env::set_var("HERDRGO_BRIDGE_EASYTIERSER_TEST_LISTENERS", &bridge_listener);
    let cfg = herdrgo_bridge::config::Config::from_cli(&herdrgo_bridge::config::Cli::from_process_env());
    let net = herdrgo_bridge::easytier_net::start_easytier(&cfg).await.unwrap();
    assert_eq!(net.virtual_addr.ip().to_string(), BRIDGE_IP);
    let listener = net.take_listener().unwrap();

    // 真实 router + 真实 AppState（/api/v1/config 不碰 herdr socket，
    // registry refresh loop 连不上 socket 只会静默重试）。
    let (state, _shutdown) =
        herdrgo_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    let app = herdrgo_bridge::http::build_router(state);
    tokio::spawn(async move { axum::serve(listener, app.into_make_service()).await.unwrap() });

    // client 端：直接用 easytier API 组网，peer 直连 bridge 端 listener。
    // 用 add_connector 而非静态 peers：与 EasyTier 自带的
    // portable_core_instances_connect_through_core_tcp_listener 范例一致；
    // 本机实测静态 peers 的初始 connector 任务建立连接后不发握手包
    // （client 侧 2s connect timeout，与 listener 无关）。
    let config = TomlConfigLoader::default();
    config.set_network_identity(NetworkIdentity::new(
        net.network_name.clone(),
        NETWORK_SECRET.into(),
    ));
    config.set_ipv4(Some("10.126.99.2/24".parse().unwrap()));
    config.set_listeners(vec![]);
    let mut flags = config.get_flags();
    flags.no_tun = true;
    flags.disable_upnp = true;
    config.set_flags(flags);
    let client = easytier::instance::factory::create_native_instance(config).unwrap();
    client.start().await.unwrap();
    client.add_connector(bridge_listener.parse().unwrap()).unwrap();

    // 等路由收敛后打通 data-plane TCP（组网需数秒，给足 20s 重试窗口）。
    let mut stream = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            match client
                .data_plane_tcp_connect(
                    format!("{BRIDGE_IP}:{http_port}").parse().unwrap(),
                    Duration::from_secs(3),
                )
                .await
            {
                Ok(s) => break s,
                Err(_) => tokio::time::sleep(Duration::from_millis(500)).await,
            }
        }
    })
    .await
    .expect("connect timeout");

    stream
        .write_all(b"GET /api/v1/config HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).await.unwrap();
    let body = String::from_utf8_lossy(&buf);
    assert!(body.contains("200"), "{body}");
    assert!(body.contains("build"), "{body}");
}
