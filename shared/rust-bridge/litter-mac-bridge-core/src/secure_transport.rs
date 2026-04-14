use std::collections::VecDeque;
use std::time::{SystemTime, UNIX_EPOCH};

use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce, Tag};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use serde::Serialize;
use serde_json::Value as JsonValue;
use sha2::{Digest, Sha256};
use thiserror::Error;
use tracing::debug;
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

use crate::device_state::BridgeDeviceState;
use crate::protocol::{
    LITTER_PAIRING_QR_VERSION, LITTER_SECURE_CLIENT_AUTH_LABEL, LITTER_SECURE_HANDSHAKE_TAG,
    LITTER_SECURE_PROTOCOL_VERSION, PairingPayload, SecureApplicationPayload, SecureClientAuth,
    SecureClientHello, SecureEnvelope, SecureErrorMessage, SecureHandshakeMode, SecureReady,
    SecureResumeState, SecureSender, SecureServerHello,
};

const MAX_PAIRING_AGE_MS: i64 = 5 * 60 * 1000;
const MAX_BRIDGE_OUTBOUND_MESSAGES: usize = 500;
const MAX_BRIDGE_OUTBOUND_BYTES: usize = 10 * 1024 * 1024;

#[derive(Debug, Error)]
pub enum BridgeSecureTransportError {
    #[error("invalid wire message: {0}")]
    InvalidWireMessage(String),
    #[error("crypto error: {0}")]
    Crypto(String),
    #[error("serialization error: {0}")]
    Serialization(String),
}

#[derive(Debug, Default)]
pub struct HandleWireMessageResult {
    pub outbound_wire_texts: Vec<String>,
    pub application_messages: Vec<String>,
    pub device_state_changed: bool,
}

#[derive(Debug, Default)]
pub struct QueueApplicationResult {
    pub outbound_wire_texts: Vec<String>,
    pub device_state_changed: bool,
}

#[derive(Debug, Clone)]
struct BufferedOutboundEntry {
    bridge_outbound_seq: u64,
    payload_text: String,
    size_bytes: usize,
}

#[derive(Debug, Clone)]
struct PendingHandshake {
    session_id: String,
    handshake_mode: SecureHandshakeMode,
    key_epoch: u32,
    phone_device_id: String,
    phone_identity_public_key: String,
    phone_ephemeral_public_key: [u8; 32],
    mac_ephemeral_private_key: [u8; 32],
    transcript_bytes: Vec<u8>,
}

#[derive(Debug, Clone)]
struct ActiveSession {
    session_id: String,
    key_epoch: u32,
    phone_to_mac_key: [u8; 32],
    mac_to_phone_key: [u8; 32],
    last_inbound_counter: Option<u64>,
    next_outbound_counter: u64,
    is_resumed: bool,
}

pub struct BridgeSecureTransport {
    device_state: BridgeDeviceState,
    current_pairing_expires_at_ms: i64,
    pending_handshake: Option<PendingHandshake>,
    active_session: Option<ActiveSession>,
    next_key_epoch: u32,
    next_bridge_outbound_seq: u64,
    last_relayed_bridge_outbound_seq: u64,
    outbound_buffer_bytes: usize,
    outbound_buffer: VecDeque<BufferedOutboundEntry>,
}

impl BridgeSecureTransport {
    pub fn new(device_state: BridgeDeviceState) -> Self {
        Self {
            device_state,
            current_pairing_expires_at_ms: now_ms() + MAX_PAIRING_AGE_MS,
            pending_handshake: None,
            active_session: None,
            next_key_epoch: 1,
            next_bridge_outbound_seq: 1,
            last_relayed_bridge_outbound_seq: 0,
            outbound_buffer_bytes: 0,
            outbound_buffer: VecDeque::new(),
        }
    }

    pub fn device_state(&self) -> &BridgeDeviceState {
        &self.device_state
    }

    pub fn create_pairing_payload(&mut self, relay: &str, session_id: &str) -> PairingPayload {
        self.current_pairing_expires_at_ms = now_ms() + MAX_PAIRING_AGE_MS;
        PairingPayload {
            v: LITTER_PAIRING_QR_VERSION,
            relay: relay.to_string(),
            session_id: session_id.to_string(),
            mac_device_id: self.device_state.mac_device_id.clone(),
            mac_identity_public_key: self.device_state.mac_identity_public_key.clone(),
            expires_at: self.current_pairing_expires_at_ms,
        }
    }

    pub fn is_secure_channel_ready(&self) -> bool {
        self.active_session
            .as_ref()
            .map(|session| session.is_resumed)
            .unwrap_or(false)
    }

    pub fn handle_incoming_wire_message(
        &mut self,
        raw_message: &str,
        session_id: &str,
    ) -> Result<HandleWireMessageResult, BridgeSecureTransportError> {
        let parsed: JsonValue = serde_json::from_str(raw_message)
            .map_err(|error| BridgeSecureTransportError::InvalidWireMessage(error.to_string()))?;
        let kind = parsed
            .get("kind")
            .and_then(JsonValue::as_str)
            .map(str::trim)
            .unwrap_or_default();

        let mut result = HandleWireMessageResult::default();

        match kind {
            "clientHello" => {
                let message: SecureClientHello = serde_json::from_value(parsed)
                    .map_err(|error| BridgeSecureTransportError::Serialization(error.to_string()))?;
                result
                    .outbound_wire_texts
                    .extend(self.handle_client_hello(message, session_id)?);
            }
            "clientAuth" => {
                let message: SecureClientAuth = serde_json::from_value(parsed)
                    .map_err(|error| BridgeSecureTransportError::Serialization(error.to_string()))?;
                let (messages, device_state_changed) = self.handle_client_auth(message, session_id)?;
                result.outbound_wire_texts.extend(messages);
                result.device_state_changed = device_state_changed;
            }
            "resumeState" => {
                let message: SecureResumeState = serde_json::from_value(parsed)
                    .map_err(|error| BridgeSecureTransportError::Serialization(error.to_string()))?;
                result
                    .outbound_wire_texts
                    .extend(self.handle_resume_state(message, session_id)?);
            }
            "encryptedEnvelope" => {
                let message: SecureEnvelope = serde_json::from_value(parsed)
                    .map_err(|error| BridgeSecureTransportError::Serialization(error.to_string()))?;
                let application_message = self.handle_encrypted_envelope(message, session_id)?;
                if let Some(application_message) = application_message {
                    result.application_messages.push(application_message);
                }
            }
            _ => {
                if parsed.get("method").is_some() || parsed.get("id").is_some() {
                    result
                        .outbound_wire_texts
                        .push(serialize_wire_message(&SecureErrorMessage::new(
                            "update_required",
                            "This bridge requires encrypted relay traffic before JSON-RPC can flow.",
                        ))?);
                }
            }
        }

        Ok(result)
    }

    pub fn queue_outbound_application_message(
        &mut self,
        payload_text: impl Into<String>,
        session_id: &str,
    ) -> Result<QueueApplicationResult, BridgeSecureTransportError> {
        let payload_text = payload_text.into();
        if payload_text.trim().is_empty() {
            return Ok(QueueApplicationResult::default());
        }

        let entry = BufferedOutboundEntry {
            bridge_outbound_seq: self.next_bridge_outbound_seq,
            size_bytes: payload_text.len(),
            payload_text,
        };
        self.next_bridge_outbound_seq += 1;
        self.outbound_buffer_bytes += entry.size_bytes;
        self.outbound_buffer.push_back(entry.clone());
        self.trim_outbound_buffer();

        let mut result = QueueApplicationResult::default();
        if self
            .active_session
            .as_ref()
            .map(|session| session.is_resumed && session.session_id == session_id)
            .unwrap_or(false)
        {
            result
                .outbound_wire_texts
                .push(self.encrypt_buffered_entry(entry, session_id)?);
        }

        Ok(result)
    }

    fn handle_client_hello(
        &mut self,
        message: SecureClientHello,
        session_id: &str,
    ) -> Result<Vec<String>, BridgeSecureTransportError> {
        if message.protocol_version != LITTER_SECURE_PROTOCOL_VERSION {
            return Ok(vec![serialize_wire_message(&SecureErrorMessage::new(
                "update_required",
                "The iPhone and Mac bridge are using different secure transport versions.",
            ))?]);
        }

        if message.session_id != session_id {
            return Ok(vec![serialize_wire_message(&SecureErrorMessage::new(
                "invalid_session",
                "The handshake session does not match the active bridge session.",
            ))?]);
        }

        if message.phone_device_id.trim().is_empty()
            || message.phone_identity_public_key.trim().is_empty()
            || message.phone_ephemeral_public_key.trim().is_empty()
            || message.client_nonce.trim().is_empty()
        {
            return Ok(vec![serialize_wire_message(&SecureErrorMessage::new(
                "invalid_client_hello",
                "The secure client hello is missing required fields.",
            ))?]);
        }

        if matches!(message.handshake_mode, SecureHandshakeMode::QrBootstrap)
            && now_ms() > self.current_pairing_expires_at_ms
        {
            return Ok(vec![serialize_wire_message(&SecureErrorMessage::new(
                "pairing_expired",
                "The pairing QR code has expired. Generate a fresh pairing payload on the Mac.",
            ))?]);
        }

        if matches!(message.handshake_mode, SecureHandshakeMode::TrustedReconnect) {
            match self
                .device_state
                .trusted_phone_public_key(&message.phone_device_id)
            {
                None => {
                    return Ok(vec![serialize_wire_message(&SecureErrorMessage::new(
                        "phone_not_trusted",
                        "This iPhone is not trusted by the current bridge state.",
                    ))?]);
                }
                Some(existing) if existing != message.phone_identity_public_key => {
                    return Ok(vec![serialize_wire_message(&SecureErrorMessage::new(
                        "phone_identity_changed",
                        "The trusted iPhone identity does not match this reconnect attempt.",
                    ))?]);
                }
                Some(_) => {}
            }
        }

        let client_nonce = BASE64
            .decode(message.client_nonce.as_bytes())
            .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
        let phone_ephemeral_public_key = decode_32_bytes(&message.phone_ephemeral_public_key)?;

        let mut server_nonce = [0u8; 32];
        OsRng.fill_bytes(&mut server_nonce);
        let mac_ephemeral_private_key = StaticSecret::random_from_rng(OsRng);
        let mac_ephemeral_public_key = X25519PublicKey::from(&mac_ephemeral_private_key);
        let key_epoch = self.next_key_epoch;
        let expires_at_for_transcript = if matches!(message.handshake_mode, SecureHandshakeMode::QrBootstrap) {
            self.current_pairing_expires_at_ms
        } else {
            0
        };

        let transcript_bytes = build_transcript_bytes(
            session_id,
            LITTER_SECURE_PROTOCOL_VERSION,
            message.handshake_mode,
            key_epoch,
            &self.device_state.mac_device_id,
            &message.phone_device_id,
            &self.device_state.mac_identity_public_key,
            &message.phone_identity_public_key,
            mac_ephemeral_public_key.as_bytes(),
            &phone_ephemeral_public_key,
            &client_nonce,
            &server_nonce,
            expires_at_for_transcript,
        )?;

        let signing_key = decode_signing_key(&self.device_state.mac_identity_private_key)?;
        let signature = signing_key.sign(&transcript_bytes);
        let server_hello = SecureServerHello {
            kind: "serverHello".to_string(),
            protocol_version: LITTER_SECURE_PROTOCOL_VERSION,
            session_id: session_id.to_string(),
            handshake_mode: message.handshake_mode,
            mac_device_id: self.device_state.mac_device_id.clone(),
            mac_identity_public_key: self.device_state.mac_identity_public_key.clone(),
            mac_ephemeral_public_key: BASE64.encode(mac_ephemeral_public_key.as_bytes()),
            server_nonce: BASE64.encode(server_nonce),
            key_epoch,
            expires_at_for_transcript,
            mac_signature: BASE64.encode(signature.to_bytes()),
            client_nonce: message.client_nonce.clone(),
        };

        debug!(
            "litter-bridge secure hello mode={:?} session={} key_epoch={}",
            message.handshake_mode, session_id, key_epoch
        );

        self.pending_handshake = Some(PendingHandshake {
            session_id: session_id.to_string(),
            handshake_mode: message.handshake_mode,
            key_epoch,
            phone_device_id: message.phone_device_id,
            phone_identity_public_key: message.phone_identity_public_key,
            phone_ephemeral_public_key,
            mac_ephemeral_private_key: mac_ephemeral_private_key.to_bytes(),
            transcript_bytes,
        });
        self.active_session = None;

        Ok(vec![serialize_wire_message(&server_hello)?])
    }

    fn handle_client_auth(
        &mut self,
        message: SecureClientAuth,
        session_id: &str,
    ) -> Result<(Vec<String>, bool), BridgeSecureTransportError> {
        let Some(pending) = self.pending_handshake.clone() else {
            return Ok((
                vec![serialize_wire_message(&SecureErrorMessage::new(
                    "unexpected_client_auth",
                    "There is no pending secure handshake to finalize.",
                ))?],
                false,
            ));
        };

        if message.session_id != pending.session_id
            || message.phone_device_id != pending.phone_device_id
            || message.key_epoch != pending.key_epoch
        {
            self.pending_handshake = None;
            return Ok((
                vec![serialize_wire_message(&SecureErrorMessage::new(
                    "invalid_client_auth",
                    "The secure client authentication payload was invalid.",
                ))?],
                false,
            ));
        }

        let transcript = client_auth_transcript(&pending.transcript_bytes);
        let phone_key = decode_verifying_key(&pending.phone_identity_public_key)?;
        let phone_signature_bytes = BASE64
            .decode(message.phone_signature.as_bytes())
            .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
        let phone_signature = Signature::from_slice(&phone_signature_bytes)
            .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
        if phone_key.verify(&transcript, &phone_signature).is_err() {
            self.pending_handshake = None;
            return Ok((
                vec![serialize_wire_message(&SecureErrorMessage::new(
                    "invalid_phone_signature",
                    "The iPhone secure signature could not be verified.",
                ))?],
                false,
            ));
        }

        let mac_secret = StaticSecret::from(pending.mac_ephemeral_private_key);
        let phone_public = X25519PublicKey::from(pending.phone_ephemeral_public_key);
        let shared_secret = mac_secret.diffie_hellman(&phone_public);
        let salt = Sha256::digest(&pending.transcript_bytes);
        let info_prefix = format!(
            "{}|{}|{}|{}|{}",
            LITTER_SECURE_HANDSHAKE_TAG,
            pending.session_id,
            self.device_state.mac_device_id,
            pending.phone_device_id,
            pending.key_epoch
        );

        let phone_to_mac_key = derive_aes_key(
            shared_secret.as_bytes(),
            &salt,
            format!("{info_prefix}|phoneToMac").as_bytes(),
        )?;
        let mac_to_phone_key = derive_aes_key(
            shared_secret.as_bytes(),
            &salt,
            format!("{info_prefix}|macToPhone").as_bytes(),
        )?;

        self.active_session = Some(ActiveSession {
            session_id: pending.session_id.clone(),
            key_epoch: pending.key_epoch,
            phone_to_mac_key,
            mac_to_phone_key,
            last_inbound_counter: None,
            next_outbound_counter: 0,
            is_resumed: false,
        });
        self.next_key_epoch = pending.key_epoch + 1;

        let mut device_state_changed = false;
        if matches!(pending.handshake_mode, SecureHandshakeMode::QrBootstrap)
            || self
                .device_state
                .trusted_phone_public_key(&pending.phone_device_id)
                .is_some()
        {
            device_state_changed = self.device_state.remember_trusted_phone(
                &pending.phone_device_id,
                &pending.phone_identity_public_key,
            );
        }
        if matches!(pending.handshake_mode, SecureHandshakeMode::QrBootstrap) {
            self.reset_outbound_replay_state();
        }

        self.pending_handshake = None;
        let ready = SecureReady::new(
            session_id.to_string(),
            pending.key_epoch,
            self.device_state.mac_device_id.clone(),
        );
        Ok((vec![serialize_wire_message(&ready)?], device_state_changed))
    }

    fn handle_resume_state(
        &mut self,
        message: SecureResumeState,
        session_id: &str,
    ) -> Result<Vec<String>, BridgeSecureTransportError> {
        let Some(active_session) = self.active_session.as_mut() else {
            return Ok(vec![]);
        };

        if message.session_id != session_id || message.key_epoch != active_session.key_epoch {
            return Ok(vec![]);
        }

        self.last_relayed_bridge_outbound_seq = message.last_applied_bridge_outbound_seq;
        active_session.is_resumed = true;

        let replay_entries: Vec<_> = self
            .outbound_buffer
            .iter()
            .filter(|entry| entry.bridge_outbound_seq > self.last_relayed_bridge_outbound_seq)
            .cloned()
            .collect();

        let mut messages = Vec::with_capacity(replay_entries.len());
        for entry in replay_entries {
            messages.push(self.encrypt_buffered_entry(entry, session_id)?);
        }
        Ok(messages)
    }

    fn handle_encrypted_envelope(
        &mut self,
        message: SecureEnvelope,
        session_id: &str,
    ) -> Result<Option<String>, BridgeSecureTransportError> {
        let Some(active_session) = self.active_session.as_mut() else {
            return Ok(None);
        };

        if message.session_id != session_id
            || message.key_epoch != active_session.key_epoch
            || !matches!(message.sender, SecureSender::Iphone)
        {
            return Ok(None);
        }

        if active_session
            .last_inbound_counter
            .map(|last| message.counter <= last)
            .unwrap_or(false)
        {
            return Ok(None);
        }

        let plaintext = decrypt_envelope_payload(
            &message,
            &active_session.phone_to_mac_key,
            SecureSender::Iphone,
            message.counter,
        )?;
        active_session.last_inbound_counter = Some(message.counter);

        let payload: SecureApplicationPayload = serde_json::from_slice(&plaintext)
            .map_err(|error| BridgeSecureTransportError::Serialization(error.to_string()))?;
        if payload.payload_text.trim().is_empty() {
            return Ok(None);
        }

        Ok(Some(payload.payload_text))
    }

    fn encrypt_buffered_entry(
        &mut self,
        entry: BufferedOutboundEntry,
        session_id: &str,
    ) -> Result<String, BridgeSecureTransportError> {
        let Some(active_session) = self.active_session.as_mut() else {
            return Err(BridgeSecureTransportError::InvalidWireMessage(
                "secure session is not active".to_string(),
            ));
        };

        let payload = SecureApplicationPayload {
            bridge_outbound_seq: Some(entry.bridge_outbound_seq),
            payload_text: entry.payload_text,
        };
        let envelope = encrypt_envelope_payload(
            &payload,
            &active_session.mac_to_phone_key,
            SecureSender::Mac,
            active_session.next_outbound_counter,
            session_id,
            active_session.key_epoch,
        )?;
        active_session.next_outbound_counter += 1;
        serialize_wire_message(&envelope)
    }

    fn trim_outbound_buffer(&mut self) {
        while self.outbound_buffer.len() > MAX_BRIDGE_OUTBOUND_MESSAGES
            || self.outbound_buffer_bytes > MAX_BRIDGE_OUTBOUND_BYTES
        {
            if let Some(removed) = self.outbound_buffer.pop_front() {
                self.outbound_buffer_bytes = self
                    .outbound_buffer_bytes
                    .saturating_sub(removed.size_bytes);
            } else {
                break;
            }
        }
    }

    fn reset_outbound_replay_state(&mut self) {
        self.outbound_buffer.clear();
        self.outbound_buffer_bytes = 0;
        self.last_relayed_bridge_outbound_seq = 0;
        self.next_bridge_outbound_seq = 1;
    }
}

fn encrypt_envelope_payload<T: Serialize>(
    payload: &T,
    key: &[u8; 32],
    sender: SecureSender,
    counter: u64,
    session_id: &str,
    key_epoch: u32,
) -> Result<SecureEnvelope, BridgeSecureTransportError> {
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
    let nonce_bytes = nonce_for_direction(sender, counter);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let mut plaintext = serde_json::to_vec(payload)
        .map_err(|error| BridgeSecureTransportError::Serialization(error.to_string()))?;
    let tag = cipher
        .encrypt_in_place_detached(nonce, b"", &mut plaintext)
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;

    Ok(SecureEnvelope {
        kind: "encryptedEnvelope".to_string(),
        v: LITTER_SECURE_PROTOCOL_VERSION,
        session_id: session_id.to_string(),
        key_epoch,
        sender,
        counter,
        ciphertext: BASE64.encode(plaintext),
        tag: BASE64.encode(tag),
    })
}

fn decrypt_envelope_payload(
    envelope: &SecureEnvelope,
    key: &[u8; 32],
    sender: SecureSender,
    counter: u64,
) -> Result<Vec<u8>, BridgeSecureTransportError> {
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
    let nonce_bytes = nonce_for_direction(sender, counter);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let mut ciphertext = BASE64
        .decode(envelope.ciphertext.as_bytes())
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
    let tag_bytes = BASE64
        .decode(envelope.tag.as_bytes())
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
    let tag = Tag::from_slice(&tag_bytes);
    cipher
        .decrypt_in_place_detached(nonce, b"", &mut ciphertext, tag)
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
    Ok(ciphertext)
}

fn derive_aes_key(
    shared_secret: &[u8],
    salt: &[u8],
    info: &[u8],
) -> Result<[u8; 32], BridgeSecureTransportError> {
    let hkdf = Hkdf::<Sha256>::new(Some(salt), shared_secret);
    let mut output = [0u8; 32];
    hkdf.expand(info, &mut output)
        .map_err(|_| BridgeSecureTransportError::Crypto("hkdf expansion failed".to_string()))?;
    Ok(output)
}

fn build_transcript_bytes(
    session_id: &str,
    protocol_version: u32,
    handshake_mode: SecureHandshakeMode,
    key_epoch: u32,
    mac_device_id: &str,
    phone_device_id: &str,
    mac_identity_public_key: &str,
    phone_identity_public_key: &str,
    mac_ephemeral_public_key: &[u8; 32],
    phone_ephemeral_public_key: &[u8; 32],
    client_nonce: &[u8],
    server_nonce: &[u8],
    expires_at_for_transcript: i64,
) -> Result<Vec<u8>, BridgeSecureTransportError> {
    let mut out = Vec::new();
    append_length_prefixed_utf8(&mut out, LITTER_SECURE_HANDSHAKE_TAG);
    append_length_prefixed_utf8(&mut out, session_id);
    append_length_prefixed_utf8(&mut out, protocol_version.to_string());
    append_length_prefixed_utf8(
        &mut out,
        match handshake_mode {
            SecureHandshakeMode::QrBootstrap => "qr_bootstrap",
            SecureHandshakeMode::TrustedReconnect => "trusted_reconnect",
        },
    );
    append_length_prefixed_utf8(&mut out, key_epoch.to_string());
    append_length_prefixed_utf8(&mut out, mac_device_id);
    append_length_prefixed_utf8(&mut out, phone_device_id);
    append_length_prefixed_bytes(&mut out, &BASE64.decode(mac_identity_public_key.as_bytes()).map_err(|error| {
        BridgeSecureTransportError::Crypto(error.to_string())
    })?);
    append_length_prefixed_bytes(&mut out, &BASE64.decode(phone_identity_public_key.as_bytes()).map_err(|error| {
        BridgeSecureTransportError::Crypto(error.to_string())
    })?);
    append_length_prefixed_bytes(&mut out, mac_ephemeral_public_key);
    append_length_prefixed_bytes(&mut out, phone_ephemeral_public_key);
    append_length_prefixed_bytes(&mut out, client_nonce);
    append_length_prefixed_bytes(&mut out, server_nonce);
    append_length_prefixed_utf8(&mut out, expires_at_for_transcript.to_string());
    Ok(out)
}

fn client_auth_transcript(transcript_bytes: &[u8]) -> Vec<u8> {
    let mut out = transcript_bytes.to_vec();
    append_length_prefixed_utf8(&mut out, LITTER_SECURE_CLIENT_AUTH_LABEL);
    out
}

fn append_length_prefixed_utf8(out: &mut Vec<u8>, value: impl AsRef<str>) {
    append_length_prefixed_bytes(out, value.as_ref().as_bytes());
}

fn append_length_prefixed_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    out.extend_from_slice(bytes);
}

fn nonce_for_direction(sender: SecureSender, counter: u64) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[0] = match sender {
        SecureSender::Mac => 1,
        SecureSender::Iphone => 2,
    };
    let counter_bytes = counter.to_be_bytes();
    nonce[4..12].copy_from_slice(&counter_bytes);
    nonce
}

fn decode_32_bytes(encoded: &str) -> Result<[u8; 32], BridgeSecureTransportError> {
    let bytes = BASE64
        .decode(encoded.as_bytes())
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))?;
    bytes.try_into().map_err(|_| {
        BridgeSecureTransportError::Crypto("expected exactly 32 decoded bytes".to_string())
    })
}

fn decode_signing_key(encoded: &str) -> Result<SigningKey, BridgeSecureTransportError> {
    let bytes = decode_32_bytes(encoded)?;
    Ok(SigningKey::from_bytes(&bytes))
}

fn decode_verifying_key(encoded: &str) -> Result<VerifyingKey, BridgeSecureTransportError> {
    let bytes = decode_32_bytes(encoded)?;
    VerifyingKey::from_bytes(&bytes)
        .map_err(|error| BridgeSecureTransportError::Crypto(error.to_string()))
}

fn serialize_wire_message<T: Serialize>(message: &T) -> Result<String, BridgeSecureTransportError> {
    serde_json::to_string(message)
        .map_err(|error| BridgeSecureTransportError::Serialization(error.to_string()))
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_state::BridgeDeviceState;
    use crate::protocol::{SecureClientAuth, SecureClientHello, SecureResumeState};
    use ed25519_dalek::SigningKey;

    #[test]
    fn handshake_encrypts_and_decrypts_application_payloads() {
        let mut transport = BridgeSecureTransport::new(BridgeDeviceState::create_new());
        let session_id = "session-1";
        let relay = "ws://relay.example.test/relay";
        let pairing = transport.create_pairing_payload(relay, session_id);

        let phone_signing_key = SigningKey::generate(&mut OsRng);
        let phone_identity_public_key = BASE64.encode(phone_signing_key.verifying_key().to_bytes());
        let phone_identity_private_key = BASE64.encode(phone_signing_key.to_bytes());
        let phone_key_agreement_secret = StaticSecret::random_from_rng(OsRng);
        let phone_key_agreement_public = X25519PublicKey::from(&phone_key_agreement_secret);
        let client_nonce = vec![7u8; 32];

        let client_hello = SecureClientHello::new(
            LITTER_SECURE_PROTOCOL_VERSION,
            session_id.to_string(),
            SecureHandshakeMode::QrBootstrap,
            "phone-1".to_string(),
            phone_identity_public_key.clone(),
            BASE64.encode(phone_key_agreement_public.as_bytes()),
            BASE64.encode(&client_nonce),
        );
        let hello_result = transport
            .handle_incoming_wire_message(
                &serde_json::to_string(&client_hello).expect("serialize hello"),
                session_id,
            )
            .expect("hello result");
        assert_eq!(hello_result.outbound_wire_texts.len(), 1);
        let server_hello: SecureServerHello =
            serde_json::from_str(&hello_result.outbound_wire_texts[0]).expect("server hello");

        let transcript = build_transcript_bytes(
            session_id,
            LITTER_SECURE_PROTOCOL_VERSION,
            SecureHandshakeMode::QrBootstrap,
            server_hello.key_epoch,
            &pairing.mac_device_id,
            "phone-1",
            &pairing.mac_identity_public_key,
            &phone_identity_public_key,
            &decode_32_bytes(&server_hello.mac_ephemeral_public_key).expect("mac eph"),
            phone_key_agreement_public.as_bytes(),
            &client_nonce,
            &BASE64.decode(server_hello.server_nonce.as_bytes()).expect("server nonce"),
            pairing.expires_at,
        )
        .expect("transcript");
        let client_auth_signature = phone_signing_key.sign(&client_auth_transcript(&transcript));
        let client_auth = SecureClientAuth::new(
            session_id.to_string(),
            "phone-1".to_string(),
            server_hello.key_epoch,
            BASE64.encode(client_auth_signature.to_bytes()),
        );
        let auth_result = transport
            .handle_incoming_wire_message(
                &serde_json::to_string(&client_auth).expect("serialize auth"),
                session_id,
            )
            .expect("auth result");
        assert_eq!(auth_result.outbound_wire_texts.len(), 1);
        assert!(auth_result.device_state_changed);

        let mac_ephemeral_public =
            X25519PublicKey::from(decode_32_bytes(&server_hello.mac_ephemeral_public_key).expect("mac eph bytes"));
        let shared_secret = phone_key_agreement_secret.diffie_hellman(&mac_ephemeral_public);
        let salt = Sha256::digest(&transcript);
        let info_prefix = format!(
            "{}|{}|{}|{}|{}",
            LITTER_SECURE_HANDSHAKE_TAG,
            session_id,
            pairing.mac_device_id,
            "phone-1",
            server_hello.key_epoch
        );
        let phone_to_mac_key = derive_aes_key(
            shared_secret.as_bytes(),
            &salt,
            format!("{info_prefix}|phoneToMac").as_bytes(),
        )
        .expect("phone->mac");
        let mac_to_phone_key = derive_aes_key(
            shared_secret.as_bytes(),
            &salt,
            format!("{info_prefix}|macToPhone").as_bytes(),
        )
        .expect("mac->phone");

        let resume = SecureResumeState::new(session_id.to_string(), server_hello.key_epoch, 0);
        let _resume_result = transport
            .handle_incoming_wire_message(
                &serde_json::to_string(&resume).expect("serialize resume"),
                session_id,
            )
            .expect("resume");

        let outbound = transport
            .queue_outbound_application_message("hello from mac", session_id)
            .expect("queue outbound");
        assert_eq!(outbound.outbound_wire_texts.len(), 1);
        let outbound_envelope: SecureEnvelope =
            serde_json::from_str(&outbound.outbound_wire_texts[0]).expect("outbound envelope");
        let decrypted_outbound =
            decrypt_envelope_payload(&outbound_envelope, &mac_to_phone_key, SecureSender::Mac, 0)
                .expect("decrypt outbound");
        let outbound_payload: SecureApplicationPayload =
            serde_json::from_slice(&decrypted_outbound).expect("outbound payload");
        assert_eq!(outbound_payload.payload_text, "hello from mac");
        assert_eq!(outbound_payload.bridge_outbound_seq, Some(1));

        let inbound_envelope = encrypt_envelope_payload(
            &SecureApplicationPayload {
                bridge_outbound_seq: None,
                payload_text: "hello from phone".to_string(),
            },
            &phone_to_mac_key,
            SecureSender::Iphone,
            0,
            session_id,
            server_hello.key_epoch,
        )
        .expect("encrypt inbound");
        let inbound_result = transport
            .handle_incoming_wire_message(
                &serde_json::to_string(&inbound_envelope).expect("serialize inbound envelope"),
                session_id,
            )
            .expect("inbound result");
        assert_eq!(inbound_result.application_messages, vec!["hello from phone"]);
        assert!(transport.is_secure_channel_ready());

        let _ = phone_identity_private_key;
    }
}
