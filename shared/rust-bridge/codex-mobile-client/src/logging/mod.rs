use std::sync::Arc;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use codex_ipc::{RawFrameDirection, install_raw_frame_trace_observer};
use tracing::Level;

static TRACING_SUBSCRIBER_INSTALLED: OnceLock<()> = OnceLock::new();
const JSON_LOG_PREVIEW_LIMIT: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LogLevelName {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
}

impl LogLevelName {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Trace => "TRACE",
            Self::Debug => "DEBUG",
            Self::Info => "INFO",
            Self::Warn => "WARN",
            Self::Error => "ERROR",
        }
    }

    fn into_tracing(self) -> Level {
        match self {
            Self::Trace => Level::TRACE,
            Self::Debug => Level::DEBUG,
            Self::Info => Level::INFO,
            Self::Warn => Level::WARN,
            Self::Error => Level::ERROR,
        }
    }
}

pub(crate) fn install_tracing_subscriber() {
    TRACING_SUBSCRIBER_INSTALLED.get_or_init(|| {
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .without_time()
            .compact()
            .with_target(true)
            .with_max_level(Level::TRACE);
        #[cfg(target_os = "ios")]
        let subscriber = subscriber.with_writer(std::io::stderr).finish();
        #[cfg(not(target_os = "ios"))]
        let subscriber = subscriber.finish();
        let _ = tracing::subscriber::set_global_default(subscriber);
    });
}

pub(crate) fn log_rust(
    level: LogLevelName,
    subsystem: impl Into<String>,
    category: impl Into<String>,
    message: impl Into<String>,
    fields_json: Option<String>,
) {
    install_tracing_subscriber();

    let subsystem = subsystem.into();
    let category = category.into();
    let message = message.into();
    let fields_json = fields_json.filter(|value| !value.trim().is_empty());

    match (level.into_tracing(), fields_json.as_deref()) {
        (Level::TRACE, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::TRACE,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::DEBUG, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::DEBUG,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::INFO, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::INFO,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::WARN, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::WARN,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::ERROR, Some(fields_json)) => {
            tracing::event!(
                target: "mobile",
                Level::ERROR,
                subsystem = %subsystem,
                category = %category,
                fields_json = %fields_json,
                "{message}"
            );
        }
        (Level::TRACE, None) => {
            tracing::event!(target: "mobile", Level::TRACE, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::DEBUG, None) => {
            tracing::event!(target: "mobile", Level::DEBUG, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::INFO, None) => {
            tracing::event!(target: "mobile", Level::INFO, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::WARN, None) => {
            tracing::event!(target: "mobile", Level::WARN, subsystem = %subsystem, category = %category, "{message}");
        }
        (Level::ERROR, None) => {
            tracing::event!(target: "mobile", Level::ERROR, subsystem = %subsystem, category = %category, "{message}");
        }
    }
}

pub(crate) fn install_ipc_wire_trace_logger() {
    install_tracing_subscriber();
    install_raw_frame_trace_observer(Arc::new(|direction, payload| {
        let timestamp_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default();
        let summary = summarize_ipc_frame(payload);
        let direction_label = match direction {
            RawFrameDirection::In => "in",
            RawFrameDirection::Out => "out",
        };
        tracing::event!(
            target: "mobile",
            Level::TRACE,
            subsystem = "ipc",
            category = "wire",
            direction = direction_label,
            ts_ms = timestamp_ms,
            bytes = payload.len(),
            summary = %summary,
            "IPC raw frame"
        );
    }));
}

pub(crate) fn summarize_json_for_log(payload: &str) -> String {
    let compact = serde_json::from_str::<serde_json::Value>(payload)
        .ok()
        .and_then(|value| serde_json::to_string(&value).ok())
        .unwrap_or_else(|| payload.trim().to_string());

    truncate_log_preview(&compact, JSON_LOG_PREVIEW_LIMIT)
}

fn truncate_log_preview(value: &str, limit: usize) -> String {
    let total_chars = value.chars().count();
    let total_bytes = value.len();
    if total_chars <= limit {
        return value.to_string();
    }

    let preview: String = value.chars().take(limit).collect();
    format!(
        "{preview}… ({total_chars} chars, {})",
        format_bytes(total_bytes)
    )
}

fn format_bytes(bytes: usize) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];

    let mut value = bytes as f64;
    let mut unit_index = 0;
    while value >= 1024.0 && unit_index < UNITS.len() - 1 {
        value /= 1024.0;
        unit_index += 1;
    }

    if unit_index == 0 {
        format!("{bytes} {}", UNITS[unit_index])
    } else {
        format!("{value:.1} {}", UNITS[unit_index])
    }
}

fn summarize_ipc_frame(payload: &str) -> String {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(payload) else {
        return "invalid-json".to_string();
    };

    let envelope_type = value
        .get("type")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("unknown");

    let method = value
        .get("method")
        .and_then(serde_json::Value::as_str)
        .or_else(|| {
            value
                .get("request")
                .and_then(|request| request.get("method"))
                .and_then(serde_json::Value::as_str)
        })
        .unwrap_or("-");

    let request_id = value
        .get("requestId")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("-");

    let result_type = value
        .get("resultType")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("-");

    format!(
        "type={} method={} request_id={} result_type={}",
        envelope_type, method, request_id, result_type
    )
}

#[cfg(test)]
mod tests {
    use super::{LogLevelName, format_bytes, summarize_json_for_log};

    #[test]
    fn log_level_name_strings_match_expected_format() {
        assert_eq!(LogLevelName::Trace.as_str(), "TRACE");
        assert_eq!(LogLevelName::Debug.as_str(), "DEBUG");
        assert_eq!(LogLevelName::Info.as_str(), "INFO");
        assert_eq!(LogLevelName::Warn.as_str(), "WARN");
        assert_eq!(LogLevelName::Error.as_str(), "ERROR");
    }

    #[test]
    fn summarize_json_for_log_keeps_short_payloads() {
        let payload = r#"{"data":[{"agentNick":"worker"}]}"#;
        assert_eq!(summarize_json_for_log(payload), payload);
    }

    #[test]
    fn summarize_json_for_log_truncates_long_payloads() {
        let payload = format!(r#"{{"data":[{{"message":"{}"}}]}}"#, "x".repeat(700));
        let summary = summarize_json_for_log(&payload);
        assert!(summary.len() < payload.len());
        assert!(summary.contains("chars, "));
        assert!(summary.contains("B)"));
        assert!(summary.starts_with(r#"{"data":[{"message":"#));
    }

    #[test]
    fn format_bytes_uses_human_readable_units() {
        assert_eq!(format_bytes(999), "999 B");
        assert_eq!(format_bytes(1024), "1.0 KB");
        assert_eq!(format_bytes(1536), "1.5 KB");
        assert_eq!(format_bytes(1024 * 1024), "1.0 MB");
    }
}
