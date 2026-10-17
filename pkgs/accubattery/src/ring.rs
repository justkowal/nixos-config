//! Rolling CSV of raw samples. Costs a few MB and lets a wrong detection be replayed offline.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;

use crate::engine::Sample;

/// 48 h at one sample per 10 s
const KEEP: usize = 17_280;
const TRIM_EVERY: u32 = 360;

pub struct Ring {
    path: PathBuf,
    since_trim: u32,
}

impl Ring {
    pub fn new(dir: &std::path::Path, battery: &str) -> Self {
        Self { path: dir.join(format!("ring-{battery}.csv")), since_trim: 0 }
    }

    pub fn push(&mut self, s: &Sample) {
        let fresh = !self.path.exists();
        let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&self.path) else { return };
        if fresh {
            let _ = writeln!(f, "{}", Sample::CSV_HEADER);
        }
        let _ = writeln!(f, "{}", s.to_csv());
        self.since_trim += 1;
        if self.since_trim >= TRIM_EVERY {
            self.since_trim = 0;
            self.trim();
        }
    }

    fn trim(&self) {
        let Ok(text) = fs::read_to_string(&self.path) else { return };
        let lines: Vec<&str> = text.lines().skip(1).collect();
        if lines.len() <= KEEP + TRIM_EVERY as usize {
            return;
        }
        let mut out = String::from(Sample::CSV_HEADER);
        for l in &lines[lines.len() - KEEP..] {
            out.push('\n');
            out.push_str(l);
        }
        out.push('\n');
        let tmp = self.path.with_extension("tmp");
        if fs::write(&tmp, out).is_ok() {
            let _ = fs::rename(tmp, &self.path);
        }
    }
}

pub fn load(path: &std::path::Path) -> Vec<Sample> {
    fs::read_to_string(path).map(|t| t.lines().filter_map(Sample::from_csv).collect()).unwrap_or_default()
}
