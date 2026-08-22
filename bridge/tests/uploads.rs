mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

async fn upload_app(state_dir: &std::path::Path)
    -> (axum::Router, tokio::sync::watch::Sender<bool>)
{
    let mock = common::MockHerdr::start(serde_json::Map::new()).await;
    let mut cfg = herdrgo_bridge::config::Config::from_cli(&herdrgo_bridge::config::Cli::from_process_env());
    cfg.socket_path = mock.socket_path.clone();
    cfg.state_dir = state_dir.to_path_buf();
    let (state, sd) = herdrgo_bridge::http::test_app_state(std::sync::Arc::new(cfg)).await;
    (herdrgo_bridge::http::build_router(state), sd)
}

fn multipart_body(field: &str, filename: &str, content_type: &str, data: &[u8]) -> (String, Vec<u8>) {
    let boundary = "testboundary123";
    let mut body = Vec::new();
    body.extend_from_slice(format!(
        "--{boundary}\r\ncontent-disposition: form-data; name=\"{field}\"; filename=\"{filename}\"\r\ncontent-type: {content_type}\r\n\r\n"
    ).as_bytes());
    body.extend_from_slice(data);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    (format!("multipart/form-data; boundary={boundary}"), body)
}

#[tokio::test]
async fn upload_saves_and_returns_host_path() {
    let dir = tempfile::tempdir().unwrap();
    let (app, _sd) = upload_app(dir.path()).await;
    let (ct, body) = multipart_body("file", "shot.png", "image/png", b"\x89PNG fake");
    let res = app.oneshot(Request::builder().method("POST")
        .uri("/api/v1/pane/w1:p1/upload")
        .header("content-type", ct)
        .header("host", "127.0.0.1:8787")
        .body(Body::from(body)).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(v["ok"], true);
    let path = v["path"].as_str().unwrap();
    assert!(path.starts_with(dir.path().join("uploads").to_str().unwrap()));
    assert!(path.contains("w1_p1-"));
    assert!(path.ends_with(".png"));
    assert_eq!(std::fs::read(path).unwrap(), b"\x89PNG fake");
}

#[tokio::test]
async fn upload_rejects_bad_mime_and_missing_file() {
    let dir = tempfile::tempdir().unwrap();
    let (app, _sd) = upload_app(dir.path()).await;
    let (ct, body) = multipart_body("file", "x.txt", "text/plain", b"hi");
    let res = app.clone().oneshot(Request::builder().method("POST")
        .uri("/api/v1/pane/w1:p1/upload")
        .header("content-type", ct).header("host", "127.0.0.1:8787")
        .body(Body::from(body)).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
    let (ct2, body2) = multipart_body("other", "x.png", "image/png", b"hi");
    let res2 = app.oneshot(Request::builder().method("POST")
        .uri("/api/v1/pane/w1:p1/upload")
        .header("content-type", ct2).header("host", "127.0.0.1:8787")
        .body(Body::from(body2)).unwrap()).await.unwrap();
    assert_eq!(res2.status(), StatusCode::BAD_REQUEST);
    let b2 = axum::body::to_bytes(res2.into_body(), usize::MAX).await.unwrap();
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&b2).unwrap()["code"], "no_file");
}

// 无 Content-Length 且 body 超过 DefaultBodyLimit(12MB)：MultipartError 须映射为
// 413 payload_too_large，而非 400（回归：contains("length limit") 探测已失效）。
#[tokio::test]
async fn upload_over_body_limit_returns_413() {
    let dir = tempfile::tempdir().unwrap();
    let (app, _sd) = upload_app(dir.path()).await;
    let (ct, body) = multipart_body("file", "big.png", "image/png",
        &vec![0u8; 12 * 1024 * 1024 + 1024]);
    let res = app.oneshot(Request::builder().method("POST")
        .uri("/api/v1/pane/w1:p1/upload")
        .header("content-type", ct).header("host", "127.0.0.1:8787")
        .body(Body::from(body)).unwrap()).await.unwrap();
    assert_eq!(res.status(), StatusCode::PAYLOAD_TOO_LARGE);
    let b = axum::body::to_bytes(res.into_body(), usize::MAX).await.unwrap();
    assert_eq!(serde_json::from_slice::<serde_json::Value>(&b).unwrap()["code"],
        "payload_too_large");
}

#[tokio::test]
async fn sweep_removes_old_files() {
    let dir = tempfile::tempdir().unwrap();
    let up = dir.path().join("uploads");
    std::fs::create_dir_all(&up).unwrap();
    let old = up.join("w1_p1-old-deadbeef.png");
    std::fs::write(&old, b"x").unwrap();
    // mtime 改为 49 小时前
    let past = std::time::SystemTime::now() - std::time::Duration::from_secs(49 * 3600);
    let ft: std::time::SystemTime = past;
    // 无 filetime crate：用 utimensat via libc 过重；改为暴露 sweep 的 now 参数做测试。
    let _ = ft;
    herdrgo_bridge::uploads::sweep_before(dir.path(), std::time::SystemTime::now()
        - std::time::Duration::from_secs(48 * 3600));
    assert!(old.exists()); // mtime 是新的，不删
    herdrgo_bridge::uploads::sweep_before(dir.path(), std::time::SystemTime::now()
        + std::time::Duration::from_secs(3600)); // 阈值在未来 → 全删
    assert!(!old.exists());
}
