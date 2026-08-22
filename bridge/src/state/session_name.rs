use regex::Regex;

fn rule_re() -> &'static Regex {
    static RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();
    // 捕获组排除 ─/━：纯横线行（无 name）不得回溯出 dash-only 捕获（见
    // rule_without_name_no_match 用例）。
    RE.get_or_init(|| Regex::new(r"^[─━]+\s*([^─━]+?)\s*[─━]+$").unwrap())
}

/// 从最底部 `❯` 提示行的上一行提取 `─── name ───` 横线名（claude /rename）。
pub fn extract_claude_session_name(visible_text: &str) -> Option<String> {
    let clean = crate::journal::text::strip_ansi(visible_text);
    let lines: Vec<&str> = clean.lines().collect();
    let prompt_idx = lines.iter().rposition(|l| l.trim_start().starts_with('❯'))?;
    if prompt_idx == 0 { return None; }
    let above = lines[prompt_idx - 1].trim();
    rule_re().captures(above).map(|c| c[1].to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_name_from_rule_line() {
        let text = "some output\n──────────────── my-feature ────────────────\n❯ \n";
        assert_eq!(extract_claude_session_name(text).as_deref(), Some("my-feature"));
    }

    #[test]
    fn heavy_rules_also_match() {
        let text = "━━━━━━━ fix ━━━━━━━\n❯ ";
        assert_eq!(extract_claude_session_name(text).as_deref(), Some("fix"));
    }

    #[test]
    fn no_prompt_line_no_name() {
        assert_eq!(extract_claude_session_name("plain output\n"), None);
    }

    #[test]
    fn rule_without_name_no_match() {
        assert_eq!(extract_claude_session_name("────────────\n❯ "), None);
    }

    #[test]
    fn uses_bottommost_prompt() {
        let text = "─── old ───\n❯ \nstuff\n─── new ───\n❯ \n";
        assert_eq!(extract_claude_session_name(text).as_deref(), Some("new"));
    }
}
