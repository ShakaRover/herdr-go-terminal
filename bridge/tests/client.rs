mod common;

use herdr_bridge::herdr::client::HerdrClient;
use herdr_bridge::herdr::types::SessionSnapshot;

#[tokio::test]
async fn ping_and_snapshot_roundtrip() {
    let mut script = serde_json::Map::new();
    script.insert("ping".into(), serde_json::json!({
        "type": "pong", "version": "0.8.0", "protocol": 19,
        "capabilities": {"live_handoff": true, "detached_server_daemon": true}
    }));
    script.insert("session.snapshot".into(), serde_json::json!({
        "type": "session_snapshot",
        "snapshot": {
            "version": "0.8.0", "protocol": 19,
            "workspaces": [{"workspace_id": "w1", "number": 1, "label": "main",
                "focused": true, "pane_count": 1, "tab_count": 1,
                "active_tab_id": "w1:t1", "agent_status": "blocked"}],
            "tabs": [{"tab_id": "w1:t1", "workspace_id": "w1", "number": 1,
                "label": "", "focused": true, "pane_count": 1, "agent_status": "blocked"}],
            "panes": [{"pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1",
                "tab_id": "w1:t1", "focused": true, "cwd": "/tmp",
                "agent": "claude", "agent_status": "blocked", "revision": 12,
                "scroll": {"offset_from_bottom": 0, "max_offset_from_bottom": 40,
                           "viewport_rows": 24}}],
            "layouts": [], "agents": []
        }
    }));
    let mock = common::MockHerdr::start(script).await;
    let client = HerdrClient::new(mock.socket_path.clone());
    let pong = client.ping().await.unwrap();
    assert_eq!(pong.protocol, 19);
    let snap: SessionSnapshot = client.snapshot().await.unwrap();
    assert_eq!(snap.panes[0].pane_id, "w1:p1");
    assert_eq!(snap.panes[0].agent_status, herdr_bridge::herdr::types::AgentStatus::Blocked);
    // id 必须是 string，且每请求一条新连接（mock 每连接只回一次）。
    let reqs = mock.received("session.snapshot");
    assert!(reqs[0]["id"].is_string());
}

#[tokio::test]
async fn rpc_error_maps_to_typed_error() {
    let mut script = serde_json::Map::new();
    script.insert("pane.read".into(), serde_json::json!({
        "__error__": {"code": "pane_not_found", "message": "pane w9:p9 not found"}
    }));
    let mock = common::MockHerdr::start(script).await;
    let client = HerdrClient::new(mock.socket_path.clone());
    let err = client.pane_read("w9:p9", "recent", None, "ansi").await.unwrap_err();
    assert!(err.is_pane_not_found());
}

#[tokio::test]
async fn unknown_variant_detected() {
    let script = serde_json::Map::new(); // 空脚本 → invalid_request unknown variant
    let mock = common::MockHerdr::start(script).await;
    let client = HerdrClient::new(mock.socket_path.clone());
    let err = client.snapshot().await.unwrap_err();
    assert!(err.is_unknown_variant());
}
