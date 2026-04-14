use std::collections::BTreeMap;
use std::io;
use std::path::PathBuf;

use async_trait::async_trait;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::mpsc;
use tracing::{debug, warn};

#[async_trait]
pub trait CodexTransport: Send {
    async fn send_line(&mut self, line: String) -> io::Result<()>;
    fn try_recv_line(&mut self) -> io::Result<Option<String>>;
    async fn shutdown(&mut self) -> io::Result<()>;
}

#[derive(Debug, Clone)]
pub struct StdioCodexTransportConfig {
    pub command: String,
    pub args: Vec<String>,
    pub current_dir: Option<PathBuf>,
    pub env: BTreeMap<String, String>,
}

impl Default for StdioCodexTransportConfig {
    fn default() -> Self {
        Self {
            command: "codex".to_string(),
            args: vec!["app-server".to_string()],
            current_dir: None,
            env: BTreeMap::new(),
        }
    }
}

pub struct StdioCodexTransport {
    child: Child,
    stdin: ChildStdin,
    line_rx: mpsc::UnboundedReceiver<String>,
}

impl StdioCodexTransport {
    pub async fn spawn(config: StdioCodexTransportConfig) -> io::Result<Self> {
        let mut command = Command::new(&config.command);
        command.args(&config.args);
        if let Some(current_dir) = &config.current_dir {
            command.current_dir(current_dir);
        }
        for (key, value) in &config.env {
            command.env(key, value);
        }
        command.stdin(std::process::Stdio::piped());
        command.stdout(std::process::Stdio::piped());
        command.stderr(std::process::Stdio::piped());

        let mut child = command.spawn()?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("codex stdin unavailable"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("codex stdout unavailable"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| io::Error::other("codex stderr unavailable"))?;

        let (line_tx, line_rx) = mpsc::unbounded_channel();

        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout).lines();
            loop {
                match reader.next_line().await {
                    Ok(Some(line)) => {
                        if !line.trim().is_empty() && line_tx.send(line).is_err() {
                            break;
                        }
                    }
                    Ok(None) => break,
                    Err(error) => {
                        warn!(%error, "codex stdout reader failed");
                        break;
                    }
                }
            }
        });

        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr).lines();
            loop {
                match reader.next_line().await {
                    Ok(Some(line)) => debug!("codex stderr: {line}"),
                    Ok(None) => break,
                    Err(error) => {
                        warn!(%error, "codex stderr reader failed");
                        break;
                    }
                }
            }
        });

        Ok(Self {
            child,
            stdin,
            line_rx,
        })
    }
}

#[async_trait]
impl CodexTransport for StdioCodexTransport {
    async fn send_line(&mut self, line: String) -> io::Result<()> {
        self.stdin.write_all(line.as_bytes()).await?;
        self.stdin.write_all(b"\n").await?;
        self.stdin.flush().await
    }

    fn try_recv_line(&mut self) -> io::Result<Option<String>> {
        match self.line_rx.try_recv() {
            Ok(line) => Ok(Some(line)),
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => Ok(None),
            Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => Ok(None),
        }
    }

    async fn shutdown(&mut self) -> io::Result<()> {
        if self.child.id().is_some() {
            let _ = self.child.start_kill();
            let _ = self.child.wait().await?;
        }
        Ok(())
    }
}
