mod common;

use std::time::Duration;
use herdrgot_bridge::herdr::client::HerdrClient;
use herdrgot_bridge::state::engine::StateEngine;

#[tokio::test]
async fn engine_polls_and_sorts_triage() {
    let mock = common::MockHerdr::start(common::engine_script()).await;
    let dir = tempfile::tempdir().unwrap();
    let ledger = herdrgot_bridge::state::activity::ActivityLedger::load(
        &dir.path().join("activity.json"));
    let engine = StateEngine::new(HerdrClient::new(mock.socket_path.clone()),
        250, 1000, ledger, "default".to_string());
    let (tx, rx) = tokio::sync::watch::channel(false);
    let e = engine.clone();
    let handle = tokio::spawn(async move { e.run(rx).await });
    // 等首轮 poll 完成
    for _ in 0..40 {
        if engine.current().connected { break; }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let view = engine.current();
    assert!(view.connected);
    assert_eq!(view.panes.len(), 3);
    let (agents, shells) = herdrgot_bridge::state::view::build_pane_wires(
        &view, &engine.activity_snapshot(), &engine.session_names(), &|_| false);
    assert_eq!(agents.len(), 2);
    assert_eq!(shells.len(), 1);
    assert_eq!(shells[0].kind.as_deref(), Some("shell"));
    assert_eq!(shells[0].agent, "shell");
    // triage：blocked 在 working 前；同 rank 按 workspaceNumber→paneId
    assert_eq!(agents[0].pane_id, "w1:p1");
    assert_eq!(agents[1].pane_id, "w1:p2");
    assert_eq!(agents[0].readable_lines, Some(64));
    assert_eq!(agents[0].workspace_label, "one");
    assert_eq!(agents[0].tab_label, None); // 空 label 不产 tabLabel
    tx.send(true).unwrap();
    handle.await.unwrap();
}

#[tokio::test]
async fn unknown_variant_falls_back_to_lists() {
    let mut script = serde_json::Map::new();
    // session.snapshot 缺席 → mock 回 invalid_request unknown variant
    script.insert("workspace.list".into(), serde_json::json!({"workspaces": []}));
    script.insert("tab.list".into(), serde_json::json!({"tabs": []}));
    script.insert("pane.list".into(), serde_json::json!({"panes": [
        {"pane_id": "w1:p1", "terminal_id": "t1", "workspace_id": "w1", "tab_id": "w1:t1",
         "focused": true, "cwd": "/b", "agent": "pi", "agent_status": "done", "revision": 1}
    ]}));
    let mock = common::MockHerdr::start(script).await;
    let dir = tempfile::tempdir().unwrap();
    let ledger = herdrgot_bridge::state::activity::ActivityLedger::load(
        &dir.path().join("activity.json"));
    let engine = StateEngine::new(HerdrClient::new(mock.socket_path.clone()),
        250, 1000, ledger, "default".to_string());
    let (tx, rx) = tokio::sync::watch::channel(false);
    let e = engine.clone();
    let handle = tokio::spawn(async move { e.run(rx).await });
    for _ in 0..40 {
        if engine.current().connected { break; }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert_eq!(engine.current().panes.len(), 1);
    // 降级是永久的：第二轮 poll 不再调 session.snapshot
    let before = mock.received("session.snapshot").len();
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(mock.received("session.snapshot").len(), before);
    assert!(mock.received("pane.list").len() >= 2);
    tx.send(true).unwrap();
    handle.await.unwrap();
}

#[tokio::test]
async fn engine_updates_ledger_on_status_transitions() {
    let mock = common::MockHerdr::start(common::engine_script()).await;
    let dir = tempfile::tempdir().unwrap();
    let ledger = herdrgot_bridge::state::activity::ActivityLedger::load(
        &dir.path().join("activity.json"));
    let engine = StateEngine::new(HerdrClient::new(mock.socket_path.clone()),
        250, 1000, ledger.clone(), "default".to_string());
    let (tx, rx) = tokio::sync::watch::channel(false);
    let e = engine.clone();
    let handle = tokio::spawn(async move { e.run(rx).await });
    for _ in 0..40 {
        if engine.current().connected { break; }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    // 首轮：三个 pane 全部首见种子化（activity_snapshot 已解 session 前缀）
    let (a1, s1) = engine.activity_snapshot().get("w1:p1").copied().unwrap();
    assert_eq!(a1, s1);
    engine.mark_seen("w1:p1");
    let (_, s2) = engine.activity_snapshot().get("w1:p1").copied().unwrap();
    assert!(s2 >= s1);
    tx.send(true).unwrap();
    handle.await.unwrap();
}

#[tokio::test]
async fn shutdown_flushes_ledger() {
    let mock = common::MockHerdr::start(common::engine_script()).await;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("activity.json");
    let ledger = herdrgot_bridge::state::activity::ActivityLedger::load(&path);
    let engine = StateEngine::new(HerdrClient::new(mock.socket_path.clone()),
        250, 1000, ledger.clone(), "default".to_string());
    let (tx, rx) = tokio::sync::watch::channel(false);
    let e = engine.clone();
    let handle = tokio::spawn(async move { e.run(rx).await });
    for _ in 0..40 {
        if engine.current().connected { break; }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    // mark_seen 只置 dirty（10s 去抖内不落盘），此刻文件不应存在
    engine.mark_seen("w1:p1");
    let (_, seen) = engine.activity_snapshot().get("w1:p1").copied().unwrap();
    assert!(!path.exists());
    tx.send(true).unwrap();
    handle.await.unwrap();
    // run() 返回前 flush：文件已写入，seenAt 不早于 note 时刻。
    // 落盘键带 session 前缀（default\u{1f}，SEP 为 Unit Separator）。
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    assert!(v["default\u{1f}w1:p1"]["seenAt"].as_u64().unwrap() >= seen);
}

#[tokio::test]
async fn extracts_claude_session_name_after_poll() {
    let mut script = common::engine_script();
    // engine_script 的 claude pane 是 w1:p1；visible read 回带横线名的文本。
    script.insert("pane.read:visible".into(), serde_json::json!({
        "read": {"text": "some output\n──────────────── my-feature ────────────────\n❯ \n"}
    }));
    let mock = common::MockHerdr::start(script).await;
    let engine = StateEngine::new(HerdrClient::new(mock.socket_path.clone()),
        250, 1000, herdrgot_bridge::state::activity::ActivityLedger::load(
            &tempfile::tempdir().unwrap().path().join("a.json")), "default".to_string());
    let (tx, rx) = tokio::sync::watch::channel(false);
    let e = engine.clone();
    let handle = tokio::spawn(async move { e.run(rx).await });
    // 等首轮 poll + visible read 提取完成
    for _ in 0..80 {
        if engine.session_names().contains_key("w1:p1") { break; }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let view = engine.current();
    let (agents, _) = herdrgot_bridge::state::view::build_pane_wires(
        &view, &engine.activity_snapshot(), &engine.session_names(), &|_| false);
    let claude = agents.iter().find(|a| a.pane_id == "w1:p1").unwrap();
    assert_eq!(claude.session_name.as_deref(), Some("my-feature"));
    // 发给 herdr 的是 visible + text（绝不 recent，否则会滚动操作者终端）
    let reads = mock.received("pane.read");
    assert!(!reads.is_empty());
    for r in &reads {
        assert_eq!(r["params"]["source"], "visible");
        assert_eq!(r["params"]["format"], "text");
        assert_eq!(r["params"]["lines"], 40);
    }
    // 只读 claude pane；codex(w1:p2) 与 shell(w2:p1) 不发 pane.read
    assert!(reads.iter().all(|r| r["params"]["pane_id"] == "w1:p1"));
    tx.send(true).unwrap();
    handle.await.unwrap();
}

#[tokio::test]
async fn registry_discovers_named_sessions() {
    // 布局：tmp/herdr.sock（primary=default）、tmp/sessions/work/herdr.sock
    let dir = tempfile::tempdir().unwrap();
    let primary_sock = dir.path().join("herdr.sock");
    let work_dir = dir.path().join("sessions").join("work");
    std::fs::create_dir_all(&work_dir).unwrap();
    let work_sock = work_dir.join("herdr.sock");
    // 两个 mock 各自绑一个 socket 路径
    let _m1 = common::MockHerdr::start_at(&primary_sock, common::engine_script()).await;
    let _m2 = common::MockHerdr::start_at(&work_sock, common::engine_script()).await;
    let mut cfg = herdrgot_bridge::config::Config::from_cli(&herdrgot_bridge::config::Cli::from_process_env());
    cfg.socket_path = primary_sock.clone();
    let registry = herdrgot_bridge::sessions::SessionRegistry::new(
        std::sync::Arc::new(cfg),
        herdrgot_bridge::state::activity::ActivityLedger::load(
            &dir.path().join("activity.json")));
    registry.refresh_once().await;
    assert!(registry.runtime(None).is_ok());
    assert!(registry.runtime(Some("work")).is_ok());
    let err = registry.runtime(Some("../evil")).unwrap_err();
    assert_eq!(err.status, axum::http::StatusCode::NOT_FOUND); // 不拼路径
    let names: Vec<String> = registry.summaries().iter().map(|s| s.name.clone()).collect();
    assert_eq!(names, vec!["default".to_string(), "work".to_string()]);
}

#[tokio::test]
async fn event_poke_triggers_fast_repoll() {
    let mut script = common::engine_script();
    script.insert("events.subscribe".into(), serde_json::json!({
        "__stream__": [
            {"event": "pane_agent_status_changed", "data": {"pane_id": "w1:p1"}}
        ]
    }));
    let mock = common::MockHerdr::start(script).await;
    let engine = StateEngine::new(HerdrClient::new(mock.socket_path.clone()), 60_000, 60_000,
        herdrgot_bridge::state::activity::ActivityLedger::load(
            &tempfile::tempdir().unwrap().path().join("a.json")), "default".to_string());
    let poker = herdrgot_bridge::herdr::events::EventPoker::new(
        HerdrClient::new(mock.socket_path.clone()), engine.clone());
    let (tx, rx) = tokio::sync::watch::channel(false);
    let (tx2, rx2) = tokio::sync::watch::channel(false);
    let e = engine.clone();
    let h1 = tokio::spawn(async move { e.run(rx).await });
    let h2 = tokio::spawn(async move { poker.run(rx2).await });
    // 等首轮 poll + 订阅建立 + 事件到达 + 去抖 200ms + 重 poll
    tokio::time::sleep(Duration::from_millis(1500)).await;
    // poll 周期是 60s，第二轮只可能由 poke 触发
    assert!(mock.received("session.snapshot").len() >= 2);
    let subs = mock.received("events.subscribe");
    let types: Vec<&str> = subs[0]["params"]["subscriptions"].as_array().unwrap()
        .iter().filter_map(|s| s["type"].as_str()).collect();
    assert!(types.contains(&"workspace.created"));
    assert!(types.contains(&"pane.agent_status_changed"));
    tx.send(true).unwrap();
    tx2.send(true).unwrap();
    h1.await.unwrap();
    h2.await.unwrap();
}
