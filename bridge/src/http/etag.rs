use axum::http::HeaderValue;

pub fn compute(body: &str) -> String {
    format!("\"{:x}\"", wyhash::wyhash(body.as_bytes(), 0))
}

pub fn matches(if_none_match: Option<&HeaderValue>, etag: &str) -> bool {
    if_none_match.and_then(|v| v.to_str().ok()) == Some(etag)
}
