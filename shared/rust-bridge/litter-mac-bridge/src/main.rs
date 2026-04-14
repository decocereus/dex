use std::collections::BTreeMap;
use std::env;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use litter_mac_bridge_core::codex_transport::{StdioCodexTransport, StdioCodexTransportConfig};
use litter_mac_bridge_core::protocol::LITTER_PAIRING_QR_VERSION;
use litter_mac_bridge_core::protocol::PairingPayload;
use litter_mac_bridge_core::device_state::{BridgeDeviceStateStore, resolve_bridge_relay_session};
use litter_mac_bridge_core::runtime::{BridgeRuntime, BridgeRuntimeError};
use qrcode::QrCode;
use qrcode::render::unicode;
use rand_core::{OsRng, RngCore};
use serde::Serialize;
use thiserror::Error;
use tokio::signal;
use tokio::time::interval;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

mod local_pairing;

use local_pairing::{
    LocalPairingConfig, LocalPairingHandle, PairingMode, PairingSession, rewrite_loopback_relay_url,
    start_local_pairing_service,
};

#[derive(Debug, Error)]
enum MainError {
    #[error("LITTER_BRIDGE_RELAY must be set to a ws:// or wss:// relay base URL")]
    MissingRelayUrl,
    #[error("invalid relay URL: {0}")]
    InvalidRelayUrl(String),
    #[error("failed to open bridge websocket: {0}")]
    Connect(String),
    #[error(transparent)]
    DeviceState(#[from] litter_mac_bridge_core::device_state::BridgeDeviceStateError),
    #[error(transparent)]
    Runtime(#[from] BridgeRuntimeError),
    #[error("websocket transport error: {0}")]
    WebSocket(String),
    #[error("serialization error: {0}")]
    Serialization(String),
    #[error("local pairing service error: {0}")]
    LocalPairing(String),
}

#[derive(Debug, Clone)]
struct BridgeConfig {
    relay_url: String,
    codex_command: String,
    codex_args: Vec<String>,
    codex_home: Option<String>,
    working_dir: Option<PathBuf>,
    local_pairing_enabled: bool,
    local_pairing_mode: PairingMode,
    local_pairing_bind_addr: std::net::SocketAddr,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RelayMacRegistration<'a> {
    session_id: &'a str,
    mac_device_id: &'a str,
    mac_identity_public_key: &'a str,
    display_name: Option<String>,
    trusted_phone_device_id: Option<&'a str>,
    trusted_phone_public_key: Option<&'a str>,
    pairing_code: &'a str,
    pairing_version: u32,
    pairing_expires_at: i64,
}

#[derive(Debug, Serialize)]
struct RelayMacRegistrationEnvelope<'a> {
    kind: &'static str,
    registration: RelayMacRegistration<'a>,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<(), MainError> {
    let config = BridgeConfig::from_env()?;
    let store = BridgeDeviceStateStore::new(BridgeDeviceStateStore::default_path());
    let device_state = store.load_or_create()?;
    let relay_session = resolve_bridge_relay_session();
    let relay_session_url = build_relay_session_url(&config.relay_url, &relay_session.session_id)?;

    let codex_transport = StdioCodexTransport::spawn(StdioCodexTransportConfig {
        command: config.codex_command.clone(),
        args: config.codex_args.clone(),
        current_dir: config.working_dir.clone(),
        env: config.codex_env(),
    })
    .await
    .map_err(BridgeRuntimeError::from)?;

    let mut runtime = BridgeRuntime::new(
        config.relay_url.clone(),
        relay_session.session_id.clone(),
        device_state,
        codex_transport,
    );
    let pairing_session = PairingSession {
        payload: runtime.pairing_payload(),
        pairing_code: generate_pairing_code(10),
    };
    let shared_pairing_session = Arc::new(tokio::sync::RwLock::new(pairing_session.clone()));

    let qr_pairing_session = PairingSession {
        payload: PairingPayload {
            relay: rewrite_loopback_relay_url(&pairing_session.payload.relay),
            ..pairing_session.payload.clone()
        },
        pairing_code: pairing_session.pairing_code.clone(),
    };

    println!(
        "[litter-mac-bridge] Pairing payload:\n{}",
        serde_json::to_string_pretty(&qr_pairing_session.payload)
            .map_err(|error| MainError::Serialization(error.to_string()))?
    );
    print_pairing_qr(&qr_pairing_session)
        .map_err(|error| MainError::Serialization(error.to_string()))?;
    println!(
        "[litter-mac-bridge] Pairing code: {}",
        pairing_session.pairing_code
    );
    println!("[litter-mac-bridge] Relay session URL: {relay_session_url}");

    let local_pairing_handle: Option<LocalPairingHandle> = if config.local_pairing_enabled {
        let (handle, local_addr) = start_local_pairing_service(
            LocalPairingConfig {
                bind_addr: config.local_pairing_bind_addr,
                display_name: machine_name().unwrap_or_else(|| "Litter Mac".to_string()),
                pairing_mode: config.local_pairing_mode,
            },
            shared_pairing_session,
        )
        .await
        .map_err(|error| MainError::LocalPairing(error.to_string()))?;
        println!(
            "[litter-mac-bridge] Local pairing service listening on http://{}:{} ({})",
            local_addr.ip(),
            local_addr.port(),
            config.local_pairing_mode.as_str()
        );
        Some(handle)
    } else {
        None
    };

    let mut request = relay_session_url
        .into_client_request()
        .map_err(|error| MainError::Connect(error.to_string()))?;
    let headers = request.headers_mut();
    headers.insert("x-role", "mac".parse().expect("static header"));
    headers.insert(
        "x-mac-device-id",
        HeaderValue::from_str(&runtime.device_state().mac_device_id)
            .map_err(|error| MainError::WebSocket(error.to_string()))?,
    );
    headers.insert(
        "x-mac-identity-public-key",
        HeaderValue::from_str(&runtime.device_state().mac_identity_public_key)
            .map_err(|error| MainError::WebSocket(error.to_string()))?,
    );
    if let Some(machine_name) = machine_name() {
        headers.insert(
            "x-machine-name",
            HeaderValue::from_str(&machine_name)
                .map_err(|error| MainError::WebSocket(error.to_string()))?,
        );
    }
    headers.insert(
        "x-pairing-code",
        HeaderValue::from_str(&pairing_session.pairing_code)
            .map_err(|error| MainError::WebSocket(error.to_string()))?,
    );
    headers.insert(
        "x-pairing-version",
        HeaderValue::from_str(&LITTER_PAIRING_QR_VERSION.to_string())
            .map_err(|error| MainError::WebSocket(error.to_string()))?,
    );
    headers.insert(
        "x-pairing-expires-at",
        HeaderValue::from_str(&pairing_session.payload.expires_at.to_string())
            .map_err(|error| MainError::WebSocket(error.to_string()))?,
    );
    if let Some((device_id, public_key)) = first_trusted_phone(&runtime) {
        headers.insert(
            "x-trusted-phone-device-id",
            HeaderValue::from_str(device_id)
                .map_err(|error| MainError::WebSocket(error.to_string()))?,
        );
        headers.insert(
            "x-trusted-phone-public-key",
            HeaderValue::from_str(public_key)
                .map_err(|error| MainError::WebSocket(error.to_string()))?,
        );
    }

    let (mut ws_stream, _) = connect_async(request)
        .await
        .map_err(|error| MainError::Connect(error.to_string()))?;

    send_registration(&mut ws_stream, &runtime, &pairing_session).await?;

    let mut drain_interval = interval(Duration::from_millis(100));
    loop {
        tokio::select! {
            _ = signal::ctrl_c() => {
                if let Some(handle) = local_pairing_handle {
                    handle.shutdown().await;
                }
                runtime.shutdown().await?;
                break;
            }
            _ = drain_interval.tick() => {
                forward_runtime_output(&mut ws_stream, &mut runtime).await?;
                persist_state_if_needed(&store, &mut ws_stream, &mut runtime, &pairing_session).await?;
            }
            message = ws_stream.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        let outbound = runtime.ingest_relay_wire_text(&text).await?;
                        for payload in outbound {
                            ws_stream.send(Message::Text(payload.into())).await.map_err(|error| MainError::WebSocket(error.to_string()))?;
                        }
                        forward_runtime_output(&mut ws_stream, &mut runtime).await?;
                        persist_state_if_needed(&store, &mut ws_stream, &mut runtime, &pairing_session).await?;
                    }
                    Some(Ok(Message::Binary(binary))) => {
                        let text = String::from_utf8(binary.to_vec())
                            .map_err(|error| MainError::WebSocket(error.to_string()))?;
                        let outbound = runtime.ingest_relay_wire_text(&text).await?;
                        for payload in outbound {
                            ws_stream.send(Message::Text(payload.into())).await.map_err(|error| MainError::WebSocket(error.to_string()))?;
                        }
                        forward_runtime_output(&mut ws_stream, &mut runtime).await?;
                        persist_state_if_needed(&store, &mut ws_stream, &mut runtime, &pairing_session).await?;
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        ws_stream.send(Message::Pong(payload)).await.map_err(|error| MainError::WebSocket(error.to_string()))?;
                    }
                    Some(Ok(Message::Close(frame))) => {
                        if let Some(frame) = frame {
                            return Err(MainError::WebSocket(format!("relay closed: {} ({})", frame.reason, frame.code)));
                        }
                        return Err(MainError::WebSocket("relay closed".to_string()));
                    }
                    Some(Ok(_)) => {}
                    Some(Err(error)) => return Err(MainError::WebSocket(error.to_string())),
                    None => return Err(MainError::WebSocket("relay stream ended".to_string())),
                }
            }
        }
    }

    Ok(())
}

impl BridgeConfig {
    fn from_env() -> Result<Self, MainError> {
        let relay_url = env::var("LITTER_BRIDGE_RELAY")
            .ok()
            .map(|value| value.trim().trim_end_matches('/').to_string())
            .filter(|value| !value.is_empty())
            .ok_or(MainError::MissingRelayUrl)?;
        if !relay_url.starts_with("ws://") && !relay_url.starts_with("wss://") {
            return Err(MainError::InvalidRelayUrl(relay_url));
        }

        let codex_command = env::var("LITTER_BRIDGE_CODEX_COMMAND")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "codex".to_string());
        let codex_args = env::var("LITTER_BRIDGE_CODEX_ARGS")
            .ok()
            .map(|value| {
                value
                    .split_whitespace()
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| vec!["app-server".to_string()]);
        let codex_home = env::var("LITTER_BRIDGE_CODEX_HOME")
            .ok()
            .filter(|value| !value.trim().is_empty());
        let working_dir = env::var("LITTER_BRIDGE_WORKING_DIR")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from);
        let local_pairing_enabled = env::var("LITTER_BRIDGE_LOCAL_PAIRING")
            .ok()
            .map(|value| matches!(value.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
            .unwrap_or(true);
        let local_pairing_mode = match env::var("LITTER_BRIDGE_LOCAL_PAIRING_MODE")
            .ok()
            .map(|value| value.trim().to_ascii_lowercase())
            .as_deref()
        {
            Some("auto") => PairingMode::AutoApprove,
            _ => PairingMode::PairingCode,
        };
        let local_pairing_bind_addr = env::var("LITTER_BRIDGE_LOCAL_PAIRING_BIND")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or_else(|| "0.0.0.0:56609".parse().expect("static bind addr"));

        Ok(Self {
            relay_url,
            codex_command,
            codex_args,
            codex_home,
            working_dir,
            local_pairing_enabled,
            local_pairing_mode,
            local_pairing_bind_addr,
        })
    }

    fn codex_env(&self) -> BTreeMap<String, String> {
        let mut envs = BTreeMap::new();
        if let Some(codex_home) = &self.codex_home {
            envs.insert("CODEX_HOME".to_string(), codex_home.clone());
        }
        envs
    }
}

async fn forward_runtime_output(
    ws_stream: &mut tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    runtime: &mut BridgeRuntime<StdioCodexTransport>,
) -> Result<(), MainError> {
    let outbound = runtime.drain_codex_output()?;
    for payload in outbound {
        ws_stream
            .send(Message::Text(payload.into()))
            .await
            .map_err(|error| MainError::WebSocket(error.to_string()))?;
    }
    Ok(())
}

async fn persist_state_if_needed(
    store: &BridgeDeviceStateStore,
    ws_stream: &mut tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    runtime: &mut BridgeRuntime<StdioCodexTransport>,
    pairing_session: &PairingSession,
) -> Result<(), MainError> {
    if !runtime.device_state_dirty() {
        return Ok(());
    }

    store.save(runtime.device_state())?;
    runtime.clear_device_state_dirty();
    send_registration(ws_stream, runtime, pairing_session).await?;
    Ok(())
}

async fn send_registration(
    ws_stream: &mut tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    runtime: &BridgeRuntime<StdioCodexTransport>,
    pairing_session: &PairingSession,
) -> Result<(), MainError> {
    let trusted_phone = first_trusted_phone(runtime);

    let registration = RelayMacRegistrationEnvelope {
        kind: "relayMacRegistration",
        registration: RelayMacRegistration {
            session_id: runtime.session_id(),
            mac_device_id: &runtime.device_state().mac_device_id,
            mac_identity_public_key: &runtime.device_state().mac_identity_public_key,
            display_name: machine_name(),
            trusted_phone_device_id: trusted_phone.map(|(device_id, _)| device_id),
            trusted_phone_public_key: trusted_phone.map(|(_, public_key)| public_key),
            pairing_code: &pairing_session.pairing_code,
            pairing_version: LITTER_PAIRING_QR_VERSION,
            pairing_expires_at: pairing_session.payload.expires_at,
        },
    };

    let payload = serde_json::to_string(&registration)
        .map_err(|error| MainError::Serialization(error.to_string()))?;
    ws_stream
        .send(Message::Text(payload.into()))
        .await
        .map_err(|error| MainError::WebSocket(error.to_string()))?;
    Ok(())
}

fn build_relay_session_url(relay_url: &str, session_id: &str) -> Result<String, MainError> {
    let relay_url = relay_url.trim().trim_end_matches('/');
    if relay_url.is_empty() {
        return Err(MainError::MissingRelayUrl);
    }
    Ok(format!("{relay_url}/{session_id}"))
}

fn machine_name() -> Option<String> {
    env::var("HOSTNAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
}

fn first_trusted_phone(
    runtime: &BridgeRuntime<StdioCodexTransport>,
) -> Option<(&str, &str)> {
    runtime
        .device_state()
        .trusted_phones
        .iter()
        .next()
        .map(|(device_id, public_key)| (device_id.as_str(), public_key.as_str()))
}

fn generate_pairing_code(length: usize) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = OsRng;
    let mut bytes = vec![0u8; length];
    rng.fill_bytes(&mut bytes);
    bytes
        .into_iter()
        .map(|byte| ALPHABET[(byte as usize) % ALPHABET.len()] as char)
        .collect()
}

fn print_pairing_qr(pairing_session: &PairingSession) -> Result<(), serde_json::Error> {
    let payload = serde_json::to_string(&pairing_session.payload)?;
    if let Ok(code) = QrCode::new(payload.as_bytes()) {
        let rendered = code.render::<unicode::Dense1x2>().build();
        println!("\n[litter-mac-bridge] Scan this QR with the iPhone app:\n");
        println!("{rendered}");
    }
    Ok(())
}
