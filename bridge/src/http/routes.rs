use std::path::PathBuf;

use axum::body::Body;
use axum::extract::{Path, Query, State};
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
        &|a| state.journal.has_adapter(a));
    let sessions = state.registry.summaries(&|a| state.journal.has_adapter(a));
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

#[derive(Deserialize)]
pub struct PaneReadQuery {
    session: Option<String>,
    lines: Option<u32>,
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
    let Some(session) = &pane.agent_session else { return Ok(unavailable("no-session")) };
    let agent = pane.agent.as_deref().unwrap_or("");
    if session.agent.as_deref().is_some_and(|a| a != agent)
        || !state.journal.has_adapter(agent)
    {
        return Ok(unavailable("no-session"));
    }
    let kind = match session.kind.as_str() {
        "id" => crate::journal::RefKind::Id,
        "path" => crate::journal::RefKind::Path,
        _ => return Ok(unavailable("no-session")),
    };
    let r = crate::journal::AgentSessionRef { kind, value: session.value.clone() };
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
