use std::sync::Mutex;

use futures::{SinkExt, StreamExt};
use litter_mac_bridge_core::phone_identity::PhoneIdentityStore;
use litter_mac_bridge_core::protocol::{
    PairingPayload, SecureEnvelope, SecureReady, SecureServerHello, TrustedSessionResolveResponse,
};
use litter_mac_bridge_core::secure_relay_client::SecureRelayClient;
use serde_json::Value as JsonValue;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::accept_async;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tracing::{error, info, warn};

#[derive(Debug, thiserror::Error)]
pub enum SecureBridgeProxyError {
    #[error("invalid relay url: {0}")]
    InvalidRelayUrl(String),
    #[error("phone identity error: {0}")]
    PhoneIdentity(String),
    #[error("trusted session resolve failed: {0}")]
    TrustedSessionResolve(String),
    #[error("proxy transport failed: {0}")]
    Transport(String),
    #[error("handshake failed: {0}")]
    Handshake(String),
}

#[derive(Debug, Clone)]
pub struct PairedMacConfig {
    pub relay_url: String,
    pub relay_session_id: String,
    pub mac_device_id: String,
    pub mac_identity_public_key: String,
    pub trusted_reconnect: bool,
}

struct ProxyHandle {
    local_url: String,
    shutdown_tx: oneshot::Sender<()>,
    task: tokio::task::JoinHandle<()>,
}

pub struct SecureBridgeProxyManager {
    handle: Mutex<Option<ProxyHandle>>,
}

impl SecureBridgeProxyManager {
    pub fn new() -> Self {
        Self {
            handle: Mutex::new(None),
        }
    }

    pub async fn start_paired_mac_proxy(
        &self,
        config: PairedMacConfig,
    ) -> Result<String, SecureBridgeProxyError> {
        self.stop().await;
        info!(
            "secure-bridge-proxy: start paired mac proxy mac_device_id={} relay_url={} trusted_reconnect={}",
            config.mac_device_id, config.relay_url, config.trusted_reconnect
        );

        let identity_store = PhoneIdentityStore::new(PhoneIdentityStore::default_path());
        let phone_identity = identity_store
            .load_or_create()
            .map_err(|error| SecureBridgeProxyError::PhoneIdentity(error.to_string()))?;
        info!(
            "secure-bridge-proxy: loaded phone identity path={} phone_device_id={}",
            identity_store.path().display(),
            phone_identity.phone_device_id
        );

        let pairing_payload = resolve_pairing_payload(&phone_identity, &config).await?;
        info!(
            "secure-bridge-proxy: resolved pairing payload session_id={} mac_device_id={} relay={}",
            pairing_payload.session_id, pairing_payload.mac_device_id, pairing_payload.relay
        );

        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
        let local_addr = listener
            .local_addr()
            .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
        let local_url = format!("ws://127.0.0.1:{}", local_addr.port());

        let (shutdown_tx, mut shutdown_rx) = oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => {
                        break;
                    }
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { break; };
                        let pairing_payload = pairing_payload.clone();
                        let phone_identity = phone_identity.clone();
                        tokio::spawn(async move {
                            if let Err(error) = handle_local_client(
                                stream,
                                pairing_payload,
                                phone_identity,
                                config.trusted_reconnect,
                            )
                            .await
                            {
                                error!("secure-bridge-proxy: local client session failed: {}", error);
                            }
                        });
                    }
                }
            }
        });

        let mut guard = self
            .handle
            .lock()
            .map_err(|_| SecureBridgeProxyError::Transport("proxy manager lock poisoned".to_string()))?;
        *guard = Some(ProxyHandle {
            local_url: local_url.clone(),
            shutdown_tx,
            task,
        });
        info!(
            "secure-bridge-proxy: local proxy ready mac_device_id={} local_url={}",
            config.mac_device_id, local_url
        );
        Ok(local_url)
    }

    pub async fn stop(&self) {
        let handle = {
            let mut guard = match self.handle.lock() {
                Ok(guard) => guard,
                Err(error) => error.into_inner(),
            };
            guard.take()
        };

        if let Some(handle) = handle {
            info!("secure-bridge-proxy: stopping local proxy url={}", handle.local_url);
            let _ = handle.shutdown_tx.send(());
            handle.task.abort();
        }
    }

    pub fn active_local_url(&self) -> Option<String> {
        let guard = self.handle.lock().ok()?;
        guard.as_ref().map(|handle| handle.local_url.clone())
    }
}

async fn resolve_pairing_payload(
    phone_identity: &litter_mac_bridge_core::phone_identity::PhoneIdentityState,
    config: &PairedMacConfig,
) -> Result<PairingPayload, SecureBridgeProxyError> {
    if !config.trusted_reconnect {
        info!(
            "secure-bridge-proxy: trusted reconnect disabled, using saved session session_id={}",
            config.relay_session_id
        );
        return Ok(PairingPayload {
            v: 1,
            relay: config.relay_url.clone(),
            session_id: config.relay_session_id.clone(),
            mac_device_id: config.mac_device_id.clone(),
            mac_identity_public_key: config.mac_identity_public_key.clone(),
            expires_at: i64::MAX,
        });
    }

    let client = SecureRelayClient::new(phone_identity.clone());
    let nonce = uuid::Uuid::new_v4().to_string();
    let timestamp = current_timestamp_ms();
    let request = client
        .build_trusted_session_resolve_request(config.mac_device_id.clone(), timestamp, nonce)
        .map_err(|error| SecureBridgeProxyError::TrustedSessionResolve(error.to_string()))?;
    let resolve_url = trusted_session_resolve_url(&config.relay_url)?;

    let http_client = reqwest::Client::new();
    let response = http_client
        .post(resolve_url)
        .json(&request)
        .send()
        .await
        .map_err(|error| SecureBridgeProxyError::TrustedSessionResolve(error.to_string()))?;
    if !response.status().is_success() {
        let body = response.text().await.unwrap_or_default();
        warn!(
            "secure-bridge-proxy: trusted session resolve failed mac_device_id={} body={}",
            config.mac_device_id, body
        );
        return Err(SecureBridgeProxyError::TrustedSessionResolve(body));
    }
    let resolved: TrustedSessionResolveResponse = response
        .json()
        .await
        .map_err(|error| SecureBridgeProxyError::TrustedSessionResolve(error.to_string()))?;
    client
        .apply_trusted_session_resolve_response(resolved, config.relay_url.clone())
        .map_err(|error| SecureBridgeProxyError::TrustedSessionResolve(error.to_string()))
}

async fn handle_local_client(
    stream: tokio::net::TcpStream,
    pairing_payload: PairingPayload,
    phone_identity: litter_mac_bridge_core::phone_identity::PhoneIdentityState,
    trusted_reconnect: bool,
) -> Result<(), SecureBridgeProxyError> {
    let mut local_ws = accept_async(stream)
        .await
        .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
    info!(
        "secure-bridge-proxy: accepted local websocket client session_id={}",
        pairing_payload.session_id
    );
    let relay_session_url = format!(
        "{}/{}",
        pairing_payload.relay.trim_end_matches('/'),
        pairing_payload.session_id
    );
    let mut relay_request = relay_session_url
        .into_client_request()
        .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
    relay_request
        .headers_mut()
        .insert("x-role", HeaderValue::from_static("iphone"));
    let (mut relay_ws, _) = connect_async(relay_request)
        .await
        .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
    info!(
        "secure-bridge-proxy: connected relay websocket session_id={} trusted_reconnect={}",
        pairing_payload.session_id, trusted_reconnect
    );

    let mut secure_client = SecureRelayClient::new(phone_identity);
    let hello = secure_client
        .begin_handshake(pairing_payload.clone(), trusted_reconnect)
        .map_err(|error| SecureBridgeProxyError::Handshake(error.to_string()))?;
    relay_ws
        .send(Message::Text(
            serde_json::to_string(&hello)
                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?
                .into(),
        ))
        .await
        .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;

    let mut handshake_complete = false;
    while !handshake_complete {
        let Some(message) = relay_ws.next().await else {
            error!(
                "secure-bridge-proxy: relay closed during handshake session_id={}",
                pairing_payload.session_id
            );
            return Err(SecureBridgeProxyError::Handshake(
                "relay closed during handshake".to_string(),
            ));
        };
        let message = message.map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
        if let Some(text) = websocket_text(message)? {
            match secure_message_kind(&text).as_deref() {
                Some("serverHello") => {
                    let server_hello: SecureServerHello = serde_json::from_str(&text)
                        .map_err(|error| SecureBridgeProxyError::Handshake(error.to_string()))?;
                    let client_auth = secure_client
                        .handle_server_hello(server_hello)
                        .map_err(|error| SecureBridgeProxyError::Handshake(error.to_string()))?;
                    relay_ws
                        .send(Message::Text(
                            serde_json::to_string(&client_auth)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?
                                .into(),
                        ))
                        .await
                        .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                }
                Some("secureReady") => {
                    let ready: SecureReady = serde_json::from_str(&text)
                        .map_err(|error| SecureBridgeProxyError::Handshake(error.to_string()))?;
                    let resume = secure_client
                        .finalize_handshake(ready, 0)
                        .map_err(|error| SecureBridgeProxyError::Handshake(error.to_string()))?;
                    relay_ws
                        .send(Message::Text(
                            serde_json::to_string(&resume)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?
                                .into(),
                        ))
                        .await
                        .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                    handshake_complete = true;
                    info!(
                        "secure-bridge-proxy: secure handshake completed session_id={}",
                        pairing_payload.session_id
                    );
                }
                Some("secureError") => {
                    error!(
                        "secure-bridge-proxy: secure error during handshake session_id={} payload={}",
                        pairing_payload.session_id, text
                    );
                    return Err(SecureBridgeProxyError::Handshake(text));
                }
                _ => {}
            }
        }
    }

    loop {
        tokio::select! {
            local_message = local_ws.next() => {
                let Some(local_message) = local_message else { break; };
                let local_message = local_message.map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                match local_message {
                    Message::Text(text) => {
                        let envelope = secure_client
                            .encrypt_application_message(text.to_string())
                            .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                        relay_ws.send(Message::Text(
                            serde_json::to_string(&envelope)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?
                                .into()
                        )).await.map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                    }
                    Message::Binary(binary) => {
                        let text = String::from_utf8(binary.to_vec())
                            .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                        let envelope = secure_client
                            .encrypt_application_message(text)
                            .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                        relay_ws.send(Message::Text(
                            serde_json::to_string(&envelope)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?
                                .into()
                        )).await.map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                    }
                    Message::Ping(payload) => {
                        local_ws.send(Message::Pong(payload)).await.map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                    }
                    Message::Close(frame) => {
                        let _ = relay_ws.send(Message::Close(frame)).await;
                        break;
                    }
                    _ => {}
                }
            }
            relay_message = relay_ws.next() => {
                let Some(relay_message) = relay_message else { break; };
                let relay_message = relay_message.map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                match relay_message {
                    Message::Text(text) => {
                        if secure_message_kind(&text).as_deref() == Some("encryptedEnvelope") {
                            let envelope: SecureEnvelope = serde_json::from_str(&text)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                            let payload = secure_client
                                .decrypt_application_message(envelope)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                            local_ws
                                .send(Message::Text(payload.payload_text.into()))
                                .await
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                        } else if secure_message_kind(&text).as_deref() == Some("secureError") {
                            return Err(SecureBridgeProxyError::Transport(text.to_string()));
                        }
                    }
                    Message::Binary(binary) => {
                        let text = String::from_utf8(binary.to_vec())
                            .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                        if secure_message_kind(&text).as_deref() == Some("encryptedEnvelope") {
                            let envelope: SecureEnvelope = serde_json::from_str(&text)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                            let payload = secure_client
                                .decrypt_application_message(envelope)
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                            local_ws
                                .send(Message::Text(payload.payload_text.into()))
                                .await
                                .map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                        }
                    }
                    Message::Ping(payload) => {
                        relay_ws.send(Message::Pong(payload)).await.map_err(|error| SecureBridgeProxyError::Transport(error.to_string()))?;
                    }
                    Message::Close(frame) => {
                        let _ = local_ws.send(Message::Close(frame)).await;
                        break;
                    }
                    _ => {}
                }
            }
        }
    }

    Ok(())
}

fn secure_message_kind(text: &str) -> Option<String> {
    serde_json::from_str::<JsonValue>(text)
        .ok()
        .and_then(|value| value.get("kind").and_then(JsonValue::as_str).map(str::to_string))
}

fn websocket_text(message: Message) -> Result<Option<String>, SecureBridgeProxyError> {
    match message {
        Message::Text(text) => Ok(Some(text.to_string())),
        Message::Binary(binary) => String::from_utf8(binary.to_vec())
            .map(Some)
            .map_err(|error| SecureBridgeProxyError::Transport(error.to_string())),
        Message::Ping(_) | Message::Pong(_) => Ok(None),
        Message::Close(_) => Ok(None),
        _ => Ok(None),
    }
}

fn trusted_session_resolve_url(relay_url: &str) -> Result<reqwest::Url, SecureBridgeProxyError> {
    let mut url = reqwest::Url::parse(relay_url)
        .map_err(|error| SecureBridgeProxyError::InvalidRelayUrl(error.to_string()))?;
    match url.scheme() {
        "ws" => {
            let _ = url.set_scheme("http");
        }
        "wss" => {
            let _ = url.set_scheme("https");
        }
        "http" | "https" => {}
        _ => {
            return Err(SecureBridgeProxyError::InvalidRelayUrl(
                "unsupported relay URL scheme".to_string(),
            ));
        }
    }

    let mut segments: Vec<String> = url
        .path_segments()
        .map(|segments| segments.map(str::to_string).collect())
        .unwrap_or_default();
    if segments.last().map(|segment| segment == "relay").unwrap_or(false) {
        segments.pop();
    }
    segments.extend(["v1".to_string(), "trusted".to_string(), "session".to_string(), "resolve".to_string()]);
    url.set_path(&segments.join("/"));
    Ok(url)
}

fn current_timestamp_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}
