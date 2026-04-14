use std::path::PathBuf;
use std::sync::Mutex;

use litter_mac_bridge_core::phone_identity::PhoneIdentityStore;
use litter_mac_bridge_core::protocol::{
    PairingPayload, SecureApplicationPayload, SecureEnvelope, SecureReady, SecureServerHello,
    TrustedSessionResolveResponse,
};
use litter_mac_bridge_core::secure_relay_client::SecureRelayClient;

use crate::ffi::ClientError;

#[derive(uniffi::Record)]
pub struct AppPhoneIdentityRecord {
    pub phone_device_id: String,
    pub phone_identity_public_key: String,
}

#[derive(uniffi::Record)]
pub struct AppSecureApplicationPayloadRecord {
    pub bridge_outbound_seq: Option<u64>,
    pub payload_text: String,
}

#[derive(uniffi::Object)]
pub struct SecureRelayBridgeClient {
    store: PhoneIdentityStore,
    inner: Mutex<SecureRelayClient>,
}

#[uniffi::export]
impl SecureRelayBridgeClient {
    #[uniffi::constructor]
    pub fn new(identity_path: Option<String>) -> Result<Self, ClientError> {
        let store = PhoneIdentityStore::new(
            identity_path
                .map(PathBuf::from)
                .unwrap_or_else(PhoneIdentityStore::default_path),
        );
        let identity = store
            .load_or_create()
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        Ok(Self {
            store,
            inner: Mutex::new(SecureRelayClient::new(identity)),
        })
    }

    pub fn phone_identity(&self) -> Result<AppPhoneIdentityRecord, ClientError> {
        let guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let identity = guard.phone_identity();
        Ok(AppPhoneIdentityRecord {
            phone_device_id: identity.phone_device_id.clone(),
            phone_identity_public_key: identity.phone_identity_public_key.clone(),
        })
    }

    pub fn identity_path(&self) -> String {
        self.store.path().display().to_string()
    }

    pub fn begin_handshake(
        &self,
        pairing_payload_json: String,
        trusted_reconnect: bool,
    ) -> Result<String, ClientError> {
        let pairing_payload: PairingPayload = serde_json::from_str(&pairing_payload_json)
            .map_err(|error| ClientError::Serialization(error.to_string()))?;
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let hello = guard
            .begin_handshake(pairing_payload, trusted_reconnect)
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        serde_json::to_string(&hello).map_err(|error| ClientError::Serialization(error.to_string()))
    }

    pub fn handle_server_hello(&self, server_hello_json: String) -> Result<String, ClientError> {
        let server_hello: SecureServerHello = serde_json::from_str(&server_hello_json)
            .map_err(|error| ClientError::Serialization(error.to_string()))?;
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let client_auth = guard
            .handle_server_hello(server_hello)
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        serde_json::to_string(&client_auth)
            .map_err(|error| ClientError::Serialization(error.to_string()))
    }

    pub fn finalize_handshake(
        &self,
        secure_ready_json: String,
        last_applied_bridge_outbound_seq: u64,
    ) -> Result<String, ClientError> {
        let ready: SecureReady = serde_json::from_str(&secure_ready_json)
            .map_err(|error| ClientError::Serialization(error.to_string()))?;
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let resume = guard
            .finalize_handshake(ready, last_applied_bridge_outbound_seq)
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        serde_json::to_string(&resume)
            .map_err(|error| ClientError::Serialization(error.to_string()))
    }

    pub fn encrypt_message(&self, payload_text: String) -> Result<String, ClientError> {
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let envelope = guard
            .encrypt_application_message(payload_text)
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        serde_json::to_string(&envelope)
            .map_err(|error| ClientError::Serialization(error.to_string()))
    }

    pub fn decrypt_message(
        &self,
        envelope_json: String,
    ) -> Result<AppSecureApplicationPayloadRecord, ClientError> {
        let envelope: SecureEnvelope = serde_json::from_str(&envelope_json)
            .map_err(|error| ClientError::Serialization(error.to_string()))?;
        let mut guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let payload: SecureApplicationPayload = guard
            .decrypt_application_message(envelope)
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        Ok(AppSecureApplicationPayloadRecord {
            bridge_outbound_seq: payload.bridge_outbound_seq,
            payload_text: payload.payload_text,
        })
    }

    pub fn is_ready(&self) -> Result<bool, ClientError> {
        let guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        Ok(guard.is_ready())
    }

    pub fn build_trusted_session_resolve_request(
        &self,
        mac_device_id: String,
        timestamp_ms: i64,
        nonce: String,
    ) -> Result<String, ClientError> {
        let guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let request = guard
            .build_trusted_session_resolve_request(mac_device_id, timestamp_ms, nonce)
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        serde_json::to_string(&request)
            .map_err(|error| ClientError::Serialization(error.to_string()))
    }

    pub fn pairing_payload_from_trusted_session_response(
        &self,
        response_json: String,
        relay_url: String,
    ) -> Result<String, ClientError> {
        let response: TrustedSessionResolveResponse = serde_json::from_str(&response_json)
            .map_err(|error| ClientError::Serialization(error.to_string()))?;
        let guard = self
            .inner
            .lock()
            .map_err(|_| ClientError::Rpc("secure relay client lock poisoned".to_string()))?;
        let payload = guard
            .apply_trusted_session_resolve_response(response, relay_url)
            .map_err(|error| ClientError::Rpc(error.to_string()))?;
        serde_json::to_string(&payload)
            .map_err(|error| ClientError::Serialization(error.to_string()))
    }
}
