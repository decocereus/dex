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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PhoneIdentityState {
    pub phone_device_id: String,
    pub phone_identity_private_key: String,
    pub phone_identity_public_key: String,
}

impl PhoneIdentityState {
    pub fn create_new() -> Self {
        let mut rng = OsRng;
        let signing_key = SigningKey::generate(&mut rng);
        let verifying_key = signing_key.verifying_key();
        Self {
            phone_device_id: Uuid::new_v4().to_string(),
            phone_identity_private_key: BASE64.encode(signing_key.to_bytes()),
            phone_identity_public_key: BASE64.encode(verifying_key.to_bytes()),
        }
    }
}

#[derive(Debug, Error)]
pub enum PhoneIdentityStoreError {
    #[error("phone identity at {path} is unreadable: {message}")]
    Corrupted { path: PathBuf, message: String },
    #[error("failed to read phone identity at {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to write phone identity at {path}: {source}")]
    Write {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

#[derive(Debug, Clone)]
pub struct PhoneIdentityStore {
    path: PathBuf,
}

impl PhoneIdentityStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn default_path() -> PathBuf {
        if let Some(explicit) = env::var_os("LITTER_BRIDGE_PHONE_IDENTITY_FILE") {
            return PathBuf::from(explicit);
        }

        let dir = env::var_os("LITTER_BRIDGE_PHONE_IDENTITY_DIR")
            .map(PathBuf::from)
            .or_else(default_store_dir)
            .unwrap_or_else(|| PathBuf::from(".litter-bridge"));
        dir.join("phone-identity.json")
    }

    pub fn load_or_create(&self) -> Result<PhoneIdentityState, PhoneIdentityStoreError> {
        match self.load()? {
            Some(identity) => Ok(identity),
            None => {
                let identity = PhoneIdentityState::create_new();
                self.save(&identity)?;
                Ok(identity)
            }
        }
    }

    pub fn load(&self) -> Result<Option<PhoneIdentityState>, PhoneIdentityStoreError> {
        if !self.path.exists() {
            return Ok(None);
        }

        let raw = fs::read_to_string(&self.path).map_err(|source| PhoneIdentityStoreError::Read {
            path: self.path.clone(),
            source,
        })?;
        let identity = serde_json::from_str::<PhoneIdentityState>(&raw).map_err(|error| {
            PhoneIdentityStoreError::Corrupted {
                path: self.path.clone(),
                message: error.to_string(),
            }
        })?;
        Ok(Some(identity))
    }

    pub fn save(&self, identity: &PhoneIdentityState) -> Result<(), PhoneIdentityStoreError> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent).map_err(|source| PhoneIdentityStoreError::Write {
                path: parent.to_path_buf(),
                source,
            })?;
        }

        let raw = serde_json::to_string_pretty(identity).map_err(|error| {
            PhoneIdentityStoreError::Corrupted {
                path: self.path.clone(),
                message: error.to_string(),
            }
        })?;
        fs::write(&self.path, raw).map_err(|source| PhoneIdentityStoreError::Write {
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
    env::var_os("HOME").map(PathBuf::from).map(|home| {
        #[cfg(target_os = "ios")]
        {
            home.join("Library")
                .join("Application Support")
                .join("codex")
                .join("bridge")
        }
        #[cfg(not(target_os = "ios"))]
        {
            home.join(".litter-bridge")
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn round_trips_phone_identity() {
        let tmp = tempdir().expect("tempdir");
        let store = PhoneIdentityStore::new(tmp.path().join("phone-identity.json"));
        let identity = store.load_or_create().expect("identity");
        assert!(!identity.phone_device_id.is_empty());

        store.save(&identity).expect("save");
        let loaded = store.load().expect("load").expect("some");
        assert_eq!(loaded, identity);
    }
}
