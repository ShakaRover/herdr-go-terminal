use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio::task::JoinHandle;
use tokio::time::{timeout, Instant};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_LEASE_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug)]
pub enum TerminalResizeError {
    Io(String),
    Protocol(String),
    Process(String),
    Timeout,
    UnknownLease,
}

impl std::fmt::Display for TerminalResizeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TerminalResizeError::Io(message) => write!(f, "io: {message}"),
            TerminalResizeError::Protocol(message) => write!(f, "protocol: {message}"),
            TerminalResizeError::Process(message) => write!(f, "herdr: {message}"),
            TerminalResizeError::Timeout => write!(f, "timeout"),
            TerminalResizeError::UnknownLease => write!(f, "terminal resize lease expired"),
        }
    }
}

impl std::error::Error for TerminalResizeError {}

#[derive(Clone, Debug, Eq, PartialEq)]
struct PaneKey {
    socket_path: PathBuf,
    pane_id: String,
}

struct LeaseEntry {
    pane: PaneKey,
    commands: mpsc::Sender<LeaseCommand>,
}

enum LeaseCommand {
    Resize {
        cols: u16,
        rows: u16,
        reply: oneshot::Sender<Result<(), TerminalResizeError>>,
    },
    Release {
        reply: oneshot::Sender<Result<(), TerminalResizeError>>,
    },
}

struct ManagerInner {
    acquire_lock: Mutex<()>,
    leases: Mutex<HashMap<String, LeaseEntry>>,
}

/// Owns the Herdr controller process while a phone is displaying a pane.
///
/// The app renews the opaque lease periodically. If it disappears without
/// releasing (for example, after a crash), the controller is released after
/// the lease timeout so a desktop Herdr client can take the terminal back.
#[derive(Clone)]
pub struct TerminalLeaseManager {
    herdr_bin: PathBuf,
    lease_timeout: Duration,
    inner: Arc<ManagerInner>,
}

impl TerminalLeaseManager {
    pub fn new(herdr_bin: PathBuf) -> Self {
        Self::with_timeout(herdr_bin, DEFAULT_LEASE_TIMEOUT)
    }

    fn with_timeout(herdr_bin: PathBuf, lease_timeout: Duration) -> Self {
        Self {
            herdr_bin,
            lease_timeout,
            inner: Arc::new(ManagerInner {
                acquire_lock: Mutex::new(()),
                leases: Mutex::new(HashMap::new()),
            }),
        }
    }

    pub async fn acquire(
        &self,
        socket_path: &Path,
        pane_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<String, TerminalResizeError> {
        let _acquire_guard = self.inner.acquire_lock.lock().await;
        let pane = PaneKey {
            socket_path: socket_path.to_path_buf(),
            pane_id: pane_id.to_string(),
        };

        let previous = {
            let mut leases = self.inner.leases.lock().await;
            let lease_id = leases
                .iter()
                .find_map(|(lease_id, entry)| (entry.pane == pane).then(|| lease_id.clone()));
            lease_id.and_then(|lease_id| leases.remove(&lease_id))
        };
        if let Some(previous) = previous {
            request_release(previous.commands).await?;
        }

        let started = timeout(
            COMMAND_TIMEOUT,
            start_controller(&self.herdr_bin, &pane, cols, rows),
        )
        .await
        .map_err(|_| TerminalResizeError::Timeout)??;
        let lease_id = uuid::Uuid::new_v4().to_string();
        let (commands, command_rx) = mpsc::channel(4);
        self.inner.leases.lock().await.insert(
            lease_id.clone(),
            LeaseEntry {
                pane,
                commands: commands.clone(),
            },
        );
        tokio::spawn(run_lease(
            self.inner.clone(),
            lease_id.clone(),
            self.lease_timeout,
            started,
            command_rx,
        ));
        Ok(lease_id)
    }

    pub async fn resize(
        &self,
        lease_id: &str,
        socket_path: &Path,
        pane_id: &str,
        cols: u16,
        rows: u16,
    ) -> Result<(), TerminalResizeError> {
        let commands = {
            let leases = self.inner.leases.lock().await;
            let entry = leases
                .get(lease_id)
                .filter(|entry| {
                    entry.pane.socket_path == socket_path && entry.pane.pane_id == pane_id
                })
                .ok_or(TerminalResizeError::UnknownLease)?;
            entry.commands.clone()
        };
        let (reply, result) = oneshot::channel();
        timeout(COMMAND_TIMEOUT, async {
            commands
                .send(LeaseCommand::Resize { cols, rows, reply })
                .await
                .map_err(|_| TerminalResizeError::UnknownLease)?;
            result
                .await
                .map_err(|_| TerminalResizeError::UnknownLease)?
        })
        .await
        .map_err(|_| TerminalResizeError::Timeout)?
    }

    pub async fn release(
        &self,
        lease_id: &str,
        socket_path: &Path,
        pane_id: &str,
    ) -> Result<(), TerminalResizeError> {
        let entry = {
            let mut leases = self.inner.leases.lock().await;
            let matches = leases.get(lease_id).is_some_and(|entry| {
                entry.pane.socket_path == socket_path && entry.pane.pane_id == pane_id
            });
            matches.then(|| leases.remove(lease_id)).flatten()
        };
        let Some(entry) = entry else {
            return Ok(());
        };
        request_release(entry.commands).await
    }
}

async fn request_release(commands: mpsc::Sender<LeaseCommand>) -> Result<(), TerminalResizeError> {
    let (reply, result) = oneshot::channel();
    timeout(COMMAND_TIMEOUT + Duration::from_secs(1), async {
        if commands
            .send(LeaseCommand::Release { reply })
            .await
            .is_err()
        {
            return Ok(());
        }
        result.await.unwrap_or(Ok(()))
    })
    .await
    .map_err(|_| TerminalResizeError::Timeout)?
}

struct StartedController {
    child: Child,
    stdin: ChildStdin,
    stdout_task: JoinHandle<()>,
    stderr_task: JoinHandle<String>,
}

async fn start_controller(
    herdr_bin: &Path,
    pane: &PaneKey,
    cols: u16,
    rows: u16,
) -> Result<StartedController, TerminalResizeError> {
    let cols = cols.to_string();
    let rows = rows.to_string();
    let mut child = Command::new(herdr_bin)
        .args([
            "terminal",
            "session",
            "control",
            &pane.pane_id,
            "--takeover",
            "--cols",
            &cols,
            "--rows",
            &rows,
        ])
        .env("HERDR_SOCKET_PATH", &pane.socket_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| TerminalResizeError::Io(error.to_string()))?;

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| TerminalResizeError::Io("herdr control stdin is unavailable".into()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| TerminalResizeError::Io("herdr control stdout is unavailable".into()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| TerminalResizeError::Io("herdr control stderr is unavailable".into()))?;
    let stderr_task = tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        let mut bytes = Vec::new();
        let _ = reader.read_to_end(&mut bytes).await;
        String::from_utf8_lossy(&bytes).trim().to_string()
    });

    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    let read = reader
        .read_line(&mut line)
        .await
        .map_err(|error| TerminalResizeError::Io(error.to_string()))?;
    if read == 0 {
        let status = child
            .wait()
            .await
            .map_err(|error| TerminalResizeError::Io(error.to_string()))?;
        let stderr = stderr_task.await.unwrap_or_default();
        let message = if stderr.is_empty() {
            format!("control exited before its first frame ({status})")
        } else {
            stderr
        };
        return Err(TerminalResizeError::Process(message));
    }

    let frame: serde_json::Value = serde_json::from_str(&line)
        .map_err(|error| TerminalResizeError::Protocol(format!("bad frame: {error}")))?;
    if frame.get("type").and_then(serde_json::Value::as_str) != Some("terminal.frame") {
        return Err(TerminalResizeError::Protocol(
            "expected terminal.frame".into(),
        ));
    }
    let stdout_task = tokio::spawn(async move {
        let mut bytes = Vec::new();
        let _ = reader.read_to_end(&mut bytes).await;
    });

    Ok(StartedController {
        child,
        stdin,
        stdout_task,
        stderr_task,
    })
}

enum LeaseEnd {
    ControllerExited(std::io::Result<std::process::ExitStatus>),
    Release(oneshot::Sender<Result<(), TerminalResizeError>>),
    Expired,
    CommandFailed,
}

async fn run_lease(
    inner: Arc<ManagerInner>,
    lease_id: String,
    lease_timeout: Duration,
    mut controller: StartedController,
    mut commands: mpsc::Receiver<LeaseCommand>,
) {
    let expiry = tokio::time::sleep(lease_timeout);
    tokio::pin!(expiry);
    let end = loop {
        tokio::select! {
            status = controller.child.wait() => {
                break LeaseEnd::ControllerExited(status);
            }
            command = commands.recv() => {
                match command {
                    Some(LeaseCommand::Resize { cols, rows, reply }) => {
                        let json = format!(
                            "{{\"type\":\"terminal.resize\",\"cols\":{cols},\"rows\":{rows}}}\n"
                        );
                        match controller.stdin.write_all(json.as_bytes()).await {
                            Ok(()) => {
                                let _ = reply.send(Ok(()));
                                expiry.as_mut().reset(Instant::now() + lease_timeout);
                            }
                            Err(error) => {
                                let _ = reply.send(Err(TerminalResizeError::Io(error.to_string())));
                                break LeaseEnd::CommandFailed;
                            }
                        }
                    }
                    Some(LeaseCommand::Release { reply }) => break LeaseEnd::Release(reply),
                    None => break LeaseEnd::Expired,
                }
            }
            () = &mut expiry => break LeaseEnd::Expired,
        }
    };

    let (result, release_reply) = match end {
        LeaseEnd::ControllerExited(status) => (finish_exited(status, controller).await, None),
        LeaseEnd::Release(reply) => (finish_with_release(controller).await, Some(reply)),
        LeaseEnd::Expired | LeaseEnd::CommandFailed => {
            (finish_with_release(controller).await, None)
        }
    };
    if let Some(reply) = release_reply {
        let _ = reply.send(result);
    }
    inner.leases.lock().await.remove(&lease_id);
}

async fn finish_exited(
    status: std::io::Result<std::process::ExitStatus>,
    controller: StartedController,
) -> Result<(), TerminalResizeError> {
    let status = status.map_err(|error| TerminalResizeError::Io(error.to_string()))?;
    let _ = controller.stdout_task.await;
    let stderr = controller.stderr_task.await.unwrap_or_default();
    if status.success() {
        Ok(())
    } else {
        Err(TerminalResizeError::Process(if stderr.is_empty() {
            status.to_string()
        } else {
            stderr
        }))
    }
}

async fn finish_with_release(mut controller: StartedController) -> Result<(), TerminalResizeError> {
    let write_result = async {
        controller
            .stdin
            .write_all(b"{\"type\":\"terminal.release\"}\n")
            .await?;
        controller.stdin.shutdown().await
    }
    .await;
    if let Err(error) = write_result {
        let _ = controller.child.kill().await;
        let _ = controller.child.wait().await;
        return Err(TerminalResizeError::Io(error.to_string()));
    }

    let result = match timeout(COMMAND_TIMEOUT, controller.child.wait()).await {
        Ok(Ok(status)) if status.success() => Ok(()),
        Ok(Ok(status)) => Err(TerminalResizeError::Process(status.to_string())),
        Ok(Err(error)) => Err(TerminalResizeError::Io(error.to_string())),
        Err(_) => {
            let _ = controller.child.kill().await;
            let _ = controller.child.wait().await;
            Err(TerminalResizeError::Timeout)
        }
    };
    let _ = controller.stdout_task.await;
    let stderr = controller.stderr_task.await.unwrap_or_default();
    result.map_err(|error| match error {
        TerminalResizeError::Process(_) if !stderr.is_empty() => {
            TerminalResizeError::Process(stderr)
        }
        error => error,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    fn make_fake_controller(body: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("herdr");
        std::fs::write(&path, body).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        (dir, path)
    }

    #[cfg(unix)]
    fn controller_script() -> &'static str {
        r#"#!/bin/sh
capture=$(dirname -- "$0")/capture
printf 'socket=%s\n' "$HERDR_SOCKET_PATH" > "$capture"
for argument in "$@"; do printf 'arg=%s\n' "$argument" >> "$capture"; done
printf '%s\n' '{"type":"terminal.frame","data":""}'
while IFS= read -r command; do
  printf 'stdin=%s\n' "$command" >> "$capture"
  [ "$command" = '{"type":"terminal.release"}' ] && exit 0
done
"#
    }

    #[cfg(unix)]
    async fn wait_for_capture(path: &Path, needle: &str) {
        timeout(Duration::from_secs(2), async {
            loop {
                let capture = std::fs::read_to_string(path).unwrap_or_default();
                if capture.contains(needle) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn holds_resizes_and_releases_controller() {
        let (dir, herdr_bin) = make_fake_controller(controller_script());
        let socket = dir.path().join("session.sock");
        let manager = TerminalLeaseManager::new(herdr_bin);

        let lease = manager.acquire(&socket, "w1:p3", 48, 31).await.unwrap();
        let capture_path = dir.path().join("capture");
        let capture = std::fs::read_to_string(&capture_path).unwrap();
        assert!(capture.contains("arg=--takeover\n"));
        assert!(!capture.contains("terminal.release"));

        manager
            .resize(&lease, &socket, "w1:p3", 72, 24)
            .await
            .unwrap();
        wait_for_capture(&capture_path, "terminal.resize").await;
        manager.release(&lease, &socket, "w1:p3").await.unwrap();

        let capture = std::fs::read_to_string(capture_path).unwrap();
        assert!(capture.contains("stdin={\"type\":\"terminal.resize\",\"cols\":72,\"rows\":24}\n"));
        assert!(capture.contains("stdin={\"type\":\"terminal.release\"}\n"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn releases_controller_when_lease_expires() {
        let (dir, herdr_bin) = make_fake_controller(controller_script());
        let manager = TerminalLeaseManager::with_timeout(herdr_bin, Duration::from_millis(50));
        let socket = dir.path().join("session.sock");

        manager.acquire(&socket, "w1:p3", 48, 31).await.unwrap();

        wait_for_capture(&dir.path().join("capture"), "terminal.release").await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reports_controller_start_failure() {
        let (_dir, herdr_bin) =
            make_fake_controller("#!/bin/sh\nprintf 'controller failed\\n' >&2\nexit 1\n");
        let manager = TerminalLeaseManager::new(herdr_bin);

        let error = manager
            .acquire(Path::new("/tmp/test.sock"), "w1:p3", 48, 31)
            .await
            .unwrap_err();

        assert!(error.to_string().contains("controller failed"));
    }
}
