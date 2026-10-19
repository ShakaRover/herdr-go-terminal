use std::path::PathBuf;

use axum::body::Body;
use axum::extract::{Path, Query, State, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;

use crate::error::{security_headers, ApiError};
use crate::http::auth::{check_access, AccessLevel};
use crate::http::{AppState, SessionRuntime};
use crate::state::view::{build_pane_wires, TabView, WorkspaceView};

#[derive(Deserialize)]
pub struct SessionQuery {
    session: Option<String>,
}

fn build_headers() -> HeaderMap {
    let mut h = security_headers();
    h.insert("x-bridge-build", crate::config::Config::build_id().parse().unwrap());
    h
}

fn json_response(status: StatusCode, value: serde_json::Value) -> Response {
    let mut res = (status, axum::Json(value)).into_response();
    res.headers_mut().extend(build_headers());
    res
}

pub async fn get_config(State(state): State<AppState>) -> Response {
    let _ = state;
    json_response(StatusCode::OK, serde_json::json!({
        "push": false,
        "vapidPublicKey": "",
        "build": crate::config::Config::build_id(),
    }))
}

pub async fn get_snapshot(
    State(state): State<AppState>, headers: HeaderMap, Query(q): Query<SessionQuery>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Read)?;
    let rt = state.runtime(q.session.as_deref())?;
    let view = rt.engine.current();
    let (agents, shells) = build_pane_wires(
        &view, &rt.engine.activity_snapshot(), &rt.engine.session_names(),
        &|pane| state.journal.pane_has_session(pane));
    let sessions = state.registry.summaries();
    let workspaces: Vec<WorkspaceView> = {
        let mut v: Vec<_> = view.workspaces.iter().map(|w| WorkspaceView {
            workspace_id: w.workspace_id.clone(), number: w.number,
            label: w.label.clone(), focused: w.focused,
        }).collect();
        v.sort_by_key(|w| w.number);
        v
    };
    let tabs: Vec<TabView> = view.tabs.iter().map(|t| TabView {
        tab_id: t.tab_id.clone(), workspace_id: t.workspace_id.clone(),
        number: t.number, label: t.label.clone(), focused: t.focused,
    }).collect();
    let mut body = serde_json::json!({
        "bridge": if view.connected { "connected" } else { "disconnected" },
        "agents": agents,
        "shellPanes": shells,
        "workspaces": workspaces,
        "tabs": tabs,
        "sessions": sessions,
        "ts": now_ms(),
    });
    if device.enforced {
        body["device"] = serde_json::json!({
            "enforced": true, "device": device.device, "authorized": device.authorized,
        });
    }
    Ok(json_response(StatusCode::OK, body))
}

pub async fn get_agent_kinds(
    State(state): State<AppState>, headers: HeaderMap, Query(q): Query<SessionQuery>,
) -> Result<Response, ApiError> {
    check_access(&state.cfg, &headers, AccessLevel::Read)?;
    let rt = state.runtime(q.session.as_deref())?;
    let mut agents = rt.client.agent_kinds().await.map_err(|e| {
        if e.is_unknown_variant() {
            ApiError::new(
                StatusCode::BAD_GATEWAY,
                "herdr_upgrade_required",
                "creating agents requires Herdr 0.8.2 or newer",
            )
        } else {
            ApiError::herdr(&e)
        }
    })?;
    agents.sort();
    agents.dedup();
    Ok(json_response(StatusCode::OK, serde_json::json!({"agents": agents})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateAgentBody {
    name: Option<String>,
    kind: Option<String>,
    cwd: Option<String>,
    workspace_id: Option<String>,
    workspace_label: Option<String>,
    initial_prompt: Option<String>,
}

const AGENT_START_TIMEOUT_MS: u64 = 20_000;

fn required_text(
    value: Option<String>, field: &'static str, max_chars: usize,
) -> Result<String, ApiError> {
    let value = value.unwrap_or_default().trim().to_string();
    if value.is_empty() || value.chars().count() > max_chars {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "bad_request",
            format!("bad {field}"),
        ));
    }
    Ok(value)
}

fn valid_agent_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase())
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

fn created_json(created: &crate::herdr::types::CreatedPane) -> serde_json::Value {
    serde_json::json!({
        "workspaceId": created.workspace_id,
        "tabId": created.tab_id,
        "paneId": created.pane_id,
    })
}

fn created_error(
    code: &'static str,
    message: impl Into<String>,
    created: &crate::herdr::types::CreatedPane,
) -> ApiError {
    ApiError::new(StatusCode::BAD_GATEWAY, code, message)
        .with_extra("created", created_json(created))
}

pub async fn create_agent(
    State(state): State<AppState>, headers: HeaderMap, Query(q): Query<SessionQuery>,
    body: Result<axum::Json<CreateAgentBody>, axum::extract::rejection::JsonRejection>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    let axum::Json(body) = body.map_err(|_| ApiError::new(
        StatusCode::BAD_REQUEST, "bad_request", "invalid json body"))?;

    let name = required_text(body.name, "name", 32)?;
    if !valid_agent_name(&name) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "bad_request",
            "name must match [a-z][a-z0-9_-]{0,31}",
        ));
    }
    let kind = required_text(body.kind, "kind", 64)?;
    let cwd = required_text(body.cwd, "cwd", 4096)?;
    if !std::path::Path::new(&cwd).is_absolute() {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST, "bad_request", "cwd must be an absolute path"));
    }
    let workspace_id = body.workspace_id
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if workspace_id.as_ref().is_some_and(|value| value.chars().count() > 128) {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_request", "bad workspaceId"));
    }
    let workspace_label = body.workspace_label
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| name.clone());
    if workspace_label.chars().count() > 128 {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_request", "bad workspaceLabel"));
    }
    let initial_prompt = body.initial_prompt
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if initial_prompt.as_ref().is_some_and(|value| value.chars().count() > 100_000) {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_request", "initialPrompt too long"));
    }

    let kinds = rt.client.agent_kinds().await.map_err(|e| {
        if e.is_unknown_variant() {
            ApiError::new(
                StatusCode::BAD_GATEWAY,
                "herdr_upgrade_required",
                "creating agents requires Herdr 0.8.2 or newer",
            )
        } else {
            ApiError::herdr(&e)
        }
    })?;
    if !kinds.iter().any(|candidate| candidate == &kind) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "unsupported_agent_kind",
            format!("unsupported agent: {kind}"),
        ));
    }

    let created = match workspace_id.as_deref() {
        Some(workspace_id) => rt.client.create_tab(workspace_id, &cwd, &name).await,
        None => rt.client.create_workspace(&cwd, &workspace_label).await,
    }
    .map_err(|e| ApiError::herdr(&e))?;
    rt.engine.poke();

    if let Err(e) = rt.client
        .start_agent(&name, &kind, &created.pane_id, AGENT_START_TIMEOUT_MS)
        .await
    {
        state.audit.log(
            "create_agent_failed", Some(&created.pane_id), q.session.as_deref(),
            device.device.as_deref(), &format!("{kind} {name}: {e}"));
        return Err(created_error("agent_start_failed", e.to_string(), &created));
    }

    if let Some(prompt) = initial_prompt {
        if let Err(e) = rt.client.pane_send_text(&created.pane_id, &prompt).await {
            state.audit.log(
                "create_agent_failed", Some(&created.pane_id), q.session.as_deref(),
                device.device.as_deref(), &format!("{kind} {name}: initial prompt: {e}"));
            return Err(created_error("initial_prompt_failed", e.to_string(), &created));
        }
        tokio::time::sleep(std::time::Duration::from_millis(350)).await;
        if rt.client.pane_send_keys(&created.pane_id, &state.cfg.submit_keys).await.is_err() {
            state.audit.log(
                "create_agent_failed", Some(&created.pane_id), q.session.as_deref(),
                device.device.as_deref(), &format!("{kind} {name}: initial prompt submit failed"));
            return Err(ApiError::text_delivered().with_extra("created", created_json(&created)));
        }
    }

    state.audit.log(
        "create_agent", Some(&created.pane_id), q.session.as_deref(),
        device.device.as_deref(), &format!("{kind} {name} cwd={cwd}"));
    rt.engine.mark_seen(&created.pane_id);
    rt.engine.poke();
    Ok(json_response(StatusCode::CREATED, serde_json::json!({
        "ok": true,
        "agentName": name,
        "workspaceId": created.workspace_id,
        "tabId": created.tab_id,
        "paneId": created.pane_id,
    })))
}

#[derive(Deserialize)]
pub struct PaneReadQuery {
    session: Option<String>,
    lines: Option<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneStreamQuery {
    session: Option<String>,
    lines: Option<u32>,
    interval_ms: Option<u64>,
}

pub async fn stream_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<PaneStreamQuery>, ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    check_access(&state.cfg, &headers, AccessLevel::Read)?;
    let runtime = state.runtime(q.session.as_deref())?;
    let lines = q
        .lines
        .filter(|lines| *lines > 0)
        .map(|lines| lines.min(10_000))
        .unwrap_or(state.cfg.read_lines);
    maybe_mark_seen(&runtime, &headers, &id, false);
    let rate = crate::pane_stream::PaneStreamRate::from_interval_ms(q.interval_ms);
    Ok(ws.on_upgrade(move |socket| {
        crate::pane_stream::serve(socket, runtime, id, lines, rate)
    }))
}

pub async fn read_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<PaneReadQuery>,
) -> Result<Response, ApiError> {
    check_access(&state.cfg, &headers, AccessLevel::Read)?;
    let rt = state.runtime(q.session.as_deref())?;
    let lines = q.lines.filter(|l| *l > 0).map(|l| l.min(10000)).unwrap_or(state.cfg.read_lines);
    let read = rt.client
        .pane_read(&id, "recent", Some(lines), "ansi")
        .await
        .map_err(|e| ApiError::herdr(&e))?;
    maybe_mark_seen(&rt, &headers, &id, false);
    // ETag 基于未压缩 body（gzip 中间件在序列化之后，与 collie 一致）。
    let body = serde_json::to_string(&serde_json::json!({
        "paneId": id,
        "text": read.text,
        "truncated": read.truncated,
        "revision": read.revision,
    }))
    .map_err(|e| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR,
        "serialize_failed", format!("pane body serialize failed: {e}")))?;
    let etag = crate::http::etag::compute(&body);
    // json_response 不便复用（304 空 body + etag 回显），此处内联构造（控制器已批准）。
    let mut res = if crate::http::etag::matches(headers.get("if-none-match"), &etag) {
        (StatusCode::NOT_MODIFIED, Body::empty()).into_response()
    } else {
        (StatusCode::OK, [(axum::http::header::CONTENT_TYPE, "application/json")], body)
            .into_response()
    };
    res.headers_mut().extend(build_headers());
    res.headers_mut().insert("etag", etag.parse().unwrap());
    Ok(res)
}

#[derive(Deserialize)]
pub struct HistoryQuery {
    session: Option<String>,
    limit: Option<usize>,
    before: Option<String>,
}

pub async fn pane_history(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<HistoryQuery>,
) -> Result<Response, ApiError> {
    crate::http::auth::check_access(&state.cfg, &headers, crate::http::auth::AccessLevel::Read)?;
    let rt = state.runtime(q.session.as_deref())?;
    if headers.contains_key("x-bridge-seen") { rt.engine.mark_seen(&id); }
    let unavailable = |reason: &str| json_response(StatusCode::OK, serde_json::json!({
        "paneId": id, "available": false, "reason": reason,
    }));
    if !state.cfg.transcript { return Ok(unavailable("disabled")); }
    let view = rt.engine.current();
    let Some(pane) = view.panes.iter().find(|p| p.pane_id == id) else {
        return Ok(unavailable("no-session"));
    };
    let agent = pane.agent.as_deref().unwrap_or("");
    let Some(r) = state.journal.pane_session(pane) else {
        return Ok(unavailable("no-session"));
    };
    let limit = q.limit.filter(|l| *l > 0).map(|l| l.min(5000)).unwrap_or(200);
    let before = q.before.as_deref().filter(|b| b.len() <= 100);
    match state.journal.history(agent, &r, limit, before) {
        Ok(crate::journal::HistoryOutcome::Ok(page)) => {
            Ok(json_response(StatusCode::OK, serde_json::json!({
                "paneId": id, "available": true,
                "entries": page.entries, "hasMore": page.has_more,
                "total": page.total, "fileTruncated": page.file_truncated,
            })))
        }
        Ok(crate::journal::HistoryOutcome::Disabled) => Ok(unavailable("disabled")),
        Ok(crate::journal::HistoryOutcome::NoSession) => Ok(unavailable("no-session")),
        Ok(crate::journal::HistoryOutcome::NoLog) => Ok(unavailable("no-log")),
        Err(e) => Err(ApiError::new(StatusCode::BAD_GATEWAY,
            "transcript_read_failed", format!("transcript read failed: {e}"))),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplyBody {
    pub text: Option<String>,
    pub submit: Option<bool>,
    pub expected_prompt: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeysBody {
    pub keys: Option<Vec<String>>,
    pub expected_prompt: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResizeBody {
    pub cols: u16,
    pub rows: u16,
    pub lease_id: Option<String>,
}

fn validate_expected_prompt(ep: &Option<String>) -> Result<(), ApiError> {
    if let Some(s) = ep {
        if s.chars().count() > 8192 {
            return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_request", "bad expectedPrompt"));
        }
    }
    Ok(())
}

/// seen 副作用（spec §5.3）：写端点必标；读端点仅在带 `x-bridge-seen` 头时标。
fn maybe_mark_seen(rt: &SessionRuntime, headers: &HeaderMap, pane_id: &str, is_write: bool) {
    if is_write || headers.contains_key("x-bridge-seen") {
        rt.engine.mark_seen(pane_id);
    }
}

pub async fn reply_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<SessionQuery>, body: Result<axum::Json<ReplyBody>, axum::extract::rejection::JsonRejection>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    let axum::Json(body) = body.map_err(|_| ApiError::new(
        StatusCode::BAD_REQUEST, "bad_request", "invalid json body"))?;
    validate_expected_prompt(&body.expected_prompt)?;
    if let Some(ep) = &body.expected_prompt {
        crate::prompt::check_prompt_binding(&rt.client, &id, ep, state.cfg.read_lines).await?;
    }
    let text = body.text.unwrap_or_default();
    let submit = body.submit.unwrap_or(true);
    if !text.is_empty() {
        rt.client.pane_send_text(&id, &text).await.map_err(|e| ApiError::herdr(&e))?;
    }
    if submit {
        if !text.is_empty() {
            tokio::time::sleep(std::time::Duration::from_millis(350)).await;
        }
        if let Err(e) = rt.client.pane_send_keys(&id, &state.cfg.submit_keys).await {
            return Err(if text.is_empty() { ApiError::herdr(&e) } else { ApiError::text_delivered() });
        }
    }
    state.audit.log("reply", Some(&id), q.session.as_deref(), device.device.as_deref(), &text);
    maybe_mark_seen(&rt, &headers, &id, true);
    Ok(json_response(StatusCode::OK, serde_json::json!({"ok": true})))
}

pub async fn keys_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<SessionQuery>, body: Result<axum::Json<KeysBody>, axum::extract::rejection::JsonRejection>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    let axum::Json(body) = body.map_err(|_| ApiError::new(
        StatusCode::BAD_REQUEST, "bad_request", "invalid json body"))?;
    validate_expected_prompt(&body.expected_prompt)?;
    let keys: Vec<String> = body.keys.unwrap_or_default()
        .into_iter().filter(|k| !k.is_empty()).collect();
    if keys.is_empty() {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_request", "no keys"));
    }
    if let Some(ep) = &body.expected_prompt {
        crate::prompt::check_prompt_binding(&rt.client, &id, ep, state.cfg.read_lines).await?;
    }
    rt.client.pane_send_keys(&id, &keys).await.map_err(|e| ApiError::herdr(&e))?;
    state.audit.log("keys", Some(&id), q.session.as_deref(), device.device.as_deref(), &keys.join(" "));
    maybe_mark_seen(&rt, &headers, &id, true);
    Ok(json_response(StatusCode::OK, serde_json::json!({"ok": true})))
}

pub async fn resize_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<SessionQuery>, body: Result<axum::Json<ResizeBody>, axum::extract::rejection::JsonRejection>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    let axum::Json(body) = body.map_err(|_| ApiError::new(
        StatusCode::BAD_REQUEST, "bad_request", "invalid json body"))?;
    if !(20..=300).contains(&body.cols) || !(5..=200).contains(&body.rows) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "bad_terminal_size",
            "terminal size must be 20-300 columns and 5-200 rows",
        ));
    }
    let lease_id = if let Some(lease_id) = body.lease_id {
        state
            .terminal_leases
            .resize(
                &lease_id,
                rt.client.socket_path(),
                &id,
                body.cols,
                body.rows,
            )
            .await
            .map_err(terminal_resize_error)?;
        lease_id
    } else {
        let lease_id = state
            .terminal_leases
            .acquire(rt.client.socket_path(), &id, body.cols, body.rows)
            .await
            .map_err(terminal_resize_error)?;
        state.audit.log(
            "resize_acquire", Some(&id), q.session.as_deref(), device.device.as_deref(),
            &format!("{}x{}", body.cols, body.rows),
        );
        rt.engine.poke();
        lease_id
    };
    maybe_mark_seen(&rt, &headers, &id, true);
    Ok(json_response(
        StatusCode::OK,
        serde_json::json!({"ok": true, "leaseId": lease_id}),
    ))
}

fn terminal_resize_error(error: crate::terminal_resize::TerminalResizeError) -> ApiError {
    let (status, code) = match error {
        crate::terminal_resize::TerminalResizeError::UnknownLease => {
            (StatusCode::CONFLICT, "terminal_lease_expired")
        }
        crate::terminal_resize::TerminalResizeError::LeaseInUse => {
            (StatusCode::CONFLICT, "terminal_lease_in_use")
        }
        _ => (StatusCode::BAD_GATEWAY, "terminal_resize_failed"),
    };
    ApiError::new(status, code, format!("terminal resize failed: {error}"))
}

pub async fn release_pane_resize(
    State(state): State<AppState>, headers: HeaderMap,
    Path((id, lease_id)): Path<(String, String)>, Query(q): Query<SessionQuery>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    state
        .terminal_leases
        .release(&lease_id, rt.client.socket_path(), &id)
        .await
        .map_err(terminal_resize_error)?;
    state.audit.log(
        "resize_release", Some(&id), q.session.as_deref(), device.device.as_deref(), "",
    );
    Ok(json_response(StatusCode::OK, serde_json::json!({"ok": true})))
}

pub async fn close_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<SessionQuery>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    rt.client.pane_close(&id).await.map_err(|e| ApiError::herdr(&e))?;
    state.audit.log("close", Some(&id), q.session.as_deref(), device.device.as_deref(), "");
    maybe_mark_seen(&rt, &headers, &id, true);
    Ok(json_response(StatusCode::OK, serde_json::json!({"ok": true})))
}

#[derive(Deserialize)]
pub struct RenameBody {
    pub label: Option<serde_json::Value>, // 用三重态区分缺席/null/值
}

pub async fn rename_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<SessionQuery>, body: Result<axum::Json<RenameBody>, axum::extract::rejection::JsonRejection>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    let axum::Json(body) = body.map_err(|_| ApiError::new(
        StatusCode::BAD_REQUEST, "bad_request", "invalid json body"))?;
    // collie 语义：body 必须含 label 键（string|null），缺席 → 400。
    if body.label.is_none() {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_request", "bad label"));
    }
    let label = match body.label {
        Some(serde_json::Value::Null) => None, // null = 清除
        Some(serde_json::Value::String(s)) => {
            let t = s.trim();
            if t.is_empty() { None } else { Some(t.to_string()) }
        }
        Some(_) => return Err(ApiError::new(StatusCode::BAD_REQUEST, "bad_request", "bad label")),
        None => None, // 不可达：上面已拒绝缺席
    };
    rt.client.pane_rename(&id, label.as_deref()).await.map_err(|e| ApiError::herdr(&e))?;
    state.audit.log("rename", Some(&id), q.session.as_deref(), device.device.as_deref(),
        label.as_deref().unwrap_or("<clear>"));
    maybe_mark_seen(&rt, &headers, &id, true);
    Ok(json_response(StatusCode::OK, serde_json::json!({"ok": true})))
}

/// MultipartError 的 Display 是常量串，无法探测 body limit；用 e.status() 分支：
/// DefaultBodyLimit 超限（或字段超限）→ 413，其余 → 400。
fn multipart_api_error(e: axum::extract::multipart::MultipartError) -> ApiError {
    if e.status() == StatusCode::PAYLOAD_TOO_LARGE {
        ApiError::new(StatusCode::PAYLOAD_TOO_LARGE, "payload_too_large",
            "image too large (max 10 MB)")
    } else {
        ApiError::new(StatusCode::BAD_REQUEST, "bad_request", e.body_text())
    }
}

pub async fn upload_pane(
    State(state): State<AppState>, headers: HeaderMap, Path(id): Path<String>,
    Query(q): Query<SessionQuery>, multipart: Result<axum::extract::Multipart, axum::extract::multipart::MultipartRejection>,
) -> Result<Response, ApiError> {
    let device = check_access(&state.cfg, &headers, AccessLevel::Write)?;
    let rt = state.runtime(q.session.as_deref())?;
    // Content-Length 预检
    if let Some(len) = headers.get("content-length").and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok())
    {
        if len > crate::uploads::MAX_CONTENT_LENGTH {
            return Err(ApiError::new(StatusCode::PAYLOAD_TOO_LARGE,
                "payload_too_large", "image too large (max 10 MB)"));
        }
    }
    let mut multipart = multipart.map_err(|_| ApiError::new(
        StatusCode::BAD_REQUEST, "bad_request", "expected multipart form data"))?;
    let mut saved: Option<PathBuf> = None;
    // 超限错误可能在 next_field（如整帧超限时首个 poll 即失败）或 field.bytes()
    // 处冒出，两处都须经 multipart_api_error 映射，不可吞错降级为 no_file。
    loop {
        let field = match multipart.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(e) => return Err(multipart_api_error(e)),
        };
        if field.name() != Some("file") { continue; }
        let mime = field.content_type().unwrap_or("").to_string();
        let Some(ext) = crate::uploads::ext_for_mime(&mime) else {
            return Err(ApiError::new(StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "unsupported_media_type", format!("unsupported type: {mime}")));
        };
        let data = field.bytes().await.map_err(multipart_api_error)?;
        if data.len() > crate::uploads::max_image_bytes() {
            return Err(ApiError::new(StatusCode::PAYLOAD_TOO_LARGE,
                "payload_too_large", "image too large (max 10 MB)"));
        }
        let path = crate::uploads::save_upload(&state.cfg.state_dir, &id, ext, &data)
            .map_err(|e| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR,
                "bad_request", format!("save failed: {e}")))?;
        saved = Some(path);
    }
    let Some(path) = saved else {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "no_file", "no file"));
    };
    rt.engine.mark_seen(&id);
    state.audit.log("upload", Some(&id), q.session.as_deref(), device.device.as_deref(),
        &path.to_string_lossy());
    Ok(json_response(StatusCode::OK, serde_json::json!({
        "ok": true, "path": path.to_string_lossy(),
    })))
}

pub async fn not_found() -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, "not_found", "not found")
}

pub async fn method_not_allowed() -> ApiError {
    ApiError::new(StatusCode::METHOD_NOT_ALLOWED, "method_not_allowed", "method not allowed")
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
