use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub struct AuditLog {
    path: PathBuf,
    file: Mutex<Option<std::fs::File>>,
}

fn sanitize(s: &str) -> String {
    let flat: String = s.chars().map(|c| if c == '\n' || c == '\r' { ' ' } else { c }).collect();
    flat.chars().take(120).collect()
}

/// audit.log 含回复文本片段，必须 0600（spec §2）。
fn open_audit(path: &Path) -> Option<std::fs::File> {
    let f = std::fs::OpenOptions::new().create(true).append(true).open(path).ok()?;
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    Some(f)
}

impl AuditLog {
    pub fn new(state_dir: &Path) -> Self {
        let path = state_dir.join("audit.log");
        AuditLog { file: Mutex::new(open_audit(&path)), path }
    }

    pub fn log(&self, action: &str, pane_id: Option<&str>, session: Option<&str>,
               device: Option<&str>, detail: &str) {
        let mut line = serde_json::json!({
            "ts": crate::http::routes::now_ms(),
            "action": action,
        });
        if let Some(p) = pane_id { line["paneId"] = sanitize(p).into(); }
        if let Some(s) = session { line["session"] = sanitize(s).into(); }
        if let Some(d) = device { line["device"] = sanitize(d).into(); }
        line["detail"] = sanitize(detail).into();
        let mut guard = self.file.lock().unwrap();
        if guard.is_none() {
            *guard = open_audit(&self.path);
        }
        if let Some(f) = guard.as_mut() {
            use std::io::Write;
            if let Err(e) = writeln!(f, "{line}") {
                tracing::warn!("audit write failed: {e}");
            }
        }
    }
}
