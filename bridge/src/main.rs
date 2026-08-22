use std::sync::Arc;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "herdrgo_bridge=info".into()),
        )
        .init();
    herdrgo_bridge::config::sanitize_env();
    let cli = herdrgo_bridge::config::Cli::parse_cli();
    let cfg = Arc::new(herdrgo_bridge::config::Config::from_cli(&cli));
    std::fs::create_dir_all(&cfg.state_dir).expect("create state dir");
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&cfg.state_dir, std::fs::Permissions::from_mode(0o700))
            .expect("chmod state dir");
    }
    tracing::info!(
        socket = %cfg.socket_path.display(),
        build = %herdrgo_bridge::config::Config::build_id(),
        "herdrgo-bridge starting"
    );
    let registry = herdrgo_bridge::sessions::SessionRegistry::new(
        cfg.clone(),
        herdrgo_bridge::state::activity::ActivityLedger::load(
            &cfg.state_dir.join("activity.json")));
    {
        let ping_client = herdrgo_bridge::herdr::client::HerdrClient::new(cfg.socket_path.clone());
        match ping_client.ping().await {
            Ok(p) => tracing::info!(version = %p.version, protocol = p.protocol, "herdr connected"),
            Err(e) => tracing::warn!("herdr ping failed: {e}; will retry via polling"),
        }
    }
    let (_tx, rx) = tokio::sync::watch::channel(false);
    {
        let registry = registry.clone();
        tokio::spawn(async move { registry.refresh_loop(rx).await });
    }
    // SIGTERM/SIGINT：直接 flush 账本并退出（serve 无优雅停机路径，
    // run() 的 flush 依赖 watch sender，此处不保证触发）。
    {
        let registry = registry.clone();
        tokio::spawn(async move {
            let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler");
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = term.recv() => {}
            }
            registry.flush_activity();
            std::process::exit(0);
        });
    }
    let state = herdrgo_bridge::http::AppState {
        cfg: cfg.clone(),
        registry,
        audit: Arc::new(herdrgo_bridge::audit::AuditLog::new(&cfg.state_dir)),
        journal: Arc::new(herdrgo_bridge::journal::JournalRegistry::new(&cfg)),
    };
    // uploads 清扫：启动一次 + 每 6h；独立 task，与 runtime 无关。
    {
        let sweep_dir = cfg.state_dir.clone();
        tokio::spawn(async move {
            loop {
                herdrgo_bridge::uploads::sweep(&sweep_dir);
                tokio::time::sleep(std::time::Duration::from_secs(6 * 3600)).await;
            }
        });
    }
    let app = herdrgo_bridge::http::build_router(state);
    if cfg.easytier_enabled() {
        // net 需活到 serve 返回之后再 drop（EasyTier 实例随 net 销毁而停止）。
        let net = herdrgo_bridge::easytier_net::start_easytier(&cfg).await.expect("start easytier");
        tracing::info!(%net.virtual_addr, "listening on easytier data plane");
        // 启动即打印配对二维码 + 明文 JSON；载荷生成失败（缺
        // secret/virtual_ip）只告警，不阻塞 bridge 启动。
        match herdrgo_bridge::easytier_net::pairing_payload(&cfg) {
            Ok(payload) => match qrcode::QrCode::new(payload.to_string()) {
                Ok(code) => {
                    let img = code.render::<qrcode::render::unicode::Dense1x2>().build();
                    println!("{img}");
                    println!("{}", serde_json::to_string_pretty(&payload).unwrap());
                }
                Err(e) => tracing::warn!("pairing qr encode failed: {e}"),
            },
            Err(e) => tracing::warn!("pairing payload unavailable: {e:#}"),
        }
        let listener = net.take_listener().expect("take listener");
        axum::serve(listener, app.into_make_service()).await.expect("serve");
        drop(net);
    } else {
        let addr = format!("{}:{}", cfg.host, cfg.http_port);
        let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
        tracing::info!(%addr, "listening");
        axum::serve(listener, app).await.expect("serve");
    }
}
