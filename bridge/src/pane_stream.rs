use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket};
use serde::Serialize;
use tokio::time::Instant;

use crate::herdr::types::PaneReadResult;
use crate::http::SessionRuntime;

const ACK_TIMEOUT: Duration = Duration::from_secs(10);
const SEND_TIMEOUT: Duration = Duration::from_secs(2);
const AUTO_ACTIVE_INTERVAL: Duration = Duration::from_millis(50);
const AUTO_IDLE_INTERVAL: Duration = Duration::from_millis(250);
const AUTO_ACTIVE_WINDOW: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PaneStreamRate {
    Automatic,
    Fixed(Duration),
}

impl PaneStreamRate {
    pub fn from_interval_ms(interval_ms: Option<u64>) -> Self {
        match interval_ms {
            Some(milliseconds @ (50 | 100 | 250)) => {
                PaneStreamRate::Fixed(Duration::from_millis(milliseconds))
            }
            _ => PaneStreamRate::Automatic,
        }
    }

    fn delay(self, last_change: Instant) -> Duration {
        match self {
            PaneStreamRate::Automatic if last_change.elapsed() < AUTO_ACTIVE_WINDOW => {
                AUTO_ACTIVE_INTERVAL
            }
            PaneStreamRate::Automatic => AUTO_IDLE_INTERVAL,
            PaneStreamRate::Fixed(delay) => delay,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PaneFrame {
    pane_id: String,
    text: String,
    truncated: bool,
    revision: u64,
    fingerprint: String,
}

impl PaneFrame {
    fn from_read(pane_id: &str, read: PaneReadResult) -> Self {
        let fingerprint = format!("{:x}", wyhash::wyhash(read.text.as_bytes(), 0));
        PaneFrame {
            pane_id: pane_id.to_string(),
            text: read.text,
            truncated: read.truncated,
            revision: read.revision,
            fingerprint,
        }
    }

    fn display_eq(&self, other: &Self) -> bool {
        self.fingerprint == other.fingerprint && self.truncated == other.truncated
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum ServerMessage {
    #[serde(rename = "pane_full")]
    Full {
        #[serde(rename = "paneId")]
        pane_id: String,
        text: String,
        truncated: bool,
        revision: u64,
        fingerprint: String,
    },
    #[serde(rename = "pane_delta")]
    Delta {
        #[serde(rename = "paneId")]
        pane_id: String,
        #[serde(rename = "baseFingerprint")]
        base_fingerprint: String,
        fingerprint: String,
        #[serde(rename = "startLine")]
        start_line: usize,
        #[serde(rename = "deleteLines")]
        delete_lines: usize,
        #[serde(rename = "insertLines")]
        insert_lines: Vec<String>,
        truncated: bool,
        revision: u64,
    },
    #[serde(rename = "pane_error")]
    Error { code: &'static str, error: String },
}

impl ServerMessage {
    fn full(frame: &PaneFrame) -> Self {
        ServerMessage::Full {
            pane_id: frame.pane_id.clone(),
            text: frame.text.clone(),
            truncated: frame.truncated,
            revision: frame.revision,
            fingerprint: frame.fingerprint.clone(),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
struct LineDelta {
    start_line: usize,
    delete_lines: usize,
    insert_lines: Vec<String>,
}

fn line_delta(before: &str, after: &str) -> LineDelta {
    let before: Vec<&str> = before.split('\n').collect();
    let after: Vec<&str> = after.split('\n').collect();
    let prefix = before
        .iter()
        .zip(&after)
        .take_while(|(left, right)| left == right)
        .count();
    let suffix = before[prefix..]
        .iter()
        .rev()
        .zip(after[prefix..].iter().rev())
        .take_while(|(left, right)| left == right)
        .count();
    LineDelta {
        start_line: prefix,
        delete_lines: before.len() - prefix - suffix,
        insert_lines: after[prefix..after.len() - suffix]
            .iter()
            .map(|line| (*line).to_string())
            .collect(),
    }
}

fn update_message(base: &PaneFrame, current: &PaneFrame) -> ServerMessage {
    let patch = line_delta(&base.text, &current.text);
    let delta = ServerMessage::Delta {
        pane_id: current.pane_id.clone(),
        base_fingerprint: base.fingerprint.clone(),
        fingerprint: current.fingerprint.clone(),
        start_line: patch.start_line,
        delete_lines: patch.delete_lines,
        insert_lines: patch.insert_lines,
        truncated: current.truncated,
        revision: current.revision,
    };
    let full = ServerMessage::full(current);
    if encoded_len(&delta) < encoded_len(&full) {
        delta
    } else {
        full
    }
}

fn encoded_len(message: &ServerMessage) -> usize {
    serde_json::to_vec(message).map_or(usize::MAX, |value| value.len())
}

async fn send_message(socket: &mut WebSocket, message: &ServerMessage) -> Result<(), ()> {
    let text = serde_json::to_string(message).map_err(|_| ())?;
    tokio::time::timeout(SEND_TIMEOUT, socket.send(Message::Text(text.into())))
        .await
        .map_err(|_| ())?
        .map_err(|_| ())
}

enum ClientMessage {
    Applied(String),
    Resync,
    Closed,
    Other,
}

fn parse_client_message(message: Option<Result<Message, axum::Error>>) -> ClientMessage {
    let Some(Ok(message)) = message else {
        return ClientMessage::Closed;
    };
    match message {
        Message::Text(text) => {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
                return ClientMessage::Other;
            };
            match value.get("type").and_then(serde_json::Value::as_str) {
                Some("pane_applied") => value
                    .get("fingerprint")
                    .and_then(serde_json::Value::as_str)
                    .map(|value| ClientMessage::Applied(value.to_string()))
                    .unwrap_or(ClientMessage::Other),
                Some("pane_resync") => ClientMessage::Resync,
                _ => ClientMessage::Other,
            }
        }
        Message::Close(_) => ClientMessage::Closed,
        _ => ClientMessage::Other,
    }
}

async fn wait_for_applied(socket: &mut WebSocket, fingerprint: &str) -> Result<bool, ()> {
    tokio::time::timeout(ACK_TIMEOUT, async {
        loop {
            match parse_client_message(socket.recv().await) {
                ClientMessage::Applied(value) if value == fingerprint => return Ok(true),
                ClientMessage::Resync => return Ok(false),
                ClientMessage::Closed => return Err(()),
                _ => {}
            }
        }
    })
    .await
    .map_err(|_| ())?
}

async fn read_frame(
    runtime: &SessionRuntime,
    pane_id: &str,
    lines: u32,
) -> Result<PaneFrame, String> {
    runtime
        .client
        .pane_read(pane_id, "recent", Some(lines), "ansi")
        .await
        .map(|read| PaneFrame::from_read(pane_id, read))
        .map_err(|error| error.to_string())
}

#[derive(PartialEq, Eq)]
struct PaneProbe {
    revision: u64,
    fingerprint: u64,
}

async fn read_probe(runtime: &SessionRuntime, pane_id: &str) -> Result<PaneProbe, String> {
    runtime
        .client
        .pane_read(pane_id, "visible", None, "ansi")
        .await
        .map(|read| PaneProbe {
            revision: read.revision,
            fingerprint: wyhash::wyhash(read.text.as_bytes(), 0),
        })
        .map_err(|error| error.to_string())
}

pub async fn serve(
    mut socket: WebSocket,
    runtime: Arc<SessionRuntime>,
    pane_id: String,
    lines: u32,
    rate: PaneStreamRate,
) {
    // A small visible read is the change probe. The comparatively large
    // recent/ANSI snapshot is fetched only when that probe changes, matching
    // the relay's bounded watcher rather than transferring 200 lines at every
    // refresh tick.
    let mut probe_fingerprint = match read_probe(&runtime, &pane_id).await {
        Ok(fingerprint) => fingerprint,
        Err(error) => {
            let _ = send_message(
                &mut socket,
                &ServerMessage::Error {
                    code: "herdr_error",
                    error,
                },
            )
            .await;
            return;
        }
    };
    let mut current = match read_frame(&runtime, &pane_id, lines).await {
        Ok(frame) => frame,
        Err(error) => {
            let _ = send_message(
                &mut socket,
                &ServerMessage::Error {
                    code: "herdr_error",
                    error,
                },
            )
            .await;
            return;
        }
    };
    if send_message(&mut socket, &ServerMessage::full(&current))
        .await
        .is_err()
    {
        return;
    }
    if wait_for_applied(&mut socket, &current.fingerprint).await != Ok(true) {
        return;
    }

    let mut last_change = Instant::now();
    loop {
        let delay = rate.delay(last_change);
        tokio::select! {
            message = socket.recv() => {
                match parse_client_message(message) {
                    ClientMessage::Closed => return,
                    ClientMessage::Resync => {
                        if send_message(&mut socket, &ServerMessage::full(&current)).await.is_err() {
                            return;
                        }
                        if wait_for_applied(&mut socket, &current.fingerprint).await != Ok(true) {
                            return;
                        }
                    }
                    _ => {}
                }
                continue;
            }
            () = tokio::time::sleep(delay) => {}
        }

        let next_probe = match read_probe(&runtime, &pane_id).await {
            Ok(fingerprint) => fingerprint,
            Err(error) => {
                let _ = send_message(
                    &mut socket,
                    &ServerMessage::Error {
                        code: "herdr_error",
                        error,
                    },
                )
                .await;
                return;
            }
        };
        if next_probe == probe_fingerprint {
            continue;
        }
        probe_fingerprint = next_probe;

        let next = match read_frame(&runtime, &pane_id, lines).await {
            Ok(frame) => frame,
            Err(error) => {
                let _ = send_message(
                    &mut socket,
                    &ServerMessage::Error {
                        code: "herdr_error",
                        error,
                    },
                )
                .await;
                return;
            }
        };
        if current.display_eq(&next) {
            current.revision = current.revision.max(next.revision);
            continue;
        }

        let message = update_message(&current, &next);
        if send_message(&mut socket, &message).await.is_err() {
            return;
        }
        match wait_for_applied(&mut socket, &next.fingerprint).await {
            Ok(true) => {
                current = next;
                last_change = Instant::now();
            }
            Ok(false) => {
                if send_message(&mut socket, &ServerMessage::full(&next))
                    .await
                    .is_err()
                {
                    return;
                }
                if wait_for_applied(&mut socket, &next.fingerprint).await != Ok(true) {
                    return;
                }
                current = next;
                last_change = Instant::now();
            }
            Err(()) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(text: &str) -> PaneFrame {
        PaneFrame::from_read(
            "w1:p1",
            PaneReadResult {
                text: text.to_string(),
                truncated: false,
                revision: 1,
            },
        )
    }

    fn apply_delta(base: &str, delta: &LineDelta) -> String {
        let mut lines: Vec<String> = base.split('\n').map(str::to_string).collect();
        lines.splice(
            delta.start_line..delta.start_line + delta.delete_lines,
            delta.insert_lines.clone(),
        );
        lines.join("\n")
    }

    #[test]
    fn line_delta_reconstructs_append_replace_and_trailing_newline() {
        for (before, after) in [
            ("one\ntwo", "one\ntwo\nthree"),
            ("one\ntwo\nthree", "one\nTWO\nthree"),
            ("one\ntwo\n", "one\nTWO\n"),
            ("same", ""),
        ] {
            let delta = line_delta(before, after);
            assert_eq!(apply_delta(before, &delta), after);
        }
    }

    #[test]
    fn uses_delta_only_when_it_is_smaller_than_a_full_frame() {
        let base = frame(&format!("head\n{}\ntail", "unchanged\n".repeat(80)));
        let current = frame(&format!("head changed\n{}\ntail", "unchanged\n".repeat(80)));
        assert!(matches!(
            update_message(&base, &current),
            ServerMessage::Delta { .. }
        ));

        let unrelated = frame("short replacement");
        assert!(matches!(
            update_message(&base, &unrelated),
            ServerMessage::Full { .. }
        ));
    }

    #[test]
    fn accepts_only_supported_refresh_intervals() {
        assert_eq!(
            PaneStreamRate::from_interval_ms(None),
            PaneStreamRate::Automatic
        );
        assert_eq!(
            PaneStreamRate::from_interval_ms(Some(0)),
            PaneStreamRate::Automatic
        );
        assert_eq!(
            PaneStreamRate::from_interval_ms(Some(50)),
            PaneStreamRate::Fixed(Duration::from_millis(50))
        );
        assert_eq!(
            PaneStreamRate::from_interval_ms(Some(100)),
            PaneStreamRate::Fixed(Duration::from_millis(100))
        );
        assert_eq!(
            PaneStreamRate::from_interval_ms(Some(250)),
            PaneStreamRate::Fixed(Duration::from_millis(250))
        );
        assert_eq!(
            PaneStreamRate::from_interval_ms(Some(60)),
            PaneStreamRate::Automatic
        );
    }
}
