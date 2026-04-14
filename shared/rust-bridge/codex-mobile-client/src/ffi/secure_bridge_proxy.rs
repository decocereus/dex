use crate::ffi::ClientError;
use crate::secure_bridge_proxy::{PairedMacConfig, SecureBridgeProxyManager};

#[derive(uniffi::Object)]
pub struct SecureRelayProxyBridge {
    inner: SecureBridgeProxyManager,
}

#[uniffi::export(async_runtime = "tokio")]
impl SecureRelayProxyBridge {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self {
            inner: SecureBridgeProxyManager::new(),
        }
    }

    pub async fn start_paired_mac_proxy(
        &self,
        relay_url: String,
        relay_session_id: String,
        mac_device_id: String,
        mac_identity_public_key: String,
        trusted_reconnect: bool,
    ) -> Result<String, ClientError> {
        self.inner
            .start_paired_mac_proxy(PairedMacConfig {
                relay_url,
                relay_session_id,
                mac_device_id,
                mac_identity_public_key,
                trusted_reconnect,
            })
            .await
            .map_err(|error| ClientError::Transport(error.to_string()))
    }

    pub async fn stop(&self) {
        self.inner.stop().await;
    }

    pub fn active_local_url(&self) -> Result<Option<String>, ClientError> {
        Ok(self.inner.active_local_url())
    }
}
