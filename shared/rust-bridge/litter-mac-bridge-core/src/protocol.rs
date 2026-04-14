use serde::{Deserialize, Serialize};

pub const LITTER_SECURE_PROTOCOL_VERSION: u32 = 1;
pub const LITTER_PAIRING_QR_VERSION: u32 = 1;
pub const LITTER_SECURE_HANDSHAKE_TAG: &str = "litter-bridge-e2ee-v1";
pub const LITTER_SECURE_CLIENT_AUTH_LABEL: &str = "client-auth";
pub const LITTER_TRUSTED_SESSION_RESOLVE_TAG: &str = "litter-trusted-session-resolve-v1";
pub const SECURE_SENDER_MAC: &str = "mac";
pub const SECURE_SENDER_IPHONE: &str = "iphone";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SecureHandshakeMode {
    QrBootstrap,
    TrustedReconnect,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingPayload {
    pub v: u32,
    pub relay: String,
    pub session_id: String,
    pub mac_device_id: String,
    pub mac_identity_public_key: String,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureClientHello {
    pub kind: String,
    pub protocol_version: u32,
    pub session_id: String,
    pub handshake_mode: SecureHandshakeMode,
    pub phone_device_id: String,
    pub phone_identity_public_key: String,
    pub phone_ephemeral_public_key: String,
    pub client_nonce: String,
}

impl SecureClientHello {
    pub fn new(
        protocol_version: u32,
        session_id: String,
        handshake_mode: SecureHandshakeMode,
        phone_device_id: String,
        phone_identity_public_key: String,
        phone_ephemeral_public_key: String,
        client_nonce: String,
    ) -> Self {
        Self {
            kind: "clientHello".to_string(),
            protocol_version,
            session_id,
            handshake_mode,
            phone_device_id,
            phone_identity_public_key,
            phone_ephemeral_public_key,
            client_nonce,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureServerHello {
    pub kind: String,
    pub protocol_version: u32,
    pub session_id: String,
    pub handshake_mode: SecureHandshakeMode,
    pub mac_device_id: String,
    pub mac_identity_public_key: String,
    pub mac_ephemeral_public_key: String,
    pub server_nonce: String,
    pub key_epoch: u32,
    pub expires_at_for_transcript: i64,
    pub mac_signature: String,
    pub client_nonce: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureClientAuth {
    pub kind: String,
    pub session_id: String,
    pub phone_device_id: String,
    pub key_epoch: u32,
    pub phone_signature: String,
}

impl SecureClientAuth {
    pub fn new(
        session_id: String,
        phone_device_id: String,
        key_epoch: u32,
        phone_signature: String,
    ) -> Self {
        Self {
            kind: "clientAuth".to_string(),
            session_id,
            phone_device_id,
            key_epoch,
            phone_signature,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureReady {
    pub kind: String,
    pub session_id: String,
    pub key_epoch: u32,
    pub mac_device_id: String,
}

impl SecureReady {
    pub fn new(session_id: String, key_epoch: u32, mac_device_id: String) -> Self {
        Self {
            kind: "secureReady".to_string(),
            session_id,
            key_epoch,
            mac_device_id,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureResumeState {
    pub kind: String,
    pub session_id: String,
    pub key_epoch: u32,
    pub last_applied_bridge_outbound_seq: u64,
}

impl SecureResumeState {
    pub fn new(session_id: String, key_epoch: u32, last_applied_bridge_outbound_seq: u64) -> Self {
        Self {
            kind: "resumeState".to_string(),
            session_id,
            key_epoch,
            last_applied_bridge_outbound_seq,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SecureErrorMessage {
    pub kind: String,
    pub code: String,
    pub message: String,
}

impl SecureErrorMessage {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            kind: "secureError".to_string(),
            code: code.into(),
            message: message.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SecureSender {
    Mac,
    Iphone,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureEnvelope {
    pub kind: String,
    pub v: u32,
    pub session_id: String,
    pub key_epoch: u32,
    pub sender: SecureSender,
    pub counter: u64,
    pub ciphertext: String,
    pub tag: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecureApplicationPayload {
    pub bridge_outbound_seq: Option<u64>,
    pub payload_text: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedSessionResolveRequest {
    pub mac_device_id: String,
    pub phone_device_id: String,
    pub phone_identity_public_key: String,
    pub nonce: String,
    pub timestamp: i64,
    pub signature: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedSessionResolveResponse {
    pub ok: bool,
    pub mac_device_id: String,
    pub mac_identity_public_key: String,
    pub display_name: Option<String>,
    pub session_id: String,
}
