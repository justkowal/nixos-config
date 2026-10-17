//! lab-publish: fast event publisher for hot paths (volume keys, scripts).
//! A compiled client because Python startup per keypress is slower than the keypress repeat.
//! usage: lab-publish NAME [--source S] [--payload JSON] [--priority P] [--ttl SECS] [--strict]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;
use std::time::Duration;

use labd::bus::{make_event, sock_path};
use serde_json::{json, Value};

fn main() -> ExitCode {
    let mut args = std::env::args().skip(1);
    let Some(name) = args.next() else {
        eprintln!("usage: lab-publish NAME [--source S] [--payload JSON] [--priority P] [--ttl SECS] [--strict]");
        return ExitCode::from(2);
    };
    let mut raw = json!({"name": name, "source": "cli"});
    let mut strict = false;
    while let Some(flag) = args.next() {
        let mut value = |what: &str| args.next().ok_or(format!("{what} needs a value"));
        let res = match flag.as_str() {
            "--strict" => {
                strict = true;
                Ok(())
            }
            "--source" => value("--source").map(|v| raw["source"] = json!(v)),
            "--priority" => value("--priority").map(|v| raw["priority"] = json!(v)),
            "--payload" => value("--payload")
                .and_then(|v| {
                    serde_json::from_str::<Value>(&v)
                        .map_err(|e| format!("payload is not JSON: {e}"))
                })
                .map(|v| raw["payload"] = v),
            "--ttl" => value("--ttl")
                .and_then(|v| v.parse::<f64>().map_err(|e| format!("ttl: {e}")))
                .map(|v| raw["ttl"] = json!(v)),
            other => Err(format!("unknown option {other}")),
        };
        if let Err(e) = res {
            eprintln!("lab: {e}");
            return ExitCode::from(2);
        }
    }
    if let Err(e) = make_event(&raw) {
        eprintln!("lab: {e}");
        return ExitCode::from(2);
    }

    let send = || -> std::io::Result<Value> {
        let stream = UnixStream::connect(sock_path())?;
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        let mut out = stream.try_clone()?;
        writeln!(out, "{}", json!({"op": "publish", "event": raw}))?;
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line)?;
        serde_json::from_str(&line).map_err(std::io::Error::other)
    };
    match send() {
        Ok(reply) if reply["ok"] == true => ExitCode::SUCCESS,
        Ok(reply) => {
            eprintln!("lab: {}", reply["error"]);
            ExitCode::from(2)
        }
        Err(e) => {
            eprintln!("lab: bus unreachable ({e})");
            // publishers run inside other tools, a down shell must not break them
            if strict {
                ExitCode::FAILURE
            } else {
                ExitCode::SUCCESS
            }
        }
    }
}
