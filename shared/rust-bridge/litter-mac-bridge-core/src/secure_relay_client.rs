use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce, Tag};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use ed25519_dalek::{Signature, Signer, Verifier, VerifyingKey};
use hkdf::Hkdf;
use serde::Serialize;
use sha2::{Digest, Sha256};
use thiserror::Error;
use x25519_dalek::{PublicKey as X25519PublicKey, StaticSecret};

use crate::phone_identity::PhoneIdentityState;
use crate::protocol::{
    LITTER_SECURE_CLIENT_AUTH_LABEL, LITTER_SECURE_HANDSHAKE_TAG, LITTER_SECURE_PROTOCOL_VERSION,
    LITTER_TRUSTED_SESSION_RESOLVE_TAG, PairingPayload, SecureApplicationPayload,
    SecureClientAuth, SecureClientHello, SecureEnvelope, SecureHandshakeMode, SecureReady,
    SecureResumeState, SecureSender, SecureServerHello, TrustedSessionResolveRequest,
    TrustedSessionResolveResponse,
};

#[derive(Debug, Error)]
pub enum SecureRelayClientError {
    #[error("invalid handshake: {0}")]
    InvalidHandshake(String),
    #[error("crypto error: {0}")]
    Crypto(String),
    #[error("serialization error: {0}")]
    Serialization(String),
}

#[derive(Debug, Clone)]
struct PendingClientHandshake {
    pairing_payload: PairingPayload,
    expected_mac_identity_public_key: String,
    phone_ephemeral_private_key: [u8; 32],
    phone_ephemeral_public_key: [u8; 32],
    client_nonce: Vec<u8>,
}

#[derive(Debug, Clone)]
struct ActiveSecureSession {
    session_id: String,
    key_epoch: u32,
    mac_device_id: String,
    phone_to_mac_key: [u8; 32],
    mac_to_phone_key: [u8; 32],
    last_inbound_bridge_outbound_seq: u64,
    last_inbound_counter: Option<u64>,
    next_outbound_counter: u64,
}

pub struct SecureRelayClient {
    phone_identity: PhoneIdentityState,
    pending_handshake: Option<PendingClientHandshake>,
    secure_session: Option<ActiveSecureSession>,
}

impl SecureRelayClient {
    pub fn new(phone_identity: PhoneIdentityState) -> Self {
        Self {
            phone_identity,
            pending_handshake: None,
            secure_session: None,
        }
    }

    pub fn phone_identity(&self) -> &PhoneIdentityState {
        &self.phone_identity
    }

    pub fn is_ready(&self) -> bool {
        self.secure_session.is_some()
    }

    pub fn begin_handshake(
        &mut self,
        pairing_payload: PairingPayload,
        trusted_reconnect: bool,
    ) -> Result<SecureClientHello, SecureRelayClientError> {
        let phone_secret = StaticSecret::random_from_rng(rand_core::OsRng);
        let phone_public = X25519PublicKey::from(&phone_secret);
        let client_nonce = random_nonce(32);
        let handshake_mode = if trusted_reconnect {
            SecureHandshakeMode::TrustedReconnect
        } else {
            SecureHandshakeMode::QrBootstrap
        };

        self.pending_handshake = Some(PendingClientHandshake {
            expected_mac_identity_public_key: pairing_payload.mac_identity_public_key.clone(),
            pairing_payload: pairing_payload.clone(),
            phone_ephemeral_private_key: phone_secret.to_bytes(),
            phone_ephemeral_public_key: *phone_public.as_bytes(),
            client_nonce: client_nonce.clone(),
        });

        Ok(SecureClientHello::new(
            LITTER_SECURE_PROTOCOL_VERSION,
            pairing_payload.session_id,
            handshake_mode,
            self.phone_identity.phone_device_id.clone(),
            self.phone_identity.phone_identity_public_key.clone(),
            BASE64.encode(phone_public.as_bytes()),
            BASE64.encode(client_nonce),
        ))
    }

    pub fn handle_server_hello(
        &mut self,
        server_hello: SecureServerHello,
    ) -> Result<SecureClientAuth, SecureRelayClientError> {
        let Some(pending) = self.pending_handshake.as_ref() else {
            return Err(SecureRelayClientError::InvalidHandshake(
                "no pending client handshake".to_string(),
            ));
        };

        if server_hello.protocol_version != LITTER_SECURE_PROTOCOL_VERSION {
            return Err(SecureRelayClientError::InvalidHandshake(
                "protocol version mismatch".to_string(),
            ));
        }
        if server_hello.session_id != pending.pairing_payload.session_id {
            return Err(SecureRelayClientError::InvalidHandshake(
                "session id mismatch".to_string(),
            ));
        }
        if server_hello.mac_device_id != pending.pairing_payload.mac_device_id {
            return Err(SecureRelayClientError::InvalidHandshake(
                "mac device id mismatch".to_string(),
            ));
        }
        if server_hello.mac_identity_public_key != pending.expected_mac_identity_public_key {
            return Err(SecureRelayClientError::InvalidHandshake(
                "mac identity key mismatch".to_string(),
            ));
        }
        if server_hello.client_nonce != BASE64.encode(&pending.client_nonce) {
            return Err(SecureRelayClientError::InvalidHandshake(
                "client nonce mismatch".to_string(),
            ));
        }

        let transcript = build_transcript_bytes(
            &pending.pairing_payload.session_id,
            LITTER_SECURE_PROTOCOL_VERSION,
            server_hello.handshake_mode,
            server_hello.key_epoch,
            &server_hello.mac_device_id,
            &self.phone_identity.phone_device_id,
            &server_hello.mac_identity_public_key,
            &self.phone_identity.phone_identity_public_key,
            &decode_32_bytes(&server_hello.mac_ephemeral_public_key)?,
            &pending.phone_ephemeral_public_key,
            &pending.client_nonce,
            &BASE64
                .decode(server_hello.server_nonce.as_bytes())
                .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?,
            server_hello.expires_at_for_transcript,
        )?;

        let mac_public_key = decode_verifying_key(&server_hello.mac_identity_public_key)?;
        let mac_signature_bytes = BASE64
            .decode(server_hello.mac_signature.as_bytes())
            .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
        let mac_signature = Signature::from_slice(&mac_signature_bytes)
            .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
        mac_public_key
            .verify(&transcript, &mac_signature)
            .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;

        let phone_signing_key = decode_signing_key(&self.phone_identity.phone_identity_private_key)?;
        let client_auth_signature = phone_signing_key.sign(&client_auth_transcript(&transcript));
        let phone_ephemeral_secret = StaticSecret::from(pending.phone_ephemeral_private_key);
        let mac_ephemeral_public = X25519PublicKey::from(decode_32_bytes(&server_hello.mac_ephemeral_public_key)?);
        let shared_secret = phone_ephemeral_secret.diffie_hellman(&mac_ephemeral_public);
        let salt = Sha256::digest(&transcript);
        let info_prefix = format!(
            "{}|{}|{}|{}|{}",
            LITTER_SECURE_HANDSHAKE_TAG,
            server_hello.session_id,
            server_hello.mac_device_id,
            self.phone_identity.phone_device_id,
            server_hello.key_epoch
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

        self.secure_session = Some(ActiveSecureSession {
            session_id: server_hello.session_id.clone(),
            key_epoch: server_hello.key_epoch,
            mac_device_id: server_hello.mac_device_id.clone(),
            phone_to_mac_key,
            mac_to_phone_key,
            last_inbound_bridge_outbound_seq: 0,
            last_inbound_counter: None,
            next_outbound_counter: 0,
        });

        Ok(SecureClientAuth::new(
            server_hello.session_id,
            self.phone_identity.phone_device_id.clone(),
            server_hello.key_epoch,
            BASE64.encode(client_auth_signature.to_bytes()),
        ))
    }

    pub fn finalize_handshake(
        &mut self,
        ready: SecureReady,
        last_applied_bridge_outbound_seq: u64,
    ) -> Result<SecureResumeState, SecureRelayClientError> {
        let Some(session) = self.secure_session.as_mut() else {
            return Err(SecureRelayClientError::InvalidHandshake(
                "secure session not initialized".to_string(),
            ));
        };
        if ready.session_id != session.session_id
            || ready.key_epoch != session.key_epoch
            || ready.mac_device_id != session.mac_device_id
        {
            return Err(SecureRelayClientError::InvalidHandshake(
                "secure ready did not match the negotiated session".to_string(),
            ));
        }

        session.last_inbound_bridge_outbound_seq = last_applied_bridge_outbound_seq;
        self.pending_handshake = None;

        Ok(SecureResumeState::new(
            session.session_id.clone(),
            session.key_epoch,
            last_applied_bridge_outbound_seq,
        ))
    }

    pub fn encrypt_application_message(
        &mut self,
        payload_text: String,
    ) -> Result<SecureEnvelope, SecureRelayClientError> {
        let Some(session) = self.secure_session.as_mut() else {
            return Err(SecureRelayClientError::InvalidHandshake(
                "secure session not ready".to_string(),
            ));
        };
        let envelope = encrypt_envelope_payload(
            &SecureApplicationPayload {
                bridge_outbound_seq: None,
                payload_text,
            },
            &session.phone_to_mac_key,
            SecureSender::Iphone,
            session.next_outbound_counter,
            &session.session_id,
            session.key_epoch,
        )?;
        session.next_outbound_counter += 1;
        Ok(envelope)
    }

    pub fn decrypt_application_message(
        &mut self,
        envelope: SecureEnvelope,
    ) -> Result<SecureApplicationPayload, SecureRelayClientError> {
        let Some(session) = self.secure_session.as_mut() else {
            return Err(SecureRelayClientError::InvalidHandshake(
                "secure session not ready".to_string(),
            ));
        };
        if envelope.session_id != session.session_id
            || envelope.key_epoch != session.key_epoch
            || !matches!(envelope.sender, SecureSender::Mac)
        {
            return Err(SecureRelayClientError::InvalidHandshake(
                "incoming envelope did not match the active session".to_string(),
            ));
        }
        if session
            .last_inbound_counter
            .map(|last| envelope.counter <= last)
            .unwrap_or(false)
        {
            return Err(SecureRelayClientError::InvalidHandshake(
                "replayed envelope".to_string(),
            ));
        }

        let plaintext = decrypt_envelope_payload(
            &envelope,
            &session.mac_to_phone_key,
            SecureSender::Mac,
            envelope.counter,
        )?;
        let payload: SecureApplicationPayload = serde_json::from_slice(&plaintext)
            .map_err(|error| SecureRelayClientError::Serialization(error.to_string()))?;
        session.last_inbound_counter = Some(envelope.counter);
        if let Some(seq) = payload.bridge_outbound_seq {
            session.last_inbound_bridge_outbound_seq = seq;
        }
        Ok(payload)
    }

    pub fn build_trusted_session_resolve_request(
        &self,
        mac_device_id: String,
        timestamp_ms: i64,
        nonce: String,
    ) -> Result<TrustedSessionResolveRequest, SecureRelayClientError> {
        let transcript = trusted_session_resolve_transcript_bytes(
            &mac_device_id,
            &self.phone_identity.phone_device_id,
            &self.phone_identity.phone_identity_public_key,
            &nonce,
            timestamp_ms,
        )?;
        let phone_signing_key = decode_signing_key(&self.phone_identity.phone_identity_private_key)?;
        let signature = phone_signing_key.sign(&transcript);

        Ok(TrustedSessionResolveRequest {
            mac_device_id,
            phone_device_id: self.phone_identity.phone_device_id.clone(),
            phone_identity_public_key: self.phone_identity.phone_identity_public_key.clone(),
            nonce,
            timestamp: timestamp_ms,
            signature: BASE64.encode(signature.to_bytes()),
        })
    }

    pub fn apply_trusted_session_resolve_response(
        &self,
        response: TrustedSessionResolveResponse,
        relay_url: String,
    ) -> Result<PairingPayload, SecureRelayClientError> {
        if !response.ok {
            return Err(SecureRelayClientError::InvalidHandshake(
                "trusted session resolve response was not ok".to_string(),
            ));
        }

        Ok(PairingPayload {
            v: 1,
            relay: relay_url,
            session_id: response.session_id,
            mac_device_id: response.mac_device_id,
            mac_identity_public_key: response.mac_identity_public_key,
            expires_at: i64::MAX,
        })
    }
}

fn encrypt_envelope_payload<T: Serialize>(
    payload: &T,
    key: &[u8; 32],
    sender: SecureSender,
    counter: u64,
    session_id: &str,
    key_epoch: u32,
) -> Result<SecureEnvelope, SecureRelayClientError> {
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
    let nonce_bytes = nonce_for_direction(sender, counter);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let mut plaintext = serde_json::to_vec(payload)
        .map_err(|error| SecureRelayClientError::Serialization(error.to_string()))?;
    let tag = cipher
        .encrypt_in_place_detached(nonce, b"", &mut plaintext)
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;

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
) -> Result<Vec<u8>, SecureRelayClientError> {
    let cipher = Aes256Gcm::new_from_slice(key)
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
    let nonce_bytes = nonce_for_direction(sender, counter);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let mut ciphertext = BASE64
        .decode(envelope.ciphertext.as_bytes())
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
    let tag_bytes = BASE64
        .decode(envelope.tag.as_bytes())
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
    let tag = Tag::from_slice(&tag_bytes);
    cipher
        .decrypt_in_place_detached(nonce, b"", &mut ciphertext, tag)
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
    Ok(ciphertext)
}

fn derive_aes_key(
    shared_secret: &[u8],
    salt: &[u8],
    info: &[u8],
) -> Result<[u8; 32], SecureRelayClientError> {
    let hkdf = Hkdf::<Sha256>::new(Some(salt), shared_secret);
    let mut output = [0u8; 32];
    hkdf.expand(info, &mut output)
        .map_err(|_| SecureRelayClientError::Crypto("hkdf expansion failed".to_string()))?;
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
) -> Result<Vec<u8>, SecureRelayClientError> {
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
        SecureRelayClientError::Crypto(error.to_string())
    })?);
    append_length_prefixed_bytes(&mut out, &BASE64.decode(phone_identity_public_key.as_bytes()).map_err(|error| {
        SecureRelayClientError::Crypto(error.to_string())
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

fn decode_32_bytes(encoded: &str) -> Result<[u8; 32], SecureRelayClientError> {
    let bytes = BASE64
        .decode(encoded.as_bytes())
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?;
    bytes.try_into().map_err(|_| {
        SecureRelayClientError::Crypto("expected exactly 32 decoded bytes".to_string())
    })
}

fn decode_signing_key(encoded: &str) -> Result<ed25519_dalek::SigningKey, SecureRelayClientError> {
    let bytes = decode_32_bytes(encoded)?;
    Ok(ed25519_dalek::SigningKey::from_bytes(&bytes))
}

fn decode_verifying_key(encoded: &str) -> Result<VerifyingKey, SecureRelayClientError> {
    let bytes = decode_32_bytes(encoded)?;
    VerifyingKey::from_bytes(&bytes)
        .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))
}

fn random_nonce(length: usize) -> Vec<u8> {
    use rand_core::{OsRng, RngCore};
    let mut bytes = vec![0u8; length];
    OsRng.fill_bytes(&mut bytes);
    bytes
}

fn trusted_session_resolve_transcript_bytes(
    mac_device_id: &str,
    phone_device_id: &str,
    phone_identity_public_key: &str,
    nonce: &str,
    timestamp: i64,
) -> Result<Vec<u8>, SecureRelayClientError> {
    let mut data = Vec::new();
    append_length_prefixed_utf8(&mut data, LITTER_TRUSTED_SESSION_RESOLVE_TAG);
    append_length_prefixed_utf8(&mut data, mac_device_id);
    append_length_prefixed_utf8(&mut data, phone_device_id);
    append_length_prefixed_bytes(
        &mut data,
        &BASE64
            .decode(phone_identity_public_key.as_bytes())
            .map_err(|error| SecureRelayClientError::Crypto(error.to_string()))?,
    );
    append_length_prefixed_utf8(&mut data, nonce);
    append_length_prefixed_utf8(&mut data, timestamp.to_string());
    Ok(data)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_state::BridgeDeviceState;
    use crate::phone_identity::PhoneIdentityState;
    use crate::secure_transport::BridgeSecureTransport;

    #[test]
    fn client_and_bridge_complete_secure_roundtrip() {
        let bridge_state = BridgeDeviceState::create_new();
        let phone_identity = PhoneIdentityState::create_new();
        let mut bridge = BridgeSecureTransport::new(bridge_state);
        let pairing = bridge.create_pairing_payload("ws://relay.example.test/relay", "session-1");
        let mut client = SecureRelayClient::new(phone_identity);

        let hello = client.begin_handshake(pairing.clone(), false).expect("hello");
        let hello_result = bridge
            .handle_incoming_wire_message(&serde_json::to_string(&hello).expect("serialize hello"), &pairing.session_id)
            .expect("bridge hello");
        let server_hello: SecureServerHello =
            serde_json::from_str(&hello_result.outbound_wire_texts[0]).expect("server hello");

        let client_auth = client.handle_server_hello(server_hello).expect("client auth");
        let auth_result = bridge
            .handle_incoming_wire_message(
                &serde_json::to_string(&client_auth).expect("serialize client auth"),
                &pairing.session_id,
            )
            .expect("bridge auth");
        let ready: SecureReady =
            serde_json::from_str(&auth_result.outbound_wire_texts[0]).expect("ready");
        let resume = client.finalize_handshake(ready, 0).expect("resume");
        let _ = bridge
            .handle_incoming_wire_message(
                &serde_json::to_string(&resume).expect("serialize resume"),
                &pairing.session_id,
            )
            .expect("bridge resume");

        let outbound = client
            .encrypt_application_message("hello from phone".to_string())
            .expect("encrypt");
        let inbound = bridge
            .handle_incoming_wire_message(
                &serde_json::to_string(&outbound).expect("serialize outbound"),
                &pairing.session_id,
            )
            .expect("bridge inbound");
        assert_eq!(inbound.application_messages, vec!["hello from phone"]);

        let bridge_outbound = bridge
            .queue_outbound_application_message("hello from mac", &pairing.session_id)
            .expect("queue bridge outbound");
        let envelope: SecureEnvelope =
            serde_json::from_str(&bridge_outbound.outbound_wire_texts[0]).expect("envelope");
        let payload = client.decrypt_application_message(envelope).expect("decrypt inbound");
        assert_eq!(payload.payload_text, "hello from mac");
    }

    #[test]
    fn trusted_session_resolve_request_is_signed() {
        let client = SecureRelayClient::new(PhoneIdentityState::create_new());
        let request = client
            .build_trusted_session_resolve_request(
                "mac-1".to_string(),
                1_730_000_000_000,
                "nonce-1".to_string(),
            )
            .expect("request");
        assert_eq!(request.mac_device_id, "mac-1");
        assert_eq!(request.nonce, "nonce-1");
        assert!(!request.signature.is_empty());
    }
}
