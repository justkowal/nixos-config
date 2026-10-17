use crate::db::Db;
use rusqlite::Result;

const COLS: &[&str] = &[
    "id", "battery", "session_type", "kind", "start_time", "end_time", "duration_min", "start_pct", "end_pct",
    "gain_pct", "wear_cycles", "energy_wh", "energy_mah", "avg_power_w", "max_power_w", "avg_temp_c", "max_temp_c",
    "pd_standard", "wake_json",
];

fn rows(db: &Db) -> Result<Vec<Vec<serde_json::Value>>> {
    let mut st = db.0.prepare(&format!("SELECT {} FROM cycles WHERE duration_min>0.3 ORDER BY start_time", COLS.join(",")))?;
    let out = st
        .query_map([], |r| {
            (0..COLS.len())
                .map(|i| {
                    Ok(match r.get_ref(i)? {
                        rusqlite::types::ValueRef::Null => serde_json::Value::Null,
                        rusqlite::types::ValueRef::Integer(v) => v.into(),
                        rusqlite::types::ValueRef::Real(v) => v.into(),
                        rusqlite::types::ValueRef::Text(t) => String::from_utf8_lossy(t).into_owned().into(),
                        rusqlite::types::ValueRef::Blob(_) => serde_json::Value::Null,
                    })
                })
                .collect::<Result<Vec<_>>>()
        })?
        .collect::<Result<Vec<_>>>()?;
    Ok(out)
}

fn csv_cell(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::Null => String::new(),
        serde_json::Value::String(s) if s.contains([',', '"', '\n']) => format!("\"{}\"", s.replace('"', "\"\"")),
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

pub fn csv(db: &Db) -> Result<String> {
    let mut out = COLS.join(",");
    out.push('\n');
    for r in rows(db)? {
        out.push_str(&r.iter().map(csv_cell).collect::<Vec<_>>().join(","));
        out.push('\n');
    }
    Ok(out)
}

pub fn json(db: &Db) -> Result<String> {
    let list: Vec<serde_json::Value> = rows(db)?
        .into_iter()
        .map(|r| serde_json::Value::Object(COLS.iter().map(|c| c.to_string()).zip(r).collect()))
        .collect();
    Ok(serde_json::to_string_pretty(&list).unwrap_or_default())
}
