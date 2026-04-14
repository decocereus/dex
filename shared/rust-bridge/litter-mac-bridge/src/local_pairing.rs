use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::{Json, Router};
use local_ip_address::local_ip;
use mdns_sd::{ServiceDaemon, ServiceInfo};
use serde::{Deserialize, Serialize};
use tokio::net::TcpListener;
use tokio::sync::RwLock;
use url::Url;

use litter_mac_bridge_core::protocol::PairingPayload;

#[derive(Debug, Clone)]
pub struct LocalPairingConfig {
    pub bind_addr: SocketAddr,
    pub display_name: String,
    pub pairing_mode: PairingMode,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairingMode {
    AutoApprove,
    PairingCode,
}

impl PairingMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AutoApprove => "auto",
            Self::PairingCode => "code",
        }
    }
}

#[derive(Debug, Clone)]
pub struct PairingSession {
    pub payload: PairingPayload,
    pub pairing_code: String,
}

#[derive(Clone)]
struct LocalPairingState {
    session: Arc<RwLock<PairingSession>>,
    display_name: String,
    pairing_mode: PairingMode,
}

pub struct LocalPairingHandle {
    service_daemon: ServiceDaemon,
    service_fullname: String,
    shutdown_tx: tokio::sync::oneshot::Sender<()>,
    server_task: tokio::task::JoinHandle<()>,
}

impl LocalPairingHandle {
    pub async fn shutdown(self) {
        let _ = self.shutdown_tx.send(());
        let _ = self.server_task.await;
        let _ = self.service_daemon.unregister(&self.service_fullname);
        let _ = self.service_daemon.shutdown();
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocalPairingStatusResponse {
    ok: bool,
    display_name: String,
    pairing_mode: String,
    expires_at: i64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocalPairingPayloadResponse {
    ok: bool,
    payload: PairingPayload,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocalPairingErrorResponse {
    ok: bool,
    error: &'static str,
    code: &'static str,
}

#[derive(Debug, Deserialize)]
struct PairingRequestQuery {
    code: Option<String>,
}

pub async fn start_local_pairing_service(
    config: LocalPairingConfig,
    session: Arc<RwLock<PairingSession>>,
) -> Result<(LocalPairingHandle, SocketAddr), Box<dyn std::error::Error + Send + Sync>> {
    let listener = TcpListener::bind(config.bind_addr).await?;
    let local_addr = listener.local_addr()?;

    let state = LocalPairingState {
        session,
        display_name: config.display_name.clone(),
        pairing_mode: config.pairing_mode,
    };

    let router = Router::new()
        .route("/health", get(health))
        .route("/v1/local/pairing/status", get(pairing_status))
        .route("/v1/local/pairing/request", get(pairing_request))
        .with_state(state.clone());

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let server_task = tokio::spawn(async move {
        let server = axum::serve(listener, router).with_graceful_shutdown(async move {
            let _ = shutdown_rx.await;
        });
        let _ = server.await;
    });

    let service_daemon = ServiceDaemon::new()?;
    let service_fullname = register_bonjour_service(&service_daemon, &state, local_addr)?;
    eprintln!(
        "[litter-bridge][pairing] local pairing service started bind_addr={} service={} mode={}",
        local_addr,
        service_fullname,
        config.pairing_mode.as_str()
    );

    Ok((
        LocalPairingHandle {
            service_daemon,
            service_fullname,
            shutdown_tx,
            server_task,
        },
        local_addr,
    ))
}

async fn health() -> impl IntoResponse {
    Json(serde_json::json!({ "ok": true }))
}

async fn pairing_status(State(state): State<LocalPairingState>) -> impl IntoResponse {
    let session = state.session.read().await;
    eprintln!(
        "[litter-bridge][pairing] status requested display_name={} mode={} expires_at={}",
        state.display_name,
        state.pairing_mode.as_str(),
        session.payload.expires_at
    );
    Json(LocalPairingStatusResponse {
        ok: true,
        display_name: state.display_name,
        pairing_mode: state.pairing_mode.as_str().to_string(),
        expires_at: session.payload.expires_at,
    })
}

async fn pairing_request(
    State(state): State<LocalPairingState>,
    Query(query): Query<PairingRequestQuery>,
) -> impl IntoResponse {
    let session = state.session.read().await;
    eprintln!(
        "[litter-bridge][pairing] pairing request display_name={} mode={} has_code={}",
        state.display_name,
        state.pairing_mode.as_str(),
        query.code.as_deref().map(|value| !value.is_empty()).unwrap_or(false)
    );

    if state.pairing_mode == PairingMode::PairingCode {
        let provided = normalize_code(query.code.as_deref().unwrap_or_default());
        let expected = normalize_code(&session.pairing_code);
        if provided.is_empty() || provided != expected {
            eprintln!(
                "[litter-bridge][pairing] pairing request rejected code mismatch display_name={}",
                state.display_name
            );
            return (
                StatusCode::UNAUTHORIZED,
                Json(LocalPairingErrorResponse {
                    ok: false,
                    error: "Pairing code required",
                    code: "pairing_code_required",
                }),
            )
                .into_response();
        }
    }

    if current_timestamp_ms() > session.payload.expires_at {
        eprintln!(
            "[litter-bridge][pairing] pairing request rejected expired display_name={}",
            state.display_name
        );
        return (
            StatusCode::GONE,
            Json(LocalPairingErrorResponse {
                ok: false,
                error: "Pairing session expired",
                code: "pairing_session_expired",
            }),
        )
            .into_response();
    }

    let reachable_payload = PairingPayload {
        relay: rewrite_loopback_relay_url(&session.payload.relay),
        ..session.payload.clone()
    };

    (
        StatusCode::OK,
        Json(LocalPairingPayloadResponse {
            ok: true,
            payload: reachable_payload,
        }),
    )
        .into_response()
}

fn register_bonjour_service(
    daemon: &ServiceDaemon,
    state: &LocalPairingState,
    local_addr: SocketAddr,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let service_type = "_litter-bridge._tcp.local.";
    let instance_name = state.display_name.clone();
    let host_name = sanitize_hostname(&state.display_name);
    let ip = local_ip().unwrap_or(IpAddr::from([127, 0, 0, 1]));

    let properties = HashMap::from([
        ("bridge_transport".to_string(), "local_pairing".to_string()),
        ("service_type".to_string(), "_litter-bridge._tcp.".to_string()),
        ("pairing_mode".to_string(), state.pairing_mode.as_str().to_string()),
        ("pairing_path".to_string(), "/v1/local/pairing/request".to_string()),
        ("status_path".to_string(), "/v1/local/pairing/status".to_string()),
    ]);

    let service_info = ServiceInfo::new(
        service_type,
        &instance_name,
        &host_name,
        ip.to_string(),
        local_addr.port(),
        Some(properties),
    )?;
    let fullname = service_info.get_fullname().to_string();
    daemon.register(service_info)?;
    eprintln!(
        "[litter-bridge][bonjour] registered service fullname={} host={} ip={} port={} mode={}",
        fullname,
        host_name,
        ip,
        local_addr.port(),
        state.pairing_mode.as_str()
    );
    Ok(fullname)
}

fn sanitize_hostname(display_name: &str) -> String {
    let trimmed = display_name.trim();
    let normalized = if trimmed.is_empty() { "litter-mac-bridge" } else { trimmed };
    let replaced = normalized
        .chars()
        .map(|character| if character.is_ascii_alphanumeric() { character } else { '-' })
        .collect::<String>();
    format!("{}.local.", replaced.trim_matches('-'))
}

fn normalize_code(value: &str) -> String {
    value
        .trim()
        .to_uppercase()
        .replace([' ', '-'], "")
}

fn current_timestamp_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

pub(crate) fn rewrite_loopback_relay_url(raw: &str) -> String {
    let Ok(mut url) = Url::parse(raw) else {
        return raw.to_string();
    };
    let Some(host) = url.host_str() else {
        return raw.to_string();
    };
    let is_loopback = matches!(host, "127.0.0.1" | "localhost" | "::1");
    if !is_loopback {
        return raw.to_string();
    }

    let Ok(ip) = local_ip() else {
        return raw.to_string();
    };

    if url.set_host(Some(&ip.to_string())).is_err() {
        return raw.to_string();
    }
    url.to_string()
}
