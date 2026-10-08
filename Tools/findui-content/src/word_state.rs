//! Preparation coverage is independent of FTS hits. Only metadata is checked;
//! checking status never opens source contents or runs a document converter.
use crate::{content_index, Plan};
use rayon::prelude::*;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Default, Serialize, Deserialize)]
pub struct Coverage {
    pub roots: Vec<PathBuf>,
    pub directories: BTreeMap<PathBuf, String>,
    pub complete: bool,
}
fn unfiltered(scope: &Value) -> bool {
    scope["unfiltered"] == true
        || scope["files"] == json!({"all":[]})
        || scope["files"] == json!({"all":{"_0":[]}})
}
pub fn schema(db: &Connection) -> rusqlite::Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS word_generation(id INTEGER PRIMARY KEY CHECK(id=1),value INTEGER NOT NULL);
INSERT OR IGNORE INTO word_generation VALUES(1,0);
CREATE TABLE IF NOT EXISTS word_runs(key TEXT PRIMARY KEY,roots TEXT,configuration TEXT,scope TEXT,coverage TEXT,updated INTEGER,complete INTEGER);
CREATE TABLE IF NOT EXISTS word_members(run TEXT,path TEXT,PRIMARY KEY(run,path)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS word_member_paths ON word_members(path);
CREATE TABLE IF NOT EXISTS word_aliases(path TEXT PRIMARY KEY,display TEXT NOT NULL);
CREATE TRIGGER IF NOT EXISTS word_source_generation AFTER INSERT ON sources BEGIN UPDATE word_generation SET value=value+1; END;
CREATE TRIGGER IF NOT EXISTS word_source_deleted AFTER DELETE ON sources BEGIN UPDATE word_generation SET value=value+1; DELETE FROM word_members WHERE path=old.path; END;")
}
pub fn canonical_roots(roots: &[PathBuf]) -> Vec<PathBuf> {
    roots
        .iter()
        .map(|r| fs::canonicalize(r).unwrap_or_else(|_| r.clone()))
        .collect()
}
pub struct RootMap(Vec<(PathBuf, PathBuf)>);
impl RootMap {
    pub fn new(roots: &[PathBuf]) -> Self {
        Self(roots.iter().cloned().zip(canonical_roots(roots)).collect())
    }
    pub fn canonical(&self) -> impl Iterator<Item = &PathBuf> {
        self.0.iter().map(|(_, p)| p)
    }
    pub fn stored(&self, path: &Path) -> io::Result<PathBuf> {
        for (selected, canonical) in &self.0 {
            if let Ok(relative) = path.strip_prefix(selected) {
                return Ok(canonical.join(relative));
            }
        }
        fs::canonicalize(path)
    }
    pub fn selected(&self, path: &Path) -> PathBuf {
        for (selected, canonical) in &self.0 {
            if let Ok(relative) = path.strip_prefix(canonical) {
                return selected.join(relative);
            }
        }
        path.to_owned()
    }
}
pub fn generation(db: &Connection) -> i64 {
    db.query_row("SELECT value FROM word_generation WHERE id=1", [], |r| {
        r.get(0)
    })
    .unwrap_or(-1)
}
pub fn save(
    db: &mut Connection,
    plan: &Plan,
    config: &str,
    paths: &[(String, String)],
    success: bool,
    coverage: Option<Coverage>,
) -> Result<u64, Box<dyn std::error::Error>> {
    let coverage = coverage
        .or_else(|| {
            std::env::var_os("FINDUI_WORD_COVERAGE")
                .and_then(|p| fs::read(p).ok())
                .and_then(|b| serde_json::from_slice::<Coverage>(&b).ok())
        })
        .unwrap_or_default();
    let roots = canonical_roots(&plan.word_roots);
    let scope = serde_json::to_string(&plan.word_scope)?;
    let roots_json = serde_json::to_string(&roots)?;
    let key = content_index::hash(format!("{roots_json}:{config}:{scope}").as_bytes());
    let complete = success
        && coverage.complete
        && canonical_roots(&coverage.roots) == roots
        && !roots.is_empty();
    let tx = db.transaction()?;
    let mut removed = 0;
    if complete {
        // Never treat an absent/offline root or a permission failure as deletion.
        // A path is prunable only if its closest existing parent was visited.
        let full_scope = plan.word_scope.as_ref().is_some_and(unfiltered);
        let existing: Vec<String> = if full_scope {
            tx.prepare("SELECT path FROM sources")?
                .query_map([], |r| r.get(0))?
                .collect::<Result<_, _>>()?
        } else {
            tx.prepare("SELECT path FROM word_members WHERE run=?")?
                .query_map([&key], |r| r.get(0))?
                .collect::<Result<_, _>>()?
        };
        for path in existing {
            let p = Path::new(&path);
            if !roots.iter().any(|r| p.starts_with(r)) {
                continue;
            }
            if fs::symlink_metadata(p).is_err_and(|e| e.kind() == io::ErrorKind::NotFound) {
                let mut parent = p.parent();
                while let Some(p) = parent {
                    if coverage.directories.contains_key(p) {
                        tx.execute("DELETE FROM documents WHERE path=?", [&path])?;
                        removed += tx.execute("DELETE FROM sources WHERE path=?", [&path])? as u64;
                        break;
                    }
                    if !fs::symlink_metadata(p).is_err_and(|e| e.kind() == io::ErrorKind::NotFound)
                    {
                        break;
                    }
                    parent = p.parent();
                }
            }
        }
    }
    tx.execute(
        "INSERT OR REPLACE INTO word_runs VALUES(?,?,?,?,?,unixepoch(),?)",
        params![
            key,
            roots_json,
            config,
            scope,
            serde_json::to_string(&coverage)?,
            complete
        ],
    )?;
    tx.execute_batch("CREATE TEMP TABLE IF NOT EXISTS prepared_paths(path TEXT PRIMARY KEY) WITHOUT ROWID; DELETE FROM prepared_paths;")?;
    {
        let mut visited = tx.prepare("INSERT INTO prepared_paths VALUES(?)")?;
        let mut aliases=tx.prepare("INSERT INTO word_aliases VALUES(?,?) ON CONFLICT(path) DO UPDATE SET display=excluded.display WHERE word_aliases.display<>excluded.display")?;
        for (path, display) in paths {
            visited.execute([path])?;
            aliases.execute(params![path, display])?;
        }
    }
    tx.execute(
        "DELETE FROM word_members WHERE run=? AND path NOT IN (SELECT path FROM prepared_paths)",
        [&key],
    )?;
    tx.execute(
        "INSERT OR IGNORE INTO word_members SELECT ?,path FROM prepared_paths",
        [&key],
    )?;
    tx.commit()?;
    Ok(removed)
}
pub fn status(
    db: &Connection,
    plan: &Plan,
    config: &str,
) -> Result<Value, Box<dyn std::error::Error>> {
    let started = std::time::Instant::now();
    let checkpoint = crate::word_journal::Checkpoint::new(plan, config, generation(db));
    if let Some(report) = checkpoint.as_ref().and_then(|c| c.reuse(plan)) {
        return Ok(report);
    }
    let roots = canonical_roots(&plan.word_roots);
    let mut unavailable = roots.iter().filter(|p| !p.is_dir()).count();
    let mut runs = match db.prepare("SELECT roots,configuration,scope,coverage,updated,complete,key FROM word_runs ORDER BY updated DESC,rowid DESC") {
        Ok(s) => s, Err(_) => return Ok(json!({"state":"notPrepared","message":"Update the word index to record coverage.","generation":generation(db)})),
    };
    let mut rows = runs.query([])?;
    let requested = plan.word_scope.as_ref().unwrap_or(&Value::Null);
    let mut covered = false;
    let mut updated = 0;
    let mut directories = BTreeMap::new();
    let mut matching_runs: Vec<(String, bool)> = Vec::new();
    while let Some(row) = rows.next()? {
        let prepared: Vec<PathBuf> = serde_json::from_str(&row.get::<_, String>(0)?)?;
        let same_config = row.get::<_, String>(1)? == config;
        let saved_scope: Value = serde_json::from_str(&row.get::<_, String>(2)?)?;
        let same_scope = saved_scope == *requested
            || (unfiltered(&saved_scope)
                && saved_scope["traversal"] == requested["traversal"]
                && saved_scope["hidden"] == requested["hidden"]
                && saved_scope["resultScope"] == requested["resultScope"]);
        if same_config
            && (roots.is_empty()
                || roots
                    .iter()
                    .all(|r| prepared.iter().any(|p| r.starts_with(p))))
        {
            updated = updated.max(row.get::<_, i64>(4)?);
            covered |= row.get::<_, bool>(5)? && same_scope;
            if same_scope {
                matching_runs.push((row.get(6)?, saved_scope == *requested));
            }
            let coverage: Coverage = serde_json::from_str(&row.get::<_, String>(3)?)?;
            for (p, identity) in coverage.directories {
                if roots.is_empty() || roots.iter().any(|r| p.starts_with(r)) {
                    directories.entry(p).or_insert(identity);
                }
            }
        }
    }
    let mut changed_directories = 0;
    for (path, saved) in directories {
        match content_index::identity(&path, "word-directory-v1") {
            Ok(current) if current == saved => {}
            Ok(_) => changed_directories += 1,
            Err(_) => {
                changed_directories += 1;
                unavailable += usize::from(!path.exists());
            }
        }
    }
    if matching_runs.iter().any(|(_, exact)| *exact) {
        matching_runs.retain(|(_, exact)| *exact);
    }
    // Restrict both run membership and canonical roots in SQLite. A small
    // subfolder must not first allocate every source in the prepared parent.
    // Keep the existing path filter for unusually large root lists, which can
    // exceed SQLite expression limits, and unavailable/non-directory roots.
    let filter_roots_in_sql = !roots.is_empty() && roots.len() <= 128 && unavailable == 0;
    let root_filter = if !filter_roots_in_sql { String::new() } else {
        format!("({})", roots.iter().map(|_| "(path>=? AND path<?)").collect::<Vec<_>>().join(" OR "))
    };
    let mut parameters = Vec::new();
    let filter = if !matching_runs.is_empty() {
        let placeholders = matching_runs
            .iter()
            .map(|_| "?")
            .collect::<Vec<_>>()
            .join(",");
        parameters.extend(matching_runs.iter().map(|r| r.0.clone()));
        // The (run,path) primary key can narrow membership before collecting
        // it. An outer path filter alone still materializes the entire run.
        let within = if root_filter.is_empty() { String::new() } else { format!(" AND {root_filter}") };
        format!(" WHERE path IN (SELECT path FROM word_members WHERE run IN ({placeholders}){within})")
    } else if root_filter.is_empty() { String::new() } else { format!(" WHERE {root_filter}") };
    if filter_roots_in_sql {
        for root in &roots {
            let prefix = root.to_str().ok_or("Word indexes require UTF-8 roots")?.trim_end_matches('/');
            parameters.extend([format!("{prefix}/"), format!("{prefix}0")]);
        }
    }
    let selected: Vec<(String, String, bool)> = db
        .prepare(&format!("SELECT path,identity,complete FROM sources{filter}"))?
        .query_map(rusqlite::params_from_iter(parameters), |r| Ok((r.get::<_, String>(0)?, r.get(1)?, r.get(2)?)))?
        .filter(|row| match row {
            Ok((path, _, _)) => filter_roots_in_sql || roots.is_empty()
                || roots.iter().any(|root| Path::new(path).starts_with(root)),
            Err(_) => true,
        })
        .collect::<Result<_, _>>()?;
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(if plan.threads == 0 {
            4
        } else {
            plan.threads.clamp(1, 64)
        })
        .build()?;
    let journal_safe = std::sync::atomic::AtomicBool::new(true);
    let changed = pool.install(|| {
        selected
            .par_iter()
            .filter(|(p, saved, complete)| {
                use std::os::unix::fs::MetadataExt;
                match fs::metadata(p) {
                    Ok(m) => {
                        if m.nlink() > 1 {
                            journal_safe.store(false, std::sync::atomic::Ordering::Relaxed);
                        }
                        !complete
                            || content_index::identity_at_path(Path::new(p), &m, config) != *saved
                    }
                    Err(_) => {
                        journal_safe.store(false, std::sync::atomic::Ordering::Relaxed);
                        true
                    }
                }
            })
            .count()
    });
    let state = if unavailable > 0 {
        "unavailable"
    } else if changed > 0 || changed_directories > 0 {
        "needsUpdate"
    } else if !covered {
        "partial"
    } else {
        "updated"
    };
    let message = match state {
        "updated" => "Prepared words are up to date.",
        "unavailable" => {
            "Some prepared folders are unavailable. Their index entries have been retained."
        }
        "needsUpdate" => {
            "Files or folders changed. Update the word index to include current words."
        }
        _ => "This scope is not fully prepared. Update the word index for complete results.",
    };
    let report = json!({"verification":"metadata","verificationMilliseconds":started.elapsed().as_secs_f64()*1000.0,"state":state,"message":message,"updated":updated,"sources":selected.len(),"changedSources":changed,"changedDirectories":changed_directories,"generation":generation(db)});
    if journal_safe.load(std::sync::atomic::Ordering::Relaxed) {
        if let Some(checkpoint) = checkpoint {
            checkpoint.save(&report);
        }
    }
    Ok(report)
}
