use regex::Regex;
use std::sync::OnceLock;

fn csi_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\x1b\[[0-?]*[ -/]*[@-~]|\x{9b}[0-?]*[ -/]*[@-~]").unwrap())
}

/// 剥除全部 CSI 转义序列：`\x1b[`/U+009B 开头，后跟参数/中间字节，终于最终字节。
pub fn strip_ansi(s: &str) -> String {
    csi_re().replace_all(s, "").into_owned()
}

pub const MAX_TEXT_CHARS: usize = 20000;
pub const MAX_TOOL_RESULT_CHARS: usize = 2000;
pub const MAX_TOOL_SUMMARY_CHARS: usize = 200;

pub fn truncate_chars(s: &str, max: usize) -> (String, bool) {
    if s.chars().count() <= max {
        (s.to_string(), false)
    } else {
        (s.chars().take(max).collect(), true)
    }
}

pub fn single_line(s: &str, max: usize) -> String {
    let flat: String = s.chars().map(|c| if c == '\n' || c == '\r' { ' ' } else { c }).collect();
    truncate_chars(&flat, max).0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_sgr_and_cup() {
        assert_eq!(strip_ansi("\x1b[1;32mok\x1b[0m"), "ok");
        assert_eq!(strip_ansi("\x1b[2J\x1b[10;5Hx"), "x");
    }

    #[test]
    fn strips_c1_csi_short_form() {
        assert_eq!(strip_ansi("\u{9b}1malive"), "alive");
    }

    #[test]
    fn keeps_plain_text() {
        assert_eq!(strip_ansi("plain ── text ──\n❯ "), "plain ── text ──\n❯ ");
    }
}
