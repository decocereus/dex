use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use ed25519_dalek::SigningKey;
use rand_core::OsRng;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum BridgeDeviceStateError {
    #[error("bridge device state at {path} is unreadable: {message}")]
    Corrupted { path: PathBuf, message: String },
    #[error("failed to read bridge device state at {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to write bridge device state at {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeDeviceState {
    pub version: u32,
    pub mac_device_id: String,
    pub mac_identity_public_key: String,
    pub mac_identity_private_key: String,
    #[serde(default)]
    pub trusted_phones: BTreeMap<String, String>,
    #[serde(default)]
    pub last_seen_phone_app_version: Option<String>,
}

impl BridgeDeviceState {
    pub fn create_new() -> Self {
        let mut rng = OsRng;
        let signing_key = SigningKey::generate(&mut rng);
        let verifying_key = signing_key.verifying_key();
        Self {
            version: 1,
            mac_device_id: Uuid::new_v4().to_string(),
            mac_identity_public_key: BASE64.encode(verifying_key.to_bytes()),
            mac_identity_private_key: BASE64.encode(signing_key.to_bytes()),
            trusted_phones: BTreeMap::new(),
            last_seen_phone_app_version: None,
        }
    }

    pub fn remember_trusted_phone(&mut self, phone_device_id: &str, phone_identity_public_key: &str) -> bool {
        let phone_device_id = normalize_non_empty(phone_device_id);
        let phone_identity_public_key = normalize_non_empty(phone_identity_public_key);
        if phone_device_id.is_empty() || phone_identity_public_key.is_empty() {
            return false;
        }

        let changed = self
            .trusted_phones
            .get(&phone_device_id)
            .map(|existing| existing != &phone_identity_public_key)
            .unwrap_or(true);

        self.trusted_phones.clear();
        self.trusted_phones
            .insert(phone_device_id, phone_identity_public_key);
        changed
    }

    pub fn remember_last_seen_phone_app_version(&mut self, version: &str) -> bool {
        let version = normalize_non_empty(version);
        if version.is_empty() {
            return false;
        }
        if self.last_seen_phone_app_version.as_deref() == Some(version.as_str()) {
            return false;
        }
        self.last_seen_phone_app_version = Some(version);
        true
    }

    pub fn trusted_phone_public_key(&self, phone_device_id: &str) -> Option<&str> {
        let phone_device_id = normalize_non_empty(phone_device_id);
        self.trusted_phones.get(&phone_device_id).map(String::as_str)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BridgeRelaySession {
    pub session_id: String,
    pub is_persistent: bool,
}

pub fn resolve_bridge_relay_session() -> BridgeRelaySession {
    BridgeRelaySession {
        session_id: Uuid::new_v4().to_string(),
        is_persistent: false,
    }
}

#[derive(Debug, Clone)]
pub struct BridgeDeviceStateStore {
    path: PathBuf,
}

impl BridgeDeviceStateStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn default_path() -> PathBuf {
        if let Some(explicit) = env::var_os("LITTER_BRIDGE_DEVICE_STATE_FILE") {
            return PathBuf::from(explicit);
        }

        let dir = env::var_os("LITTER_BRIDGE_DEVICE_STATE_DIR")
            .map(PathBuf::from)
            .or_else(default_store_dir)
            .unwrap_or_else(|| PathBuf::from(".litter-bridge"));
        dir.join("device-state.json")
    }

    pub fn load_or_create(&self) -> Result<BridgeDeviceState, BridgeDeviceStateError> {
        match self.load() {
            Ok(Some(state)) => Ok(state),
            Ok(None) => {
                let state = BridgeDeviceState::create_new();
                self.save(&state)?;
                Ok(state)
            }
            Err(error) => Err(error),
        }
    }

    pub fn load(&self) -> Result<Option<BridgeDeviceState>, BridgeDeviceStateError> {
        if !self.path.exists() {
            return Ok(None);
        }

        let raw = fs::read_to_string(&self.path).map_err(|source| BridgeDeviceStateError::Read {
            path: self.path.clone(),
            source,
        })?;
        let state = serde_json::from_str::<BridgeDeviceState>(&raw).map_err(|error| {
            BridgeDeviceStateError::Corrupted {
                path: self.path.clone(),
                message: error.to_string(),
            }
        })?;
        Ok(Some(state))
    }

    pub fn save(&self, state: &BridgeDeviceState) -> Result<(), BridgeDeviceStateError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|source| BridgeDeviceStateError::Write {
                path: parent.to_path_buf(),
                source,
            })?;
        }

        let raw = serde_json::to_string_pretty(state).map_err(|error| BridgeDeviceStateError::Corrupted {
            path: self.path.clone(),
            message: error.to_string(),
        })?;
        fs::write(&self.path, raw).map_err(|source| BridgeDeviceStateError::Write {
            path: self.path.clone(),
            source,
        })?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600));
        }

        Ok(())
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

fn default_store_dir() -> Option<PathBuf> {
    env::var_os("HOME").map(PathBuf::from).map(|home| home.join(".litter-bridge"))
}

fn normalize_non_empty(value: &str) -> String {
    value.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn round_trips_device_state() {
        let tmp = tempdir().expect("tempdir");
        let store = BridgeDeviceStateStore::new(tmp.path().join("device-state.json"));
        let mut state = store.load_or_create().expect("state");
        assert!(!state.mac_device_id.is_empty());

        let changed = state.remember_trusted_phone("phone-1", "pubkey-1");
        assert!(changed);
        store.save(&state).expect("save");

        let loaded = store.load().expect("load").expect("some");
        assert_eq!(
            loaded.trusted_phone_public_key("phone-1"),
            Some("pubkey-1")
        );
    }
}
