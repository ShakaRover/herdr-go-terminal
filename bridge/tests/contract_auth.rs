mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

fn cfg_with(f: impl FnOnce(&mut herdr_bridge::config::Config)) -> std::sync::Arc<herdr_bridge::config::Config> {
    let mut cfg = herdr_bridge::config::Config::from_cli(&herdr_bridge::config::Cli::from_process_env());
    f(&mut cfg);
    std::sync::Arc::new(cfg)
}

async fn app_with(cfg: std::sync::Arc<herdr_bridge::config::Config>)
    -> (axum::Router, tokio::sync::watch::Sender<bool>)
{
    let mock = common::MockHerdr::start(common::engine_script()).await;
    let mut c = (*cfg).clone();
    c.socket_path = mock.socket_path.clone();
    // 审计落在 tempdir（函数返回即清理），避免 cargo test 写进真实 state dir。
    let state_dir = tempfile::tempdir().unwrap();
    c.state_dir = state_dir.path().to_path_buf();
    let (state, sd) = herdr_bridge::http::test_app_state(std::sync::Arc::new(c)).await;
    (herdr_bridge::http::build_router(state), sd)
}

fn get(uri: &str, headers: &[(&str, &str)]) -> Request<Body> {
    let mut b = Request::builder().uri(uri);
    for (k, v) in headers { b = b.header(*k, *v); }
    b.body(Body::empty()).unwrap()
}

fn post(uri: &str, body: &str, headers: &[(&str, &str)]) -> Request<Body> {
    let mut b = Request::builder().method("POST").uri(uri)
        .header("content-type", "application/json");
    for (k, v) in headers { b = b.header(*k, *v); }
    b.body(Body::from(body.to_string())).unwrap()
}

#[tokio::test]
async fn write_without_origin_on_lan_is_rejected() {
    let (app, _sd) = app_with(cfg_with(|_| {})).await;
    // 无 Origin + Host 非 loopback → 403 origin_required（仅写端点）
    let res = app.clone().oneshot(post("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"enter\"]}",
        &[("host", "10.0.0.1:8787")])).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let e: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(e["code"], "origin_required");
    // 同样的请求 Host 是 loopback → 放行（502 说明过了门禁、倒在 mock 无脚本）
    let res2 = app.clone().oneshot(post("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"enter\"]}",
        &[("host", "127.0.0.1:8787")])).await.unwrap();
    assert_ne!(res2.status(), StatusCode::FORBIDDEN);
    // 读端点无 Origin 始终放行
    let res3 = app.oneshot(get("/api/v1/snapshot",
        &[("host", "10.0.0.1:8787")])).await.unwrap();
    assert_eq!(res3.status(), StatusCode::OK);
}

#[tokio::test]
async fn cross_origin_rejected_and_allowed() {
    let (app, _sd) = app_with(cfg_with(|c| {
        c.allowed_origins = vec!["https://phone.example".into()];
    })).await;
    // Origin host == Host → 同源放行
    let res = app.clone().oneshot(post("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"enter\"]}",
        &[("host", "10.0.0.1:8787"), ("origin", "http://10.0.0.1:8787")])).await.unwrap();
    assert_ne!(res.status(), StatusCode::FORBIDDEN);
    // Origin 整串在 allowlist → 放行
    let res2 = app.clone().oneshot(post("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"enter\"]}",
        &[("host", "10.0.0.1:8787"), ("origin", "https://phone.example")])).await.unwrap();
    assert_ne!(res2.status(), StatusCode::FORBIDDEN);
    // 其它 → 403 cross_origin_rejected
    let res3 = app.oneshot(post("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"enter\"]}",
        &[("host", "10.0.0.1:8787"), ("origin", "https://evil.example")])).await.unwrap();
    assert_eq!(res3.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn device_gate_write_only() {
    let (app, _sd) = app_with(cfg_with(|c| {
        c.device_header = Some("x-device".into());
        c.device_allowlist = vec!["phone".into()];
    })).await;
    // 无 device header：读放行（snapshot 带 device 字段 unauthorized），写 403
    let res = app.clone().oneshot(get("/api/v1/snapshot",
        &[("host", "127.0.0.1:8787")])).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(v["device"]["enforced"], true);
    assert_eq!(v["device"]["authorized"], false);
    let res2 = app.clone().oneshot(post("/api/v1/pane/w1:p1/keys",
        "{\"keys\":[\"enter\"]}",
        &[("host", "127.0.0.1:8787")])).await.unwrap();
    assert_eq!(res2.status(), StatusCode::FORBIDDEN);
    let b2 = axum::body::to_bytes(res2.into_body(), usize::MAX).await.unwrap();
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&b2).unwrap()["code"],
               "device_not_authorised");
    // 授权设备 → 过门禁
    let res3 = app.oneshot(post("/api/v1/pane/w1:p1/keys", "{\"keys\":[\"enter\"]}",
        &[("host", "127.0.0.1:8787"), ("x-device", "phone")])).await.unwrap();
    assert_ne!(res3.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn host_allowlist_fail_closed() {
    let (app, _sd) = app_with(cfg_with(|c| {
        c.public_hosts = vec!["phone.example".into()];
    })).await;
    let res = app.clone().oneshot(get("/api/v1/snapshot",
        &[("host", "evil.example")])).await.unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
    let res2 = app.oneshot(get("/api/v1/snapshot",
        &[("host", "phone.example")])).await.unwrap();
    assert_eq!(res2.status(), StatusCode::OK);
}
