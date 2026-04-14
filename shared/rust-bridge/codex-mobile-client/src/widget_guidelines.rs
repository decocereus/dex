//! Generative UI dynamic tool specs and `visualize_read_me` handler.
//!
//! The tool specs are defined here so both iOS and Android can register
//! the same tools via a single UniFFI call. The `visualize_read_me`
//! response is assembled from embedded markdown guidelines.

use crate::types::models::AppDynamicToolSpec;

// ── Embedded guideline sections ─────────────────────────────────────────

const CORE: &str = include_str!("widget_guidelines/core.md");
const SVG_SETUP: &str = include_str!("widget_guidelines/svg_setup.md");
const ART_AND_ILLUSTRATION: &str = include_str!("widget_guidelines/art_and_illustration.md");
const UI_COMPONENTS: &str = include_str!("widget_guidelines/ui_components.md");
const COLOR_PALETTE: &str = include_str!("widget_guidelines/color_palette.md");
const CHARTS_CHART_JS: &str = include_str!("widget_guidelines/charts_chart_js.md");
const DIAGRAM_TYPES: &str = include_str!("widget_guidelines/diagram_types.md");

/// Available module names for the `visualize_read_me` tool schema.
pub const AVAILABLE_MODULES: &[&str] = &["art", "mockup", "interactive", "chart", "diagram"];

/// Sections required by each module.
fn sections_for_module(module: &str) -> &'static [&'static str] {
    match module {
        "art" => &["svg_setup", "art_and_illustration"],
        "mockup" => &["ui_components", "color_palette"],
        "interactive" => &["ui_components", "color_palette"],
        "chart" => &["ui_components", "color_palette", "charts_chart_js"],
        "diagram" => &["color_palette", "svg_setup", "diagram_types"],
        _ => &[],
    }
}

fn section_content(name: &str) -> &'static str {
    match name {
        "svg_setup" => SVG_SETUP,
        "art_and_illustration" => ART_AND_ILLUSTRATION,
        "ui_components" => UI_COMPONENTS,
        "color_palette" => COLOR_PALETTE,
        "charts_chart_js" => CHARTS_CHART_JS,
        "diagram_types" => DIAGRAM_TYPES,
        _ => "",
    }
}

// ── Public API ──────────────────────────────────────────────────────────

/// Build the guidelines text for the requested modules.
pub fn get_guidelines(modules: &[String]) -> String {
    let mut content = CORE.to_string();
    let mut seen = std::collections::HashSet::new();

    for module in modules {
        for &section in sections_for_module(module.as_str()) {
            if seen.insert(section) {
                content.push_str("\n\n\n");
                content.push_str(section_content(section));
            }
        }
    }
    content.push('\n');
    content
}

/// Handle a `visualize_read_me` dynamic tool call.
///
/// Extracts the `modules` array from the tool arguments and returns
/// the assembled guidelines text.
pub fn handle_visualize_read_me(arguments: &serde_json::Value) -> Result<String, String> {
    let modules: Vec<String> = arguments
        .get("modules")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();

    if modules.is_empty() {
        // Return core guidelines with all module names listed.
        return Ok(get_guidelines(&[]));
    }

    Ok(get_guidelines(&modules))
}

/// Handle a `show_widget` dynamic tool call.
///
/// The widget HTML is in the arguments — the conversation hydration layer
/// extracts it from the DynamicToolCall item for rendering. We just need
/// to acknowledge success.
pub fn handle_show_widget(arguments: &serde_json::Value) -> Result<String, String> {
    let title = arguments
        .get("title")
        .and_then(|v| v.as_str())
        .unwrap_or("widget");
    Ok(format!("Widget \"{title}\" rendered."))
}

// ── Tool spec generation ────────────────────────────────────────────────

/// Returns the generative UI dynamic tool specs for registration on
/// thread/start. Called from both iOS and Android when the experimental
/// feature is enabled.
#[uniffi::export]
pub fn generative_ui_dynamic_tool_specs() -> Vec<AppDynamicToolSpec> {
    vec![read_me_tool_spec(), show_widget_tool_spec()]
}

fn read_me_tool_spec() -> AppDynamicToolSpec {
    let modules_enum: Vec<serde_json::Value> = AVAILABLE_MODULES
        .iter()
        .map(|m| serde_json::Value::String(m.to_string()))
        .collect();

    let schema = serde_json::json!({
        "type": "object",
        "properties": {
            "modules": {
                "type": "array",
                "items": {
                    "type": "string",
                    "enum": modules_enum
                },
                "description": "Which module(s) to load. Pick all that fit."
            }
        },
        "required": ["modules"]
    });

    AppDynamicToolSpec {
        name: "visualize_read_me".to_string(),
        description: concat!(
            "Returns design guidelines for show_widget (CSS patterns, colors, typography, ",
            "layout rules, examples). Call once before your first show_widget call. Do NOT ",
            "mention this call to the user — it is an internal setup step. Pick the modules ",
            "that match your use case: interactive, chart, mockup, art, diagram."
        )
        .to_string(),
        input_schema_json: serde_json::to_string(&schema).unwrap_or_default(),
        defer_loading: false,
    }
}

fn show_widget_tool_spec() -> AppDynamicToolSpec {
    let schema = serde_json::json!({
        "type": "object",
        "properties": {
            "i_have_seen_read_me": {
                "type": "boolean",
                "description": "Confirm you have already called visualize_read_me in this conversation."
            },
            "title": {
                "type": "string",
                "description": "Short snake_case identifier for this widget (used as widget title)."
            },
            "widget_code": {
                "type": "string",
                "description": concat!(
                    "HTML or SVG code to render. For SVG: raw SVG starting with <svg>. ",
                    "For HTML: raw content fragment, no DOCTYPE/<html>/<head>/<body>."
                )
            },
            "width": {
                "type": "number",
                "description": "Widget width in pixels. Default: 800."
            },
            "height": {
                "type": "number",
                "description": "Widget height in pixels. Default: 600."
            }
        },
        "required": ["i_have_seen_read_me", "title", "widget_code"]
    });

    AppDynamicToolSpec {
        name: "show_widget".to_string(),
        description: concat!(
            "Show visual content — SVG graphics, diagrams, charts, or interactive HTML ",
            "widgets — rendered inline in the conversation. Use for flowcharts, dashboards, ",
            "forms, calculators, data tables, games, illustrations, or any visual content. ",
            "The HTML is rendered in a native WKWebView with full CSS/JS support including ",
            "Canvas and CDN libraries. IMPORTANT: Call visualize_read_me once before your ",
            "first show_widget call. Structure HTML as fragments: no DOCTYPE/<html>/<head>/<body>. ",
            "Style first (<style> block under ~15 lines), then HTML content, then <script> ",
            "tags last. Scripts execute after streaming completes. Load libraries via ",
            "<script src=\"https://cdnjs.cloudflare.com/ajax/libs/...\"> (UMD globals). ",
            "CDN allowlist: cdnjs.cloudflare.com, esm.sh, cdn.jsdelivr.net, unpkg.com. ",
            "Dark mode is mandatory — use CSS variables for all colors. Background is ",
            "transparent (host provides bg). Keep widgets focused. Default size is 800x600 ",
            "but adjust to fit content. For SVG: start code with <svg> tag directly."
        )
        .to_string(),
        input_schema_json: serde_json::to_string(&schema).unwrap_or_default(),
        defer_loading: false,
    }
}
