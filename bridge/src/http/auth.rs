use axum::http::{HeaderMap, StatusCode};

use crate::config::Config;
use crate::error::ApiError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccessLevel { Read, Write }

#[derive(Debug, Clone)]
pub struct DeviceAuth {
    pub enforced: bool,
    pub device: Option<String>,
    pub authorized: bool,
}

fn host_of(headers: &HeaderMap) -> Option<String> {
    headers.get("host").and_then(|v| v.to_str().ok()).map(|s| s.to_ascii_lowercase())
}

fn is_loopback_host(host: &str) -> bool {
    let h = host.split(':').next().unwrap_or(host);
    h == "localhost" || h == "127.0.0.1" || host == "[::1]" || host.starts_with("[::1]:")
}

fn forbid(code: &'static str, msg: &str) -> ApiError {
    ApiError::new(StatusCode::FORBIDDEN, code, msg)
}

fn device_auth(cfg: &Config, headers: &HeaderMap) -> DeviceAuth {
    let Some(header_name) = &cfg.device_header else {
        return DeviceAuth { enforced: false, device: None, authorized: true };
    };
    let device = headers
        .get(header_name.as_str())
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let authorized = device
        .as_ref()
        .is_some_and(|d| d != "unknown" && cfg.device_allowlist.iter().any(|a| a == d));
    DeviceAuth { enforced: true, device, authorized }
}

pub fn check_access(
    cfg: &Config, headers: &HeaderMap, level: AccessLevel,
) -> Result<DeviceAuth, ApiError> {
    let host = host_of(headers).unwrap_or_default();

    // 1. Host allowlist（启用即 fail-closed）
    if !cfg.public_hosts.is_empty()
        && !is_loopback_host(&host)
        && !cfg.public_hosts.iter().any(|h| h.eq_ignore_ascii_case(&host))
        && !cfg.allowed_origins.iter().any(|o| {
            o.trim_start_matches("https://").trim_start_matches("http://")
                .eq_ignore_ascii_case(&host)
        })
    {
        return Err(forbid("host_not_allowed", "host not allowed"));
    }

    // 2. Origin
    match headers.get("origin").and_then(|v| v.to_str().ok()) {
        Some(origin) => {
            let origin_host = origin
                .trim_start_matches("http://").trim_start_matches("https://")
                .to_ascii_lowercase();
            if origin_host == origin.to_ascii_lowercase() && !origin_host.is_empty() {
                // 没有 scheme → 解析失败
                return Err(forbid("bad_origin", "bad origin"));
            }
            if origin_host != host
                && !is_loopback_host(&origin_host)
                && !cfg.allowed_origins.iter().any(|o| o == origin)
            {
                return Err(forbid("cross_origin_rejected", "cross-origin rejected"));
            }
        }
        None => {
            if level == AccessLevel::Write && !is_loopback_host(&host) {
                return Err(forbid("origin_required", "origin required"));
            }
        }
    }

    // 3. Tailscale identity（不带头放行）
    if let Some(trusted) = &cfg.trusted_user {
        if let Some(login) = headers.get("tailscale-user-login").and_then(|v| v.to_str().ok()) {
            if login != trusted {
                return Err(forbid("identity_not_trusted", "identity not trusted"));
            }
        }
    }

    // 4. device gate（仅写级拦截）
    let auth = device_auth(cfg, headers);
    if level == AccessLevel::Write && auth.enforced && !auth.authorized {
        return Err(forbid("device_not_authorised", "device not authorised"));
    }
    Ok(auth)
}
