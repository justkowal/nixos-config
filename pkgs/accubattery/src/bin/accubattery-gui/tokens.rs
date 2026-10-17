//! Lab design tokens (~/.config/lab/tokens.json) so the chart follows the same text size as the desk.
//! Colour is not in the tokens: Matugen themes GTK itself, so libadwaita colours are already right.

pub struct Style {
    pub caption_pt: f64,
    pub line_px: f64,
}

pub fn load() -> Style {
    let raw = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".config")))
        .map(|d| d.join("lab/tokens.json"))
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok())
        .unwrap_or(serde_json::Value::Null);
    let scale = raw["textScale"].as_f64().unwrap_or(1.0);
    Style {
        caption_pt: raw["type"]["sizes"]["caption"].as_f64().unwrap_or(9.0) * scale,
        line_px: raw["space"][0].as_f64().unwrap_or(4.0) / 2.0,
    }
}
