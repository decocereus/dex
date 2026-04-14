use super::*;

pub(super) fn spawn_store_listener(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    mut rx: broadcast::Receiver<UiEvent>,
) {
    MobileClient::spawn_detached(async move {
        loop {
            match rx.recv().await {
                Ok(event) => {
                    if should_suppress_websocket_stream_event_for_live_ipc(
                        &app_store, &sessions, &event,
                    ) {
                        continue;
                    }
                    app_store.apply_ui_event(&event);
                    if let UiEvent::TurnCompleted { key, .. } = &event {
                        maybe_send_next_local_queued_follow_up(
                            Arc::clone(&app_store),
                            Arc::clone(&sessions),
                            key.clone(),
                        )
                        .await;
                    }
                }
                Err(broadcast::error::RecvError::Closed) => break,
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    warn!("MobileClient: lagged {skipped} UI events");
                }
            }
        }
    });
}

pub(super) fn websocket_stream_event_key(event: &UiEvent) -> Option<&ThreadKey> {
    match event {
        UiEvent::MessageDelta { key, .. }
        | UiEvent::ReasoningDelta { key, .. }
        | UiEvent::PlanDelta { key, .. }
        | UiEvent::CommandOutputDelta { key, .. } => Some(key),
        _ => None,
    }
}

pub(super) fn should_suppress_websocket_stream_event(
    event: &UiEvent,
    server_has_live_ipc: bool,
) -> bool {
    server_has_live_ipc && websocket_stream_event_key(event).is_some()
}

pub(super) fn should_suppress_websocket_stream_event_for_live_ipc(
    app_store: &AppStoreReducer,
    sessions: &RwLock<HashMap<String, Arc<ServerSession>>>,
    event: &UiEvent,
) -> bool {
    let Some(key) = websocket_stream_event_key(event) else {
        return false;
    };

    let session = match sessions.read() {
        Ok(guard) => guard.get(&key.server_id).cloned(),
        Err(error) => {
            warn!("MobileClient: recovering poisoned sessions read lock");
            error.into_inner().get(&key.server_id).cloned()
        }
    };
    let Some(session) = session else {
        return false;
    };

    should_suppress_websocket_stream_event(
        event,
        server_has_live_ipc(app_store, &key.server_id, &session),
    )
}

pub(super) async fn maybe_send_next_local_queued_follow_up(
    app_store: Arc<AppStoreReducer>,
    sessions: Arc<RwLock<HashMap<String, Arc<ServerSession>>>>,
    key: ThreadKey,
) {
    let snapshot = app_store.snapshot();
    let server_has_ipc = snapshot
        .servers
        .get(&key.server_id)
        .map(|server| server.has_ipc)
        .unwrap_or(false);
    let Some(thread) = snapshot.threads.get(&key).cloned() else {
        return;
    };
    if thread.active_turn_id.is_some() || thread.queued_follow_up_drafts.is_empty() {
        return;
    }

    let session = match sessions.read() {
        Ok(guard) => guard.get(&key.server_id).cloned(),
        Err(error) => {
            warn!("MobileClient: recovering poisoned sessions read lock");
            error.into_inner().get(&key.server_id).cloned()
        }
    };
    let Some(session) = session else {
        return;
    };
    if session.has_ipc() && server_has_ipc {
        return;
    }

    let next = thread.queued_follow_up_drafts.first().cloned();
    let Some(draft) = next else {
        return;
    };
    let response = session.request(
        "turn/start",
        serde_json::json!({
            "threadId": key.thread_id,
            "input": draft.inputs,
        }),
    );
    if let Err(error) = response.await {
        warn!(
            "MobileClient: failed to autosend queued follow-up for {} thread {}: {}",
            key.server_id, key.thread_id, error
        );
    }
}
