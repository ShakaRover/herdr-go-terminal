use std::path::PathBuf;

use super::files::contained_realpath;
use super::pi::PiAdapter;
use super::{
    AgentSessionRef, JournalAdapter, ResolvedLog, TranscriptEntry,
};

/// OMP（pi-coding-agent 系）的 journal 适配器。
///
/// OMP 的会话文件与 pi 同构：`<root>/<encoded-cwd>/<ts>_<uuid>.jsonl`，
/// 因此解析直接复用 [PiAdapter]，这里只负责按 cwd 找到当前会话文件。
/// root 默认 `~/.omp/agent/sessions`，可用 `HERDRGOT_BRIDGE_OMP_ROOT` 覆盖。
pub struct OmpAdapter {
    root: PathBuf,
    inner: PiAdapter,
}

impl OmpAdapter {
    pub fn new(root: Option<PathBuf>) -> Self {
        let root = root.unwrap_or_else(|| {
            crate::config::home_dir()
                .join(".omp")
                .join("agent")
                .join("sessions")
        });
        OmpAdapter {
            inner: PiAdapter::new(Some(root.clone())),
            root,
        }
    }

    /// OMP/pi 的 cwd 目录编码：去掉开头分隔符，`/`、`\`、`:` 换成 `-`，
    /// 两端包 `--`。例如 `/tmp/project` → `--tmp-project--`。
    fn encoded_cwd(cwd: &str) -> String {
        format!(
            "--{}--",
            cwd.trim_start_matches(['/', '\\'])
                .replace(|c| c == '/' || c == '\\' || c == ':', "-")
        )
    }

    /// 在 cwd 对应目录里找最新的 `.jsonl` 会话。OMP 不会把 session ref
    /// 上报给 herdr，只能按 pane cwd 回退推断；同 cwd 多会话时取最新文件。
    pub fn find_for_cwd(&self, cwd: &str) -> Option<PathBuf> {
        let dir = self.root.join(Self::encoded_cwd(cwd));
        let mut newest: Option<(std::time::SystemTime, PathBuf)> = None;
        for entry in std::fs::read_dir(&dir).ok()?.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let name = entry.file_name();
            if !name.to_string_lossy().ends_with(".jsonl") {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            let modified = meta.modified().unwrap_or(std::time::UNIX_EPOCH);
            if newest
                .as_ref()
                .is_none_or(|(time, _)| modified > *time)
            {
                newest = Some((modified, path));
            }
        }
        contained_realpath(&newest?.1, &self.root)
    }
}

impl JournalAdapter for OmpAdapter {
    fn validate_ref(&self, r: &AgentSessionRef) -> bool {
        self.inner.validate_ref(r)
    }

    fn resolve(&self, r: &AgentSessionRef) -> Option<ResolvedLog> {
        self.inner.resolve(r)
    }

    fn load(&self, resolved: &ResolvedLog) -> std::io::Result<(Vec<TranscriptEntry>, bool)> {
        self.inner.load(resolved)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_cwd_and_finds_newest_session() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("sessions");
        let project = root.join("--tmp-project--");
        std::fs::create_dir_all(&project).unwrap();
        let older = project.join("2026-01-01T00-00-00_11111111-1111-4111-8111-111111111111.jsonl");
        let newer = project.join("2026-01-02T00-00-00_22222222-2222-4222-8222-222222222222.jsonl");
        std::fs::write(&older, "{\"type\":\"message\",\"id\":\"m1\",\"role\":\"user\",\"content\":[]}\n").unwrap();
        std::fs::write(&newer, "{\"type\":\"message\",\"id\":\"m2\",\"role\":\"user\",\"content\":[]}\n").unwrap();
        let later = std::time::SystemTime::now() + std::time::Duration::from_secs(5);
        std::fs::File::options()
            .write(true)
            .open(&newer)
            .unwrap()
            .set_modified(later)
            .unwrap();
        let a = OmpAdapter::new(Some(root));
        assert_eq!(
            a.find_for_cwd("/tmp/project"),
            Some(std::fs::canonicalize(&newer).unwrap())
        );
        assert!(a.find_for_cwd("/tmp/missing").is_none());
    }
}
