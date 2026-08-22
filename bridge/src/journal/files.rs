use std::path::{Path, PathBuf};

pub const MAX_TRANSCRIPT_BYTES: u64 = 32 * 1024 * 1024;

pub fn contained_realpath(path: &Path, root: &Path) -> Option<PathBuf> {
    let real = path.canonicalize().ok()?;
    let real_root = root.canonicalize().ok()?;
    real.starts_with(&real_root).then_some(real)
}

pub fn contained_realpath_in(path: &Path, roots: &[PathBuf]) -> Option<PathBuf> {
    roots.iter().find_map(|r| contained_realpath(path, r))
}

/// 读文件尾部 max_bytes；超窗时对齐到整行，返回 (text, truncated)。
pub fn read_tail(path: &Path, max_bytes: u64) -> std::io::Result<(String, bool)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path)?;
    let size = f.metadata()?.len();
    if size <= max_bytes {
        let mut buf = Vec::new();
        f.read_to_end(&mut buf)?;
        return Ok((String::from_utf8_lossy(&buf).to_string(), false));
    }
    f.seek(SeekFrom::End(-(max_bytes as i64)))?;
    let mut buf = vec![0u8; max_bytes as usize];
    f.read_exact(&mut buf)?;
    // 对齐到下一个换行，丢弃半行
    let start = buf.iter().position(|b| *b == b'\n').map(|p| p + 1).unwrap_or(0);
    Ok((String::from_utf8_lossy(&buf[start..]).to_string(), true))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn containment_accepts_inside_rejects_outside() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("root");
        std::fs::create_dir_all(&root).unwrap();
        let inside = root.join("a.jsonl");
        std::fs::write(&inside, "x").unwrap();
        assert!(contained_realpath(&inside, &root).is_some());
        let outside = dir.path().join("evil.jsonl");
        std::fs::write(&outside, "x").unwrap();
        assert!(contained_realpath(&outside, &root).is_none());
        // symlink 逃逸也被拒
        let link = root.join("link.jsonl");
        std::os::unix::fs::symlink(&outside, &link).unwrap();
        assert!(contained_realpath(&link, &root).is_none());
    }

    #[test]
    fn read_tail_truncates_to_window() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("big.log");
        let mut f = std::fs::File::create(&p).unwrap();
        for i in 0..1000 { writeln!(f, "line-{i}-{}", "x".repeat(100)).unwrap(); }
        let (text, truncated) = read_tail(&p, 10_000).unwrap();
        assert!(truncated);
        assert!(text.len() <= 10_000 + 256); // 行对齐余量
        assert!(text.contains("line-999"));
        assert!(!text.contains("line-0\n"));
        let (full, t2) = read_tail(&p, 1_000_000).unwrap();
        assert!(!t2);
        assert!(full.contains("line-0"));
    }
}
