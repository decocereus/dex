use std::io;

use thiserror::Error;

use crate::codex_transport::CodexTransport;
use crate::device_state::BridgeDeviceState;
use crate::protocol::PairingPayload;
use crate::secure_transport::{BridgeSecureTransport, BridgeSecureTransportError};

#[derive(Debug, Error)]
pub enum BridgeRuntimeError {
    #[error(transparent)]
    Secure(#[from] BridgeSecureTransportError),
    #[error("codex transport error: {0}")]
    Codex(#[from] io::Error),
}

pub struct BridgeRuntime<T: CodexTransport> {
    relay_url: String,
    session_id: String,
    secure_transport: BridgeSecureTransport,
    codex_transport: T,
    device_state_dirty: bool,
}

impl<T: CodexTransport> BridgeRuntime<T> {
    pub fn new(
        relay_url: String,
        session_id: String,
        device_state: BridgeDeviceState,
        codex_transport: T,
    ) -> Self {
        Self {
            relay_url,
            session_id,
            secure_transport: BridgeSecureTransport::new(device_state),
            codex_transport,
            device_state_dirty: false,
        }
    }

    pub fn pairing_payload(&mut self) -> PairingPayload {
        self.secure_transport
            .create_pairing_payload(&self.relay_url, &self.session_id)
    }

    pub fn device_state(&self) -> &BridgeDeviceState {
        self.secure_transport.device_state()
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    pub fn relay_url(&self) -> &str {
        &self.relay_url
    }

    pub fn device_state_dirty(&self) -> bool {
        self.device_state_dirty
    }

    pub fn clear_device_state_dirty(&mut self) {
        self.device_state_dirty = false;
    }

    pub fn is_secure_channel_ready(&self) -> bool {
        self.secure_transport.is_secure_channel_ready()
    }

    pub async fn ingest_relay_wire_text(
        &mut self,
        raw_message: &str,
    ) -> Result<Vec<String>, BridgeRuntimeError> {
        let result = self
            .secure_transport
            .handle_incoming_wire_message(raw_message, &self.session_id)?;

        for application_message in result.application_messages {
            self.codex_transport.send_line(application_message).await?;
        }
        self.device_state_dirty |= result.device_state_changed;

        Ok(result.outbound_wire_texts)
    }

    pub fn drain_codex_output(&mut self) -> Result<Vec<String>, BridgeRuntimeError> {
        let mut outbound = Vec::new();
        while let Some(line) = self.codex_transport.try_recv_line()? {
            let queued = self
                .secure_transport
                .queue_outbound_application_message(line, &self.session_id)?;
            self.device_state_dirty |= queued.device_state_changed;
            outbound.extend(queued.outbound_wire_texts);
        }
        Ok(outbound)
    }

    pub async fn shutdown(&mut self) -> Result<(), BridgeRuntimeError> {
        self.codex_transport.shutdown().await?;
        Ok(())
    }
}
