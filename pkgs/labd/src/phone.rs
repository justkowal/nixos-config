//! The phone app server. Off unless `~/.config/lab/phone.json` enables it.
//!
//! Exposure is deliberately small: it binds only the tailnet address (never 0.0.0.0), every /api route needs
//! a bearer token, the only action is running a scene that already exists in scenes.json, request size and
//! time are capped, and there is no way to run arbitrary commands or read files.

use std::collections::HashMap;
use std::io::{self, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};

use crate::bus::Bus;

const MAX_HEADER: usize = 8 * 1024;
const MAX_BODY: usize = 4 * 1024;
const MAX_CONNECTIONS: usize = 16;
const IO_TIMEOUT: Duration = Duration::from_secs(5);

const INDEX: &str = include_str!("../assets/phone/index.html");
const APP_JS: &str = include_str!("../assets/phone/app.js");
const APP_CSS: &str = include_str!("../assets/phone/app.css");
const ICON: &str = include_str!("../assets/phone/icon.svg");
const MANIFEST: &str = include_str!("../assets/phone/manifest.webmanifest");

pub struct Config {
    pub token: String,
    pub host: String,
    /// scene name to title, from scenes.json
    pub scenes: Vec<(String, String)>,
    /// where the theme colours come from (the Matugen output the bar uses)
    pub colors_file: Option<PathBuf>,
    pub tokens_file: Option<PathBuf>,
}

pub struct Request {
    pub method: String,
    pub path: String,
    pub authorization: Option<String>,
    pub body: Vec<u8>,
}

pub struct Response {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
    pub cache: bool,
}

impl Response {
    fn text(status: u16, content_type: &'static str, body: &str, cache: bool) -> Self {
        Response {
            status,
            content_type,
            body: body.as_bytes().to_vec(),
            cache,
        }
    }
    fn json(status: u16, v: &Value) -> Self {
        Response {
            status,
            content_type: "application/json",
            body: v.to_string().into_bytes(),
            cache: false,
        }
    }
    fn error(status: u16, msg: &str) -> Self {
        Self::json(status, &json!({"ok": false, "error": msg}))
    }
}

/// Compares without stopping at the first difference, so response time does not leak how much matched.
fn tokens_equal(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        diff |= usize::from(a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(1));
    }
    diff == 0
}

fn authorized(req: &Request, cfg: &Config) -> bool {
    !cfg.token.is_empty()
        && req
            .authorization
            .as_deref()
            .and_then(|h| h.strip_prefix("Bearer "))
            .is_some_and(|t| tokens_equal(t.trim(), &cfg.token))
}

/// `@define-color name #hex;` lines from the Matugen file, so the phone follows the wallpaper accent.
fn read_colors(file: &Option<PathBuf>) -> HashMap<String, String> {
    let text = file
        .as_ref()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .unwrap_or_default();
    text.lines()
        .filter_map(|l| {
            let rest = l.trim().strip_prefix("@define-color ")?;
            let (name, value) = rest.split_once(' ')?;
            let value = value.trim().trim_end_matches(';');
            // only accept a plain hex colour, this ends up inside CSS
            (value.starts_with('#')
                && value.len() <= 9
                && value[1..].chars().all(|c| c.is_ascii_hexdigit()))
            .then(|| (name.to_owned(), value.to_owned()))
        })
        .collect()
}

fn theme_css(cfg: &Config) -> String {
    let c = read_colors(&cfg.colors_file);
    let color = |k: &str, d: &str| c.get(k).cloned().unwrap_or_else(|| d.to_owned());
    let tokens: Value = cfg
        .tokens_file
        .as_ref()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);
    let font = |k: &str, d: &str| {
        // font names go into CSS too, keep them to plain characters
        let v = tokens["type"][k].as_str().unwrap_or(d);
        if v.chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == ' ' || ch == '-')
        {
            v.to_owned()
        } else {
            d.to_owned()
        }
    };
    let radius = tokens["radius"]["md"].as_f64().unwrap_or(12.0);
    format!(
        ":root {{ --bg: {bg}; --fg: {fg}; --dim: {dim}; --card: {card}; --card-active: {active}; --line: {line}; \
         --accent: {accent}; --on-accent: {on_accent}; --danger: {danger}; --radius-md: {radius}px; \
         --font-ui: \"{ui}\", system-ui, sans-serif; --font-display: \"{display}\", ui-monospace, monospace; }}\n",
        bg = color("background", "#101010"),
        fg = color("on_background", "#eeeeee"),
        dim = color("on_surface_variant", "#aaaaaa"),
        card = color("surface_variant", "#262626"),
        active = color("outline", "#3a3a3a"),
        line = color("outline", "#3a3a3a"),
        accent = color("primary", "#ffffff"),
        on_accent = color("on_primary", "#101010"),
        danger = color("tertiary", "#e6c18d"),
        ui = font("ui", "Inter"),
        display = font("display", "Departure Mono"),
    )
}

fn activity(state: &Value) -> Vec<Value> {
    let mut rows: Vec<(f64, String)> = Vec::new();
    for (name, ev) in state.as_object().into_iter().flatten() {
        let ts = ev["ts"].as_f64().unwrap_or(0.0);
        let p = &ev["payload"];
        let text = match name.as_str() {
            "focus.on" => "Focus on".to_owned(),
            "focus.off" => "Focus off".to_owned(),
            "focus.failed" => format!(
                "Focus unavailable, {}",
                p["reason"].as_str().unwrap_or("hub error")
            ),
            "scene.done" => format!("Scene done, {}", p["title"].as_str().unwrap_or("scene")),
            "room.received" => format!("Room received, {}", p["name"].as_str().unwrap_or("room")),
            "handoff.arrived" => "Handoff complete".to_owned(),
            _ => continue,
        };
        rows.push((ts, text));
    }
    rows.sort_by(|a, b| b.0.total_cmp(&a.0));
    rows.truncate(8);
    rows.into_iter()
        .map(|(ts, text)| json!({"ts": ts, "text": text}))
        .collect()
}

pub fn state_json(cfg: &Config, bus: &Bus) -> Value {
    let state = bus.snapshot();
    let devices = state["roster.changed"]["payload"]["devices"].clone();
    json!({
        "host": cfg.host,
        "devices": if devices.is_array() { devices } else { json!([]) },
        "scenes": cfg.scenes.iter().map(|(n, t)| json!({"name": n, "title": t})).collect::<Vec<_>>(),
        "activity": activity(&state),
    })
}

fn run_scene(name: &str) {
    let name = name.to_owned();
    // the scene waits on its steps, so it must not hold the connection
    thread::spawn(move || {
        let _ = Command::new("lab").args(["scene", &name]).status();
    });
}

pub fn route(req: &Request, cfg: &Config, bus: &Bus) -> Response {
    let path = req.path.split('?').next().unwrap_or("");
    match (req.method.as_str(), path) {
        ("GET", "/") => Response::text(200, "text/html; charset=utf-8", INDEX, true),
        ("GET", "/app.js") => Response::text(200, "text/javascript; charset=utf-8", APP_JS, true),
        ("GET", "/app.css") => Response::text(200, "text/css; charset=utf-8", APP_CSS, true),
        ("GET", "/icon.svg") => Response::text(200, "image/svg+xml", ICON, true),
        ("GET", "/manifest.webmanifest") => {
            Response::text(200, "application/manifest+json", MANIFEST, true)
        }
        ("GET", "/theme.css") => {
            Response::text(200, "text/css; charset=utf-8", &theme_css(cfg), false)
        }
        ("GET", "/api/state") | ("POST", _)
            if path.starts_with("/api/") && !authorized(req, cfg) =>
        {
            Response::error(401, "unauthorized")
        }
        ("GET", "/api/state") => Response::json(200, &state_json(cfg, bus)),
        ("POST", p) if p.starts_with("/api/scene/") => {
            let name = &p["/api/scene/".len()..];
            // only scenes that exist in scenes.json, never a name taken straight into a command
            if cfg.scenes.iter().any(|(n, _)| n == name) {
                run_scene(name);
                Response::json(202, &json!({"ok": true}))
            } else {
                Response::error(404, "no such scene")
            }
        }
        (_, p) if p.starts_with("/api/") => Response::error(404, "not found"),
        ("GET" | "HEAD", _) => Response::text(404, "text/plain; charset=utf-8", "not found", false),
        _ => Response::text(
            405,
            "text/plain; charset=utf-8",
            "method not allowed",
            false,
        ),
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        202 => "Accepted",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        _ => "Error",
    }
}

fn write_response(stream: &mut TcpStream, r: &Response) -> io::Result<()> {
    let cache = if r.cache { "no-cache" } else { "no-store" };
    let head = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: {cache}\r\n\
         X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n\
         Content-Security-Policy: default-src 'self'; style-src 'self'; script-src 'self'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'\r\n\
         Connection: close\r\n\r\n",
        r.status,
        reason(r.status),
        r.content_type,
        r.body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(&r.body)
}

/// Reads one request: header up to MAX_HEADER, body up to MAX_BODY. Err carries the status to answer with.
pub fn read_request(stream: &mut impl Read) -> Result<Request, u16> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    let end = loop {
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            // the terminator can arrive in the same chunk that crosses the limit
            if i > MAX_HEADER {
                return Err(431);
            }
            break i;
        }
        if buf.len() > MAX_HEADER {
            return Err(431);
        }
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return Err(400),
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    };
    let head = std::str::from_utf8(&buf[..end]).map_err(|_| 400u16)?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or("").split(' ');
    let (method, path) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
    if method.is_empty() || !path.starts_with('/') {
        return Err(400);
    }
    let mut authorization = None;
    let mut length = 0usize;
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            match k.trim().to_ascii_lowercase().as_str() {
                "authorization" => authorization = Some(v.trim().to_owned()),
                "content-length" => length = v.trim().parse().map_err(|_| 400u16)?,
                _ => {}
            }
        }
    }
    if length > MAX_BODY {
        return Err(413);
    }
    let mut body = buf[end + 4..].to_vec();
    while body.len() < length {
        match stream.read(&mut chunk) {
            Ok(0) | Err(_) => return Err(400),
            Ok(n) => body.extend_from_slice(&chunk[..n]),
        }
    }
    body.truncate(length);
    Ok(Request {
        method: method.to_owned(),
        path: path.to_owned(),
        authorization,
        body,
    })
}

fn handle(mut stream: TcpStream, cfg: &Config, bus: &Bus) {
    let _ = stream.set_read_timeout(Some(IO_TIMEOUT));
    let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
    let resp = match read_request(&mut stream) {
        Ok(req) => {
            let resp = route(&req, cfg, bus);
            if resp.status == 401 {
                // slows token guessing to a crawl without needing any state
                thread::sleep(Duration::from_millis(750));
            }
            resp
        }
        Err(status) => Response::text(status, "text/plain; charset=utf-8", reason(status), false),
    };
    let _ = write_response(&mut stream, &resp);
}

/// Starts serving on `addr`. Returns the address actually bound (useful with port 0 in tests).
pub fn serve(addr: SocketAddr, cfg: Config, bus: Arc<Bus>) -> io::Result<SocketAddr> {
    let listener = TcpListener::bind(addr)?;
    let bound = listener.local_addr()?;
    let cfg = Arc::new(cfg);
    let active = Arc::new(AtomicUsize::new(0));
    thread::Builder::new()
        .name("lab-phone".into())
        .spawn(move || {
            for stream in listener.incoming().flatten() {
                if active.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
                    active.fetch_sub(1, Ordering::SeqCst);
                    continue;
                }
                let (cfg, bus, active) = (Arc::clone(&cfg), Arc::clone(&bus), Arc::clone(&active));
                thread::spawn(move || {
                    handle(stream, &cfg, &bus);
                    active.fetch_sub(1, Ordering::SeqCst);
                });
            }
        })?;
    Ok(bound)
}

fn config_file(name: &str) -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .map(|d| d.join(name))
}

/// `tailscale` means the machine's tailnet IPv4 address. Anything that listens on every interface is refused.
pub fn parse_bind(
    spec: &str,
    port: u16,
    tailscale_ip: impl Fn() -> Option<String>,
) -> Result<SocketAddr, String> {
    let host = if spec == "tailscale" {
        tailscale_ip().ok_or("tailscale has no address yet")?
    } else {
        spec.to_owned()
    };
    let ip: std::net::IpAddr = host
        .trim()
        .parse()
        .map_err(|_| format!("not an address: {host}"))?;
    if ip.is_unspecified() {
        return Err("refusing to listen on every interface".into());
    }
    Ok(SocketAddr::new(ip, port))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The shared secret lives in a 0600 file next to the config; it is created on first start.
fn load_or_create_token(path: &std::path::Path) -> io::Result<String> {
    if let Ok(t) = std::fs::read_to_string(path) {
        let t = t.trim().to_owned();
        if t.len() >= 24 {
            return Ok(t);
        }
    }
    let mut raw = [0u8; 24];
    std::fs::File::open("/dev/urandom")?.read_exact(&mut raw)?;
    let token = hex(&raw);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        f.write_all(token.as_bytes())?;
    }
    Ok(token)
}

fn tailscale_ipv4() -> Option<String> {
    let bin = std::env::var("TAILSCALE").unwrap_or_else(|_| "tailscale".to_owned());
    let out = Command::new(bin).args(["ip", "-4"]).output().ok()?;
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .map(|l| l.trim().to_owned())
        .filter(|l| !l.is_empty())
}

/// Starts the server when phone.json enables it. Waits for tailscale to come up instead of failing at boot.
pub fn start_from_config(bus: Arc<Bus>) {
    let raw: Value = config_file("lab/phone.json")
        .and_then(|f| std::fs::read_to_string(f).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or(Value::Null);
    if raw["enable"] != true {
        return;
    }
    thread::spawn(move || loop {
        let spec = raw["bind"].as_str().unwrap_or("tailscale");
        let port = raw["port"]
            .as_u64()
            .and_then(|p| u16::try_from(p).ok())
            .unwrap_or(8765);
        let addr = match parse_bind(spec, port, tailscale_ipv4) {
            Ok(a) => a,
            Err(e) if e.contains("tailscale") => {
                thread::sleep(Duration::from_secs(20));
                continue;
            }
            Err(e) => {
                eprintln!("labd: phone app not started: {e}");
                return;
            }
        };
        let token_path = raw["tokenFile"]
            .as_str()
            .map(PathBuf::from)
            .or_else(|| config_file("lab/phone-token"));
        let token = match token_path.as_deref().map(load_or_create_token) {
            Some(Ok(t)) => t,
            _ => {
                eprintln!("labd: phone app not started: cannot read or create the token");
                return;
            }
        };
        let scenes: Vec<(String, String)> = config_file("lab/scenes.json")
            .and_then(|f| std::fs::read_to_string(f).ok())
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .and_then(|v| {
                v.as_object().map(|o| {
                    o.iter()
                        .filter_map(|(k, v)| Some((k.clone(), v["title"].as_str()?.to_owned())))
                        .collect()
                })
            })
            .unwrap_or_default();
        let host = Command::new("hostname").output().map_or_else(
            |_| "this machine".to_owned(),
            |o| String::from_utf8_lossy(&o.stdout).trim().to_owned(),
        );
        let cfg = Config {
            token,
            host,
            scenes,
            colors_file: config_file("waybar/colors.css"),
            tokens_file: config_file("lab/tokens.json"),
        };
        match serve(addr, cfg, Arc::clone(&bus)) {
            Ok(bound) => eprintln!("labd: phone app on http://{bound}"),
            Err(e) => eprintln!("labd: phone app not started: {e}"),
        }
        return;
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn cfg() -> Config {
        Config {
            token: "s3cret-token".into(),
            host: "Laptop".into(),
            scenes: vec![
                ("focus".into(), "Focus".into()),
                ("leave".into(), "Leave".into()),
            ],
            colors_file: None,
            tokens_file: None,
        }
    }

    fn req(method: &str, path: &str, auth: Option<&str>) -> Request {
        Request {
            method: method.into(),
            path: path.into(),
            authorization: auth.map(str::to_owned),
            body: Vec::new(),
        }
    }

    #[test]
    fn token_comparison_is_exact() {
        assert!(tokens_equal("abc", "abc"));
        assert!(!tokens_equal("abc", "abd"));
        assert!(!tokens_equal("abc", "abcd"));
        assert!(!tokens_equal("", "a"));
    }

    #[test]
    fn api_needs_the_token_and_static_files_do_not() {
        let (bus, _rx) = Bus::new();
        let c = cfg();
        assert_eq!(route(&req("GET", "/", None), &c, &bus).status, 200);
        assert_eq!(route(&req("GET", "/app.js", None), &c, &bus).status, 200);
        assert_eq!(route(&req("GET", "/api/state", None), &c, &bus).status, 401);
        assert_eq!(
            route(&req("GET", "/api/state", Some("Bearer wrong")), &c, &bus).status,
            401
        );
        assert_eq!(
            route(&req("POST", "/api/scene/focus", None), &c, &bus).status,
            401
        );
        assert_eq!(
            route(
                &req("GET", "/api/state", Some("Bearer s3cret-token")),
                &c,
                &bus
            )
            .status,
            200
        );
    }

    #[test]
    fn an_empty_configured_token_never_authorizes() {
        let (bus, _rx) = Bus::new();
        let mut c = cfg();
        c.token = String::new();
        assert_eq!(
            route(&req("GET", "/api/state", Some("Bearer ")), &c, &bus).status,
            401
        );
    }

    #[test]
    fn only_known_scenes_run() {
        let (bus, _rx) = Bus::new();
        let c = cfg();
        let auth = Some("Bearer s3cret-token");
        assert_eq!(
            route(&req("POST", "/api/scene/nope", auth), &c, &bus).status,
            404
        );
        assert_eq!(
            route(&req("POST", "/api/scene/../etc", auth), &c, &bus).status,
            404
        );
        assert_eq!(
            route(&req("POST", "/api/scene/focus; reboot", auth), &c, &bus).status,
            404
        );
        assert_eq!(
            route(&req("DELETE", "/api/state", auth), &c, &bus).status,
            404
        );
        assert_eq!(route(&req("PUT", "/", None), &c, &bus).status, 405);
    }

    #[test]
    fn state_carries_roster_scenes_and_activity() {
        let (bus, _rx) = Bus::new();
        bus.publish(crate::bus::make_event(&json!({
            "name": "roster.changed", "source": "roster",
            "payload": {"devices": [{"title": "Desktop", "online": true, "os": "linux", "self": false}]}
        })).unwrap());
        bus.publish(crate::bus::make_event(&json!({"name": "focus.failed", "source": "focus", "payload": {"reason": "the hub is unreachable"}})).unwrap());
        let s = state_json(&cfg(), &bus);
        assert_eq!(s["host"], "Laptop");
        assert_eq!(s["devices"][0]["title"], "Desktop");
        assert_eq!(s["scenes"].as_array().unwrap().len(), 2);
        assert_eq!(
            s["activity"][0]["text"],
            "Focus unavailable, the hub is unreachable"
        );
    }

    #[test]
    fn parser_enforces_the_limits() {
        let ok = b"POST /api/scene/focus HTTP/1.1\r\nAuthorization: Bearer x\r\nContent-Length: 2\r\n\r\nhi";
        let r = read_request(&mut Cursor::new(&ok[..])).unwrap();
        assert_eq!(
            (r.method.as_str(), r.path.as_str(), r.body.as_slice()),
            ("POST", "/api/scene/focus", &b"hi"[..])
        );
        assert_eq!(r.authorization.as_deref(), Some("Bearer x"));

        let big = format!(
            "POST / HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
            MAX_BODY + 1
        );
        assert_eq!(
            read_request(&mut Cursor::new(big.into_bytes())).err(),
            Some(413)
        );

        let huge = format!(
            "GET / HTTP/1.1\r\nX-Pad: {}\r\n\r\n",
            "a".repeat(MAX_HEADER + 10)
        );
        assert_eq!(
            read_request(&mut Cursor::new(huge.into_bytes())).err(),
            Some(431)
        );

        assert_eq!(
            read_request(&mut Cursor::new(&b"garbage\r\n\r\n"[..])).err(),
            Some(400)
        );
        assert_eq!(
            read_request(&mut Cursor::new(&b"GET / HTTP/1.1\r\n"[..])).err(),
            Some(400)
        );
    }

    #[test]
    fn bind_address_is_never_a_wildcard() {
        let ts = || Some("100.69.154.81".to_owned());
        assert_eq!(
            parse_bind("tailscale", 8765, ts).unwrap().to_string(),
            "100.69.154.81:8765"
        );
        assert!(parse_bind("tailscale", 8765, || None)
            .unwrap_err()
            .contains("tailscale"));
        assert!(parse_bind("0.0.0.0", 8765, ts).is_err());
        assert!(parse_bind("::", 8765, ts).is_err());
        assert!(parse_bind("not-an-ip", 8765, ts).is_err());
        assert_eq!(parse_bind("127.0.0.1", 9, ts).unwrap().port(), 9);
    }

    #[test]
    fn token_is_created_once_with_private_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let path = std::env::temp_dir().join(format!("labd-token-{}", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let first = load_or_create_token(&path).unwrap();
        assert_eq!(first.len(), 48);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            load_or_create_token(&path).unwrap(),
            first,
            "an existing token is kept"
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn theme_only_accepts_plain_hex_colours() {
        let dir = std::env::temp_dir().join(format!("labd-theme-{}", std::process::id()));
        std::fs::write(&dir, "@define-color primary #ffb3b5;\n@define-color background url(evil);\n@define-color tertiary #e6c18d;\n").unwrap();
        let mut c = cfg();
        c.colors_file = Some(dir.clone());
        let css = theme_css(&c);
        assert!(css.contains("--accent: #ffb3b5"));
        assert!(
            css.contains("--bg: #101010"),
            "a non-hex value must fall back: {css}"
        );
        assert!(!css.contains("evil"));
        let _ = std::fs::remove_file(dir);
    }

    #[test]
    fn real_socket_round_trip_and_wrong_token_is_slow_and_refused() {
        let (bus, _rx) = Bus::new();
        let addr = serve("127.0.0.1:0".parse().unwrap(), cfg(), bus).unwrap();
        let get = |path: &str, auth: &str| {
            let mut s = TcpStream::connect(addr).unwrap();
            let a = if auth.is_empty() {
                String::new()
            } else {
                format!("Authorization: Bearer {auth}\r\n")
            };
            write!(s, "GET {path} HTTP/1.1\r\nHost: x\r\n{a}\r\n").unwrap();
            let mut out = String::new();
            s.read_to_string(&mut out).unwrap();
            out
        };
        let ok = get("/api/state", "s3cret-token");
        assert!(ok.starts_with("HTTP/1.1 200"), "{ok}");
        assert!(ok.contains("X-Frame-Options: DENY") && ok.contains("Content-Security-Policy"));
        assert!(ok.contains("\"host\":\"Laptop\""));
        let started = std::time::Instant::now();
        let bad = get("/api/state", "nope");
        assert!(bad.starts_with("HTTP/1.1 401"), "{bad}");
        assert!(started.elapsed() >= Duration::from_millis(700));
        assert!(get("/", "").contains("<title>Kowal Lab</title>"));
    }
}
