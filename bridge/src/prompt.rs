use axum::http::StatusCode;
use regex::Regex;

use crate::error::ApiError;
use crate::herdr::client::HerdrClient;

pub const PROMPT_TAIL_LINES: usize = 6;
const MAX_EXPECTED_DEPTH: u32 = 10000;

fn sgr_regex() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?:\x1b\[|\x9b)[0-?]*[ -/]*m").unwrap())
}

/// 剥 SGR → CRLF/LF 归一 → 行尾空白剔除 → 丢空行（保留行首缩进）。
pub fn normalize_prompt_region(text: &str) -> Vec<String> {
    let stripped = sgr_regex().replace_all(text, "");
    stripped
        .replace("\r\n", "\n")
        .replace('\r', "\n")
        .lines()
        .map(|l| l.trim_end().to_string())
        .filter(|l| !l.is_empty())
        .collect()
}

pub fn verify_expected_prompt(fresh: &str, expected: &str) -> Result<(), &'static str> {
    let want = normalize_prompt_region(expected);
    if want.is_empty() {
        return Err("empty");
    }
    let have = normalize_prompt_region(fresh);
    if want.len() > have.len() {
        return Err("not_found");
    }
    // 最后一次完整连续匹配
    let mut last_match_end: Option<usize> = None;
    for start in 0..=(have.len() - want.len()) {
        if have[start..start + want.len()] == want[..] {
            last_match_end = Some(start + want.len());
        }
    }
    let Some(end) = last_match_end else { return Err("not_found") };
    if have.len() - end > PROMPT_TAIL_LINES {
        return Err("not_in_tail");
    }
    Ok(())
}

pub async fn check_prompt_binding(
    client: &HerdrClient, pane_id: &str, expected: &str, read_lines: u32,
) -> Result<(), ApiError> {
    let expected_lines = normalize_prompt_region(expected).len() as u32;
    let depth = read_lines.max(expected_lines + 12).min(MAX_EXPECTED_DEPTH);
    let fresh = client
        .pane_read(pane_id, "recent", Some(depth), "ansi")
        .await
        .map_err(|e| ApiError::new(
            StatusCode::BAD_GATEWAY, "herdr_read_failed", format!("herdr read failed: {e}")))?;
    match verify_expected_prompt(&fresh.text, expected) {
        Ok(()) => Ok(()),
        Err(reason) => {
            tracing::debug!(pane_id, reason, "prompt binding rejected");
            Err(ApiError::new(StatusCode::CONFLICT, "prompt_changed", "prompt changed"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_strips_sgr_and_crlf() {
        let raw = "\u{1b}[1m❯\u{1b}[0m Do it? \r\n\u{1b}[32m❯ 1. Yes\u{1b}[0m\r\n  2. No  \r\n\r\n";
        let lines = normalize_prompt_region(raw);
        assert_eq!(lines, vec!["❯ Do it?", "❯ 1. Yes", "  2. No"]);
    }

    #[test]
    fn verify_finds_last_match_in_tail() {
        let fresh = "old\n❯ 1. Yes\n  2. No\nnoise\n❯ 1. Yes\n  2. No\n";
        assert!(verify_expected_prompt(fresh, "❯ 1. Yes\n  2. No").is_ok());
    }

    #[test]
    fn verify_rejects_when_too_far_from_tail() {
        let fresh = "❯ 1. Yes\n  2. No\na\nb\nc\nd\ne\nf\ng\n"; // 匹配后还有 7 行
        assert_eq!(verify_expected_prompt(fresh, "❯ 1. Yes\n  2. No"), Err("not_in_tail"));
    }

    #[test]
    fn verify_rejects_empty_and_missing() {
        assert_eq!(verify_expected_prompt("x", "\u{1b}[31m\u{1b}[0m"), Err("empty"));
        assert_eq!(verify_expected_prompt("nothing here", "❯ pick"), Err("not_found"));
    }

    #[test]
    fn verify_preserves_indent() {
        let fresh = "❯ 1. Yes\n  2. No";
        // expected 无缩进 ≠ fresh 有缩进
        assert_eq!(verify_expected_prompt(fresh, "❯ 1. Yes\n2. No"), Err("not_found"));
    }
}
