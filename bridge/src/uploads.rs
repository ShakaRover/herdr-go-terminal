use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const MAX_IMAGE_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_CONTENT_LENGTH: u64 = (10 * 1024 * 1024 + 64 * 1024) as u64;
const SWEEP_AGE: std::time::Duration = std::time::Duration::from_secs(48 * 3600);

pub fn safe_pane(pane_id: &str) -> String {
    pane_id.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).collect()
}

fn base36(mut n: u64) -> String {
    let mut out = String::new();
    loop {
        out.push(char::from_digit((n % 36) as u32, 36).unwrap());
        n /= 36;
        if n == 0 { break; }
    }
    out.chars().rev().collect()
}

pub fn save_upload(state_dir: &Path, pane_id: &str, ext: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
    let dir = state_dir.join("uploads");
    std::fs::create_dir_all(&dir)?;
    // spec：uploads 目录 0700（umask 可能放权，显式收紧一次）。
    let mut perms = std::fs::metadata(&dir)?.permissions();
    perms.set_mode(0o700);
    std::fs::set_permissions(&dir, perms)?;
    let now = crate::http::routes::now_ms();
    let uuid8 = &uuid::Uuid::new_v4().simple().to_string()[..8];
    let name = format!("{}-{}-{}.{}", safe_pane(pane_id), base36(now), uuid8, ext);
    let path = dir.join(name);
    std::fs::write(&path, bytes)?;
    Ok(path)
}

pub fn sweep_before(state_dir: &Path, cutoff: std::time::SystemTime) {
    let dir = state_dir.join("uploads");
    let Ok(rd) = std::fs::read_dir(&dir) else { return };
    for entry in rd.flatten() {
        let old = entry.metadata().and_then(|m| m.modified())
            .map(|m| m < cutoff).unwrap_or(false);
        if old {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

pub fn sweep(state_dir: &Path) {
    sweep_before(state_dir, std::time::SystemTime::now() - SWEEP_AGE);
}

pub fn ext_for_mime(mime: &str) -> Option<&'static str> {
    match mime {
        "image/png" => Some("png"),
        "image/jpeg" => Some("jpg"),
        "image/webp" => Some("webp"),
        "image/gif" => Some("gif"),
        _ => None,
    }
}

pub fn mime_allowed(mime: &str) -> bool { ext_for_mime(mime).is_some() }

pub fn max_image_bytes() -> usize { MAX_IMAGE_BYTES }
