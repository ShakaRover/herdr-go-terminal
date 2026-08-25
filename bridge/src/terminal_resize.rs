use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

const RESIZE_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug)]
pub enum TerminalResizeError {
    Io(String),
    Protocol(String),
    Process(String),
    Timeout,
}

impl std::fmt::Display for TerminalResizeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TerminalResizeError::Io(message) => write!(f, "io: {message}"),
            TerminalResizeError::Protocol(message) => write!(f, "protocol: {message}"),
            TerminalResizeError::Process(message) => write!(f, "herdr: {message}"),
            TerminalResizeError::Timeout => write!(f, "timeout"),
        }
    }
}

impl std::error::Error for TerminalResizeError {}

/// Open a controller at the requested size, wait until Herdr emits its first
/// rendered frame, then release ownership. The PTY keeps the new dimensions
/// until another Herdr client reports a size.
pub async fn resize_once(
    herdr_bin: &Path,
    socket_path: &Path,
    pane_id: &str,
    cols: u16,
    rows: u16,
) -> Result<(), TerminalResizeError> {
    match tokio::time::timeout(
        RESIZE_TIMEOUT,
        resize_once_inner(herdr_bin, socket_path, pane_id, cols, rows),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => Err(TerminalResizeError::Timeout),
    }
}

async fn resize_once_inner(
    herdr_bin: &Path,
    socket_path: &Path,
    pane_id: &str,
    cols: u16,
    rows: u16,
) -> Result<(), TerminalResizeError> {
    let cols = cols.to_string();
    let rows = rows.to_string();
    let mut child = Command::new(herdr_bin)
        .args([
            "terminal", "session", "control", pane_id, "--cols", &cols, "--rows", &rows,
        ])
        .env("HERDR_SOCKET_PATH", socket_path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| TerminalResizeError::Io(error.to_string()))?;

    let mut stdin = child
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

    stdin
        .write_all(b"{\"type\":\"terminal.release\"}\n")
        .await
        .map_err(|error| TerminalResizeError::Io(error.to_string()))?;
    stdin
        .shutdown()
        .await
        .map_err(|error| TerminalResizeError::Io(error.to_string()))?;
    let status = child
        .wait()
        .await
        .map_err(|error| TerminalResizeError::Io(error.to_string()))?;
    let _ = stdout_task.await;
    let stderr = stderr_task.await.unwrap_or_default();
    if !status.success() {
        return Err(TerminalResizeError::Process(if stderr.is_empty() {
            status.to_string()
        } else {
            stderr
        }));
    }
    Ok(())
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
    #[tokio::test]
    async fn passes_size_and_socket_then_releases_controller() {
        let (dir, herdr_bin) = make_fake_controller(
            r#"#!/bin/sh
capture=$(dirname -- "$0")/capture
printf 'socket=%s\n' "$HERDR_SOCKET_PATH" > "$capture"
for argument in "$@"; do printf 'arg=%s\n' "$argument" >> "$capture"; done
printf '%s\n' '{"type":"terminal.frame","data":""}'
IFS= read -r command
printf 'stdin=%s\n' "$command" >> "$capture"
"#,
        );
        let socket = dir.path().join("session.sock");

        resize_once(&herdr_bin, &socket, "w1:p3", 48, 31)
            .await
            .unwrap();

        let capture = std::fs::read_to_string(dir.path().join("capture")).unwrap();
        assert_eq!(
            capture.lines().collect::<Vec<_>>(),
            [
                format!("socket={}", socket.display()),
                "arg=terminal".into(),
                "arg=session".into(),
                "arg=control".into(),
                "arg=w1:p3".into(),
                "arg=--cols".into(),
                "arg=48".into(),
                "arg=--rows".into(),
                "arg=31".into(),
                "stdin={\"type\":\"terminal.release\"}".into(),
            ]
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn reports_controller_start_failure() {
        let (_dir, herdr_bin) = make_fake_controller(
            "#!/bin/sh\nprintf 'controller already attached\\n' >&2\nexit 1\n",
        );

        let error = resize_once(&herdr_bin, Path::new("/tmp/test.sock"), "w1:p3", 48, 31)
            .await
            .unwrap_err();

        assert!(error.to_string().contains("controller already attached"));
    }
}
