use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const PRUNE_AFTER_MS: u64 = 30 * 24 * 3600 * 1000;

/// session 分键分隔符（Unit Separator）：多 session 共享一个账本文件，
/// paneId 键统一为 `{session}{SEP}{pane_id}`，分隔符不可能出现在 pane id 里。
pub(crate) const SEP: char = '\u{1f}';

#[derive(Clone)]
pub struct ActivityLedger {
    inner: Arc<Mutex<LedgerInner>>,
}

struct LedgerInner {
    path: PathBuf,
    map: HashMap<String, (u64, u64)>, // paneId -> (activeAt, seenAt)
    dirty: bool,
    last_write: std::time::Instant,
}

impl ActivityLedger {
    pub fn load(path: &Path) -> Self {
        let now = crate::http::routes::now_ms();
        // 控制器裁决 #1：brief 的 and_then(|v| {...}) 返回 Option 的链等价重排为
        // 单层 and_then + unwrap_or_default（语义一致，均可收敛为空 map）。
        let parsed: HashMap<String, (u64, u64)> = std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
            .and_then(|v| {
                v.as_object().map(|o| o.iter().filter_map(|(k, e)| {
                    let a = e["activeAt"].as_u64()?;
                    let s = e["seenAt"].as_u64()?;
                    Some((k.clone(), (a, s)))
                }).collect::<HashMap<_, _>>())
            })
            .unwrap_or_default();
        // 披露：brief 以真实 now 做 30 天剪除，但其自带的 flush_persists_and_reload
        // 用小时间戳（1000/2000）断言存活，两者矛盾。最小修正：剪除基线改为文件内
        // 最新时间戳——正常重启（文件新鲜）行为不变，长时间停机后条目保留，
        // 由 poll 的 reconcile 负责清掉已消失的 pane。
        let newest = parsed.values().flat_map(|(a, s)| [*a, *s]).max().unwrap_or(now);
        let map = parsed.into_iter()
            .filter(|(_, (a, s))| newest.saturating_sub((*a).max(*s)) < PRUNE_AFTER_MS)
            .collect();
        ActivityLedger {
            inner: Arc::new(Mutex::new(LedgerInner {
                path: path.to_path_buf(), map, dirty: false,
                last_write: std::time::Instant::now(),
            })),
        }
    }

    pub fn ensure(&self, pane_id: &str, now: u64) {
        let mut g = self.inner.lock().unwrap();
        g.map.entry(pane_id.to_string()).or_insert((now, now));
    }

    pub fn note_transition(&self, pane_id: &str, now: u64) {
        let mut g = self.inner.lock().unwrap();
        let e = g.map.entry(pane_id.to_string()).or_insert((now, now));
        e.0 = now;
        self.maybe_persist(&mut g);
    }

    pub fn note_seen(&self, pane_id: &str, now: u64) {
        let mut g = self.inner.lock().unwrap();
        let e = g.map.entry(pane_id.to_string()).or_insert((now, now));
        e.1 = now;
        self.maybe_persist(&mut g);
    }

    /// 按 scope 前缀收敛：只清本 session 的键（live 为已带前缀的键集），
    /// 其它 session 的键不受影响；live 内缺失的补种子。
    pub fn reconcile(&self, scope: &str, live: &HashSet<String>, now: u64) {
        let needle = format!("{scope}{SEP}");
        let mut g = self.inner.lock().unwrap();
        g.map.retain(|k, _| !k.starts_with(&needle) || live.contains(k));
        for id in live {
            g.map.entry(id.clone()).or_insert((now, now));
        }
    }

    /// 解前缀后的本 session 视图（paneId -> (activeAt, seenAt)）。
    pub fn snapshot_scoped(&self, scope: &str) -> HashMap<String, (u64, u64)> {
        let needle = format!("{scope}{SEP}");
        self.inner.lock().unwrap().map.iter()
            .filter_map(|(k, v)| k.strip_prefix(&needle).map(|k| (k.to_string(), *v)))
            .collect()
    }

    pub fn get(&self, pane_id: &str) -> Option<(u64, u64)> {
        self.inner.lock().unwrap().map.get(pane_id).copied()
    }

    fn maybe_persist(&self, g: &mut LedgerInner) {
        g.dirty = true;
        if g.last_write.elapsed() >= std::time::Duration::from_secs(10) {
            Self::persist(g);
        }
    }

    fn persist(g: &mut LedgerInner) {
        let mut v = serde_json::Map::new();
        for (k, (a, s)) in &g.map {
            v.insert(k.clone(), serde_json::json!({"activeAt": a, "seenAt": s}));
        }
        let tmp = g.path.with_extension("json.tmp");
        // 控制器裁决 #2：brief 的 if let Ok(()) = write().map(|_| rename) 类型不匹配，
        // 最小修正为 and_then 后判 is_ok。
        if std::fs::write(&tmp, serde_json::Value::Object(v).to_string())
            .and_then(|_| {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))
            })
            .and_then(|_| std::fs::rename(&tmp, &g.path))
            .is_ok()
        {
            g.dirty = false;
            g.last_write = std::time::Instant::now();
        }
    }

    pub fn flush(&self) {
        let mut g = self.inner.lock().unwrap();
        if g.dirty { Self::persist(&mut g); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_seen_seeds_equal_timestamps() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = ActivityLedger::load(&dir.path().join("activity.json"));
        ledger.ensure("w1:p1", 1000);
        assert_eq!(ledger.get("w1:p1"), Some((1000, 1000)));
    }

    #[test]
    fn transition_updates_active_only() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = ActivityLedger::load(&dir.path().join("activity.json"));
        ledger.ensure("w1:p1", 1000);
        ledger.note_transition("w1:p1", 2000);
        assert_eq!(ledger.get("w1:p1"), Some((2000, 1000)));
        ledger.note_seen("w1:p1", 3000);
        assert_eq!(ledger.get("w1:p1"), Some((2000, 3000)));
    }

    #[test]
    fn reconcile_drops_gone_and_seeds_new() {
        let dir = tempfile::tempdir().unwrap();
        let ledger = ActivityLedger::load(&dir.path().join("activity.json"));
        ledger.ensure(&format!("default{SEP}w1:p1"), 1000);
        // 其它 session 的同号 pane：本 session 的 reconcile 不能误删
        ledger.ensure(&format!("work{SEP}w1:p1"), 1000);
        let live: std::collections::HashSet<String> =
            [format!("default{SEP}w1:p2")].into_iter().collect();
        ledger.reconcile("default", &live, 2000);
        assert_eq!(ledger.get(&format!("default{SEP}w1:p1")), None);
        assert_eq!(ledger.get(&format!("default{SEP}w1:p2")), Some((2000, 2000)));
        assert_eq!(ledger.get(&format!("work{SEP}w1:p1")), Some((1000, 1000)));
    }

    #[test]
    fn flush_persists_and_reload() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("activity.json");
        let ledger = ActivityLedger::load(&path);
        ledger.ensure("w1:p1", 1000);
        ledger.note_transition("w1:p1", 2000);
        ledger.flush();
        let again = ActivityLedger::load(&path);
        assert_eq!(again.get("w1:p1"), Some((2000, 1000)));
    }

    #[test]
    fn stale_entries_pruned_on_load() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("activity.json");
        let old = 1000u64;
        let now = crate::http::routes::now_ms();
        std::fs::write(&path, serde_json::json!({
            "w1:p1": {"activeAt": old, "seenAt": old},
            "w1:p2": {"activeAt": now, "seenAt": now}
        }).to_string()).unwrap();
        let ledger = ActivityLedger::load(&path);
        assert_eq!(ledger.get("w1:p1"), None);
        assert!(ledger.get("w1:p2").is_some());
    }
}
