//! Read normal table values only. Never execute views, virtual tables, generated
//! expressions, user SQL or extension loaders from a searched database.
use crate::documents::{Bundle, Document, Member};
use rusqlite::{types::ValueRef, Connection, OpenFlags};
use std::{
    io,
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};
fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}
pub fn read(
    path: &Path,
    members: &[Member],
    limit: u64,
    deadline: Instant,
    stopped: &AtomicBool,
) -> io::Result<Bundle> {
    read_inner(path, members, limit, deadline, stopped)
        .map_err(|error| io::Error::other(error.to_string()))
}
fn read_inner(
    path: &Path,
    members: &[Member],
    limit: u64,
    deadline: Instant,
    stopped: &AtomicBool,
) -> Result<Bundle, Box<dyn std::error::Error>> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.busy_timeout(std::time::Duration::from_millis(250))?;
    connection.execute_batch("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; BEGIN;")?;
    connection.progress_handler(1000, Some(move || Instant::now() > deadline))?;
    let mut schema=connection.prepare("SELECT name,sql FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")?;
    let tables = schema
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut out = Bundle::default();
    let mut bytes = 0;
    let mut row_count = 0;
    for (table, sql) in tables {
        if sql.to_ascii_uppercase().contains("CREATE VIRTUAL TABLE") {
            continue;
        }
        let mut info = connection.prepare(&format!("PRAGMA table_xinfo({})", quote(&table)))?;
        let columns = info
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter(|c| c.2 == 0)
            .collect::<Vec<_>>();
        if columns.is_empty() {
            continue;
        }
        let fields = columns
            .iter()
            .map(|c| quote(&c.0))
            .collect::<Vec<_>>()
            .join(",");
        let rowid = ["_rowid_", "rowid", "oid"]
            .into_iter()
            .find(|name| !columns.iter().any(|c| c.0.eq_ignore_ascii_case(name)));
        let rowid = rowid.filter(|name| {
            connection
                .prepare(&format!("SELECT {name} FROM {} LIMIT 0", quote(&table)))
                .is_ok()
        });
        let select = if let Some(rowid) = rowid {
            format!(
                "SELECT {rowid},{fields} FROM {} ORDER BY {rowid}",
                quote(&table)
            )
        } else {
            format!("SELECT {fields} FROM {}", quote(&table))
        };
        let mut query = connection.prepare(&select)?;
        let mut rows = query.query([])?;
        let mut ordinal = 0;
        while let Some(row) = rows.next()? {
            if stopped.load(Ordering::Relaxed) || Instant::now() > deadline {
                return Err("Database search cancelled or timed out".into());
            }
            row_count += 1;
            ordinal += 1;
            if row_count > 100_000 {
                return Err(
                    "Database exceeds 100,000 rows; narrow the scope or use its database tools"
                        .into(),
                );
            }
            let label = if rowid.is_some() {
                row.get::<_, i64>(0)?.to_string()
            } else {
                format!("{ordinal}")
            };
            let mut text = String::new();
            let mut keys = Vec::new();
            for (index, (name, primary, _)) in columns.iter().enumerate() {
                let value = match row.get_ref(index + usize::from(rowid.is_some()))? {
                    ValueRef::Null => continue,
                    ValueRef::Blob(_) => continue,
                    ValueRef::Text(bytes) => String::from_utf8_lossy(bytes).into_owned(),
                    ValueRef::Integer(n) => n.to_string(),
                    ValueRef::Real(n) => n.to_string(),
                };
                if *primary > 0 {
                    keys.push(format!("{name}={value}"));
                }
                bytes += name.len() as u64 + value.len() as u64 + 3;
                if bytes > limit {
                    return Err("Database text exceeds the configured size limit".into());
                }
                text.push_str(name);
                text.push_str(": ");
                text.push_str(&value);
                text.push('\n');
            }
            if text.is_empty() {
                continue;
            }
            let key = if rowid.is_some() || keys.is_empty() {
                label.clone()
            } else {
                keys.join(", ")
            };
            let metadata = [
                ("finduiRequiresDocuments".into(), "true".into()),
                ("table".into(), table.clone()),
                ("row".into(), key.clone()),
                (
                    "finduiRecord".into(),
                    serde_json::to_string(&(&table, &key))?,
                ),
            ]
            .into();
            out.documents.push(Document {
                members: members.to_vec(),
                text,
                metadata,
                ..Default::default()
            });
        }
    }
    Ok(out)
}
