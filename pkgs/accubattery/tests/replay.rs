//! Replays recorded sample files through the engine. Add a file from ring-BAT0.csv here whenever
//! detection gets something wrong, then fix the engine until the expectation holds.

use accubattery::engine::{describe, Engine, Event};
use accubattery::ring;

fn run(name: &str) -> Vec<String> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name);
    let mut e = Engine::default();
    e.ref_charge_w = 30.0;
    ring::load(&path)
        .into_iter()
        .flat_map(|s| e.step(s))
        .filter(|ev| !matches!(ev, Event::Telemetry(_)))
        .map(|ev| describe(&ev))
        .collect()
}

#[test]
fn charging_during_suspend_is_found_and_split() {
    let ev = run("suspend_charge.csv");
    assert_eq!(ev[0], "open discharge at 60% t=1000000");
    assert!(ev[1].starts_with("close discharge"), "{ev:?}");
    assert_eq!(ev[2], "offline charge Suspend 60%->85%");
    assert!(ev[3].starts_with("open charge"), "{ev:?}");
}

#[test]
fn charging_while_powered_off_is_found() {
    let ev = run("poweroff_charge.csv");
    assert!(ev.iter().any(|e| e == "offline charge PowerOff 20%->97%"), "{ev:?}");
    // full and plugged in afterwards is a hold, not a session
    assert!(!ev.iter().any(|e| e.starts_with("open") && e.contains("97%")), "{ev:?}");
}

#[test]
fn charge_limit_hold_ends_the_charge_and_does_not_open_one() {
    let ev = run("limit_hold.csv");
    assert_eq!(ev.iter().filter(|e| e.starts_with("open charge")).count(), 1, "{ev:?}");
    assert!(ev.iter().any(|e| e.starts_with("close charge")), "{ev:?}");
    assert!(ev.iter().any(|e| e.starts_with("open discharge")), "{ev:?}");
}
