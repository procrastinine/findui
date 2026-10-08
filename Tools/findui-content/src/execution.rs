//! Versioned physical-plan adapter. The CLI and app use this same executor;
//! compositions never reconstruct UI requests or inspect shell command text.
use crate::{
    Output, Plan, Tree,
    input::{Input, Source},
    paths, walk,
};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::HashMap,
    fs,
    io::{self, BufRead, Seek, Write},
    os::unix::ffi::OsStrExt,
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering::Relaxed},
    },
    time::Duration,
};

#[derive(Debug)]
pub(crate) struct Incomplete(pub u64);
impl std::fmt::Display for Incomplete {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} files or folders could not be searched (see diagnostics above)",
            self.0
        )
    }
}
impl std::error::Error for Incomplete {}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    version: u32,
    source: SourceSpec,
    traversal: Option<walk::Configuration>,
    paths: Option<paths::Configuration>,
    selection: Option<Selection>,
    content: Option<Plan>,
    spotlight: Option<Spotlight>,
    action: String,
    unit: String,
    output: String,
    budget: Budget,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceSpec {
    kind: String,
    path: Option<PathBuf>,
    generation: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Budget {
    workers: usize,
    conversion_workers: usize,
    memory_bytes: usize,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Spotlight {
    executable: String,
    roots: Vec<PathBuf>,
    predicate: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    predicates: paths::Configuration,
    fuzzies: Vec<External>,
    #[serde(default)]
    masks: bool,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct External {
    leaf: usize,
    invocation: Invocation,
    relative_roots: Option<Vec<PathBuf>>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Invocation {
    executable: String,
    arguments: Vec<String>,
    environment: HashMap<String, String>,
    unset_environment: Vec<String>,
    empty_exit_codes: Vec<i32>,
}
impl Invocation {
    fn run(
        &self,
        input: Option<&fs::File>,
        output: &fs::File,
        stopped: &AtomicBool,
    ) -> io::Result<()> {
        let mut command = Command::new(&self.executable);
        command
            .args(&self.arguments)
            .envs(&self.environment)
            .stdin(match input {
                Some(f) => Stdio::from(f.try_clone()?),
                None => Stdio::null(),
            })
            .stdout(output.try_clone()?);
        for key in &self.unset_environment {
            command.env_remove(key);
        }
        let mut child = command.spawn()?;
        loop {
            if let Some(status) = child.try_wait()? {
                return if status.success()
                    || status
                        .code()
                        .is_some_and(|c| self.empty_exit_codes.contains(&c))
                {
                    Ok(())
                } else {
                    Err(io::Error::other(format!(
                        "{} exited with {status}",
                        self.executable
                    )))
                };
            }
            if stopped.load(Relaxed) {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Search cancelled",
                ));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}
pub fn run(json: &str) -> Result<(), Box<dyn std::error::Error>> {
    let stopped = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, stopped.clone())?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, stopped.clone())?;
    let mut result = execute(serde_json::from_str(json), stopped.clone());
    if stopped.load(Relaxed) && result.is_ok() {
        result = Err(io::Error::new(io::ErrorKind::Interrupted, "Search cancelled").into());
    }
    let skipped = result
        .as_ref()
        .err()
        .and_then(|e| e.downcast_ref::<Incomplete>())
        .map_or(0, |e| e.0);
    let status = if stopped.load(Relaxed) {
        "cancelled"
    } else if skipped > 0 {
        "partial"
    } else if result.is_err() {
        "failed"
    } else {
        "complete"
    };
    eprintln!(
        "findui-completion: {}",
        json!({"version":1,"status":status,"skipped":skipped,"message":result.as_ref().err().map(|e|e.to_string())})
    );
    result
}
fn execute(
    decoded: Result<Request, serde_json::Error>,
    stopped: Arc<AtomicBool>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut request = decoded?;
    if request.version != 1
        || request.budget.workers > 64
        || !(1..=4).contains(&request.budget.conversion_workers)
        || !(1024 * 1024..=256 * 1024 * 1024).contains(&request.budget.memory_bytes)
        || !["line", "document", "file"].contains(&request.unit.as_str())
        || !["paths", "metadata", "matches", "wordCandidates"].contains(&request.output.as_str())
    {
        return Err("Unsupported or invalid execution plan".into());
    }
    let threads = crate::input::workers(request.budget.workers);
    if let Some(content) = &mut request.content {
        content.tree.validate(content.leaves.len(), 0, &mut 0)?;
        let file_count = content
            .file_predicates
            .as_ref()
            .and_then(|p| p.leaves.as_ref())
            .map_or(0, Vec::len);
        if content
            .leaves
            .iter()
            .any(|l| l.file_index.is_some_and(|i| i >= file_count))
        {
            return Err("Invalid file condition index".into());
        }
        content.threads = threads;
        if content.files_only != (request.output == "paths")
            || content.file_unit != (request.unit != "line")
            || content.document_unit != (request.unit == "document")
        {
            return Err("Content result unit disagrees with execution plan".into());
        }
    }
    let mut input = Input::default();
    input.follow = request
        .traversal
        .as_ref()
        .map(|c| c.follow)
        .unwrap_or_else(|| {
            request
                .paths
                .as_ref()
                .or(request.selection.as_ref().map(|s| &s.predicates))
                .is_some_and(|c| c.follow)
        });
    input.source = match request.source.kind.as_str() {
        "live" => Source::Live(
            request
                .traversal
                .clone()
                .ok_or("Live source needs traversal settings")?,
        ),
        "stdin" => Source::Stdin,
        "manifest" => {
            input.admission = request.traversal.clone();
            Source::Paths(request.source.path.clone().ok_or("Manifest needs a path")?)
        }
        "records" => Source::Records(request.source.path.clone().ok_or("Records need a path")?),
        "snapshot" => Source::Snapshot(request.source.path.clone().ok_or("Snapshot needs a path")?),
        _ => return Err("Unknown candidate source".into()),
    };
    // The app supplies an immutable generation lease, not a mutable index name.
    if request
        .source
        .generation
        .as_ref()
        .is_some_and(|g| g.is_empty())
    {
        return Err("Invalid snapshot generation".into());
    }
    let spotlight_file = if let Some(spotlight) = &request.spotlight {
        let file = tempfile::NamedTempFile::new()?;
        for root in &spotlight.roots {
            Invocation {
                executable: spotlight.executable.clone(),
                arguments: vec![
                    "-0".into(),
                    "-onlyin".into(),
                    root.to_string_lossy().into_owned(),
                    spotlight.predicate.clone(),
                ],
                environment: HashMap::new(),
                unset_environment: vec![],
                empty_exit_codes: vec![],
            }
            .run(None, file.as_file(), &stopped)?;
        }
        input.source = Source::Paths(file.path().into());
        Some(file)
    } else {
        None
    };
    let configuration = request
        .paths
        .take()
        .or_else(|| request.selection.as_ref().map(|s| s.predicates.clone()));
    let preserve_masks = request.selection.as_ref().is_some_and(|s| s.masks);
    let mut external = request.selection.take().map_or(Vec::new(), |s| s.fuzzies);
    if let Some(config) = &configuration {
        for (leaf, condition) in config
            .leaves
            .as_deref()
            .unwrap_or(std::slice::from_ref(config))
            .iter()
            .enumerate()
        {
            if let Some(date) = &condition.metadata_date {
                let spotlight = request
                    .spotlight
                    .as_ref()
                    .ok_or("Metadata dates require Spotlight")?;
                if ![
                    "kMDItemContentCreationDate",
                    "kMDItemContentModificationDate",
                    "kMDItemDateAdded",
                    "kMDItemLastUsedDate",
                ]
                .contains(&date.field.as_str())
                {
                    return Err("Unknown Spotlight date field".into());
                }
                let mut clauses = vec![format!("{} == '*'", date.field)];
                if let Some(from) = date.from {
                    clauses.push(format!("{} >= {}", date.field, from - 978307200.0));
                }
                if let Some(before) = date.before {
                    clauses.push(format!("{} < {}", date.field, before - 978307200.0));
                }
                let invocation = Invocation {
                    executable: spotlight.executable.clone(),
                    arguments: vec!["-0".into(), clauses.join(" && ")],
                    environment: HashMap::new(),
                    unset_environment: vec![],
                    empty_exit_codes: vec![],
                };
                external.push(External {
                    leaf,
                    invocation,
                    relative_roots: None,
                });
            }
        }
    }
    input.predicate = configuration
        .clone()
        .map(paths::Predicate::new)
        .transpose()?;
    // Mixed indexed queries use the same file masks as live scanning. Evaluate
    // each path once, then join its constants into FTS's Boolean expression.
    // A file-only winning branch needs neither an index nor a body read.
    if request.action == "wordSearch"
        && request
            .content
            .as_ref()
            .is_some_and(|c| c.file_predicates.is_some())
    {
        let mut content = request.content.take().unwrap();
        let config = content.file_predicates.as_ref().unwrap();
        let (selected, errors, _) = select(&input, config, &external, threads, &stopped, true)?;
        let mut pending = tempfile::NamedTempFile::new()?;
        let mut output = io::BufWriter::new(io::stdout());
        for bytes in io::BufReader::new(fs::File::open(selected.path())?).split(0) {
            let bytes = bytes?;
            if bytes.is_empty() {
                continue;
            }
            let record: paths::Record = serde_json::from_slice(&bytes)?;
            let mask = record
                .conditions
                .as_ref()
                .ok_or("Missing file condition values")?;
            let possible = content
                .leaves
                .iter()
                .map(|l| l.file_index.map_or((true, true), |i| (!mask[i], mask[i])))
                .collect::<Vec<_>>();
            if content.tree.possibilities(&possible) == (false, true) {
                output.write_all(record.path.as_bytes())?;
                output.write_all(&[0])?;
            } else {
                pending.write_all(&bytes)?;
                pending.write_all(&[0])?;
            }
        }
        if pending.as_file().metadata()?.len() > 0 {
            content.word_file_masks = Some(pending.path().into());
            content.word_fuzzy_order = !external.is_empty();
            crate::fulltext::search_to(content, &mut output, None)?;
        }
        output.flush()?;
        if errors > 0 {
            return Err(Incomplete(errors as u64).into());
        }
        return Ok(());
    }
    let mut temporary = Vec::new();
    let mut selection_errors = 0;
    let word_ids = if request.action == "wordSearch" {
        let mut content = request
            .content
            .clone()
            .ok_or("Word search needs content conditions")?;
        let mut ids = tempfile::NamedTempFile::new()?;
        content.word_candidates = true;
        crate::fulltext::search_to(content, ids.as_file_mut(), None)?;
        // Freshness and query validation already ran. No candidate can survive
        // filename admission or ranking, so avoid temporary selections, tool
        // launches and reopening SQLite merely to render an empty result.
        let mut within = None;
        if request.source.kind == "manifest" {
            let mut members = crate::unique::Unique::new();
            let predicate = input.predicate.as_ref();
            for path in
                io::BufReader::new(fs::File::open(request.source.path.as_ref().unwrap())?).split(0)
            {
                let path = path?;
                if !path.is_empty() {
                    let text = std::str::from_utf8(&path)?;
                    let restored =
                        predicate.map_or_else(|| text.to_owned(), |p| p.restore_root(text));
                    members.insert(restored.as_bytes())?;
                }
            }
            within = Some(members);
        }
        if ids.as_file().metadata()?.len() == 0 {
            return Ok(());
        }
        let mut paths = tempfile::NamedTempFile::new()?;
        for line in io::BufReader::new(fs::File::open(ids.path())?).lines() {
            let row: serde_json::Value = serde_json::from_str(&line?)?;
            let path = row["data"]["path"]["text"]
                .as_str()
                .ok_or("Invalid word candidate path")?;
            if let Some(within) = &within {
                let restored = input
                    .predicate
                    .as_ref()
                    .map_or_else(|| path.to_owned(), |p| p.restore_root(path));
                if !within.contains(restored.as_bytes())? {
                    continue;
                }
            }
            paths.write_all(path.as_bytes())?;
            paths.write_all(&[0])?;
        }
        input.source = Source::Paths(paths.path().into());
        input.admission = request.traversal.clone();
        temporary.push(paths);
        Some(ids)
    } else {
        None
    };
    if !external.is_empty() {
        let (file, errors, records) = select(
            &input,
            configuration.as_ref().ok_or("Selection needs predicates")?,
            &external,
            threads,
            &stopped,
            preserve_masks,
        )?;
        selection_errors += errors;
        input.source = if records {
            Source::Records(file.path().into())
        } else {
            Source::Paths(file.path().into())
        };
        input.predicate = None;
        input.admission = None;
        temporary.push(file);
    }
    match request.action.as_str() {
        "prepareWords" => {
            input.collect_coverage = true;
            crate::fulltext::prepare_with_input(
                request.content.ok_or("Preparation needs content options")?,
                input,
            )?;
        }
        "search" | "prepareSignatures" => {
            if let Some(content) = request.content {
                crate::search::run_with_input(content, input)?;
            } else {
                let output = Output::stdout(stopped.clone());
                let summary = input.visit(if external.is_empty() { threads } else { 1 }, &stopped, || (), |_, _, mut candidate| {
                    if input.accepts(&mut candidate)? {
                        if request.output == "metadata" {
                            let record = candidate.record.as_ref().ok_or("Requested metadata projection is unavailable").map_err(io::Error::other)?;
                            let mut bytes = serde_json::to_vec(&json!({"type":"match","data":{"path":crate::text(candidate.path.as_os_str().as_bytes()),"findui_file":record}}))?;
                            bytes.push(b'\n'); output.write(&bytes)?;
                        } else { output.path(candidate.path.as_os_str().as_bytes())?; }
                    }
                    Ok(())
                })?;
                if summary.errors > 0 {
                    return Err(Incomplete(summary.errors as u64).into());
                }
            }
        }
        "wordSearch" => {
            let mut selected = tempfile::NamedTempFile::new()?;
            let writer = Mutex::new(io::BufWriter::new(selected.as_file_mut()));
            let summary = input.visit(
                1,
                &stopped,
                || (),
                |_, _, mut candidate| {
                    if input.accepts(&mut candidate)? {
                        let mut out = writer.lock().unwrap();
                        out.write_all(candidate.path.as_os_str().as_bytes())?;
                        out.write_all(&[0])?;
                    }
                    Ok(())
                },
            )?;
            writer.into_inner().unwrap().flush()?;
            if selected.as_file().metadata()?.len() == 0 {
                if summary.errors > 0 {
                    return Err(Incomplete(summary.errors as u64).into());
                }
                return Ok(());
            }
            let mut content = request.content.ok_or("Word search needs content options")?;
            content.word_selection = Some(word_ids.as_ref().unwrap().path().into());
            content.word_fuzzy_order = !external.is_empty();
            crate::fulltext::search_to(
                content,
                &mut io::BufWriter::new(io::stdout()),
                Some(&mut io::BufReader::new(fs::File::open(selected.path())?)),
            )?;
            if summary.errors > 0 {
                return Err(Incomplete(summary.errors as u64).into());
            }
        }
        _ => return Err("Unknown search action".into()),
    }
    drop(spotlight_file);
    drop(temporary);
    if selection_errors > 0 {
        return Err(Incomplete(selection_errors as u64).into());
    }
    Ok(())
}

/// Evaluate cheap predicates once, then join external membership in a temporary
/// SQLite store. Its cache is bounded; large OR/NOT groups do not allocate one
/// in-memory hash set per branch. Ranking remains the real fzf result order.
fn select(
    input: &Input,
    config: &paths::Configuration,
    external: &[External],
    threads: usize,
    stopped: &AtomicBool,
    preserve_masks: bool,
) -> Result<(tempfile::NamedTempFile, usize, bool), Box<dyn std::error::Error>> {
    let scratch = tempfile::NamedTempFile::new()?;
    let db = rusqlite::Connection::open(scratch.path())?;
    db.execute_batch("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=FILE; PRAGMA cache_size=-16384; BEGIN; CREATE TABLE candidates(path BLOB PRIMARY KEY, mask BLOB, position INTEGER, record BLOB) WITHOUT ROWID; CREATE TABLE members(leaf INTEGER,path BLOB,rank INTEGER,priority INTEGER,PRIMARY KEY(leaf,path)) WITHOUT ROWID;")?;
    let tree = config.tree.clone().unwrap_or(Tree::Leaf { leaf: 0 });
    let count = config.leaves.as_ref().map_or(1, Vec::len);
    tree.validate(count, 0, &mut 0)?;
    if external.iter().any(|e| e.leaf >= count) {
        return Err("Invalid external predicate index".into());
    }
    let mut priority = Vec::new();
    fn positives(tree: &Tree, negated: bool, out: &mut Vec<usize>) {
        match tree {
            Tree::Leaf { leaf } if !negated => {
                if !out.contains(leaf) {
                    out.push(*leaf);
                }
            }
            Tree::Leaf { .. } => {}
            Tree::All { all } => all.iter().for_each(|t| positives(t, negated, out)),
            Tree::Any { any } => any.iter().for_each(|t| positives(t, negated, out)),
            Tree::None { none } => none.iter().for_each(|t| positives(t, !negated, out)),
        }
    }
    positives(&tree, false, &mut priority);
    priority.retain(|i| {
        external
            .iter()
            .any(|e| e.leaf == *i && e.invocation.arguments.iter().any(|s| s == "--filter"))
    });
    let predicates = paths::Predicate::new(config.clone())?;
    let records = preserve_masks || predicates.needs_tags();
    let db = Mutex::new(db);
    let summary = input.visit(
        threads,
        stopped,
        || (),
        |_, index, mut candidate| {
            if candidate.path.as_os_str().is_empty() {
                return Ok(());
            }
            if let Some(path) = candidate.path.to_str() {
                candidate.path = predicates.restore_root(path).into();
            }
            let Some(mask) = candidate.mask(&predicates, input.follow)? else {
                return Ok(());
            };
            let mut possible: Vec<_> = mask.iter().map(|&value| (!value, value)).collect();
            for e in external {
                possible[e.leaf] = (true, true);
            }
            if !tree.possibilities(&possible).1 {
                return Ok(());
            }
            db.lock()
                .unwrap()
                .execute(
                    "INSERT OR IGNORE INTO candidates VALUES(?,?,?,?)",
                    rusqlite::params![
                        candidate.path.as_os_str().as_bytes(),
                        mask.iter().map(|&v| u8::from(v)).collect::<Vec<_>>(),
                        index as i64,
                        if records {
                            candidate
                                .record
                                .as_ref()
                                .map(serde_json::to_vec)
                                .transpose()?
                        } else {
                            None
                        }
                    ],
                )
                .map_err(io::Error::other)?;
            Ok(())
        },
    )?;
    let db = db.into_inner().unwrap();
    let mut paths = tempfile::NamedTempFile::new()?;
    {
        let mut write = io::BufWriter::new(paths.as_file_mut());
        let mut stmt = db.prepare("SELECT path FROM candidates ORDER BY position")?;
        for path in stmt.query_map([], |r| r.get::<_, Vec<u8>>(0))? {
            write.write_all(&path?)?;
            write.write_all(&[0])?;
        }
        write.flush()?;
    }
    let mut projection: Option<(Vec<PathBuf>, tempfile::NamedTempFile)> = None;
    for e in external {
        if let Some(roots) = &e.relative_roots {
            if projection
                .as_ref()
                .is_none_or(|(previous, _)| previous != roots)
            {
                let mut projected = tempfile::NamedTempFile::new()?;
                // Keep the join on disk, bounded like the ordinary selector. Two
                // scopes may have the same relative filename; retain both paths.
                db.execute_batch("CREATE TEMP TABLE IF NOT EXISTS projected(key BLOB,path BLOB,PRIMARY KEY(key,path)) WITHOUT ROWID; DELETE FROM projected;")?;
                let mut write = io::BufWriter::new(projected.as_file_mut());
                let mut stmt = db.prepare("SELECT path FROM candidates ORDER BY position")?;
                let mut insert = db.prepare("INSERT OR IGNORE INTO projected VALUES(?,?)")?;
                for path in stmt.query_map([], |r| r.get::<_, Vec<u8>>(0))? {
                    let path = path?;
                    let native = std::path::Path::new(std::ffi::OsStr::from_bytes(&path));
                    for root in roots {
                        if let Ok(relative) = native.strip_prefix(root) {
                            let key = relative.as_os_str().as_bytes();
                            if !key.is_empty() && insert.execute(rusqlite::params![key, &path])? > 0
                            {
                                write.write_all(key)?;
                                write.write_all(&[0])?;
                            }
                        }
                    }
                }
                write.flush()?;
                drop(write);
                projection = Some((roots.clone(), projected));
            }
        }
        let source = if e.relative_roots.is_some() {
            projection.as_mut().unwrap().1.as_file_mut()
        } else {
            paths.as_file_mut()
        };
        source.rewind()?;
        let result = tempfile::NamedTempFile::new()?;
        e.invocation.run(Some(source), result.as_file(), stopped)?;
        let sql = if e.relative_roots.is_some() {
            "INSERT OR IGNORE INTO members SELECT ?1,path,?3,?4 FROM projected WHERE key=?2"
        } else {
            "INSERT OR IGNORE INTO members VALUES(?,?,?,?)"
        };
        let mut insert = db.prepare(sql)?;
        for (rank, path) in io::BufReader::new(fs::File::open(result.path())?)
            .split(0)
            .enumerate()
        {
            let path = path?;
            if path.is_empty() {
                continue;
            }
            insert.execute(rusqlite::params![
                e.leaf as i64,
                path,
                rank as i64,
                priority.iter().position(|i| *i == e.leaf).map(|i| i as i64)
            ])?;
        }
    }
    db.execute_batch("CREATE INDEX member_paths ON members(path); COMMIT;")?;
    let mut selected = tempfile::NamedTempFile::new()?;
    let mut write = io::BufWriter::new(selected.as_file_mut());
    let mut stmt = db.prepare("WITH ranks AS (SELECT path,priority,rank,row_number() OVER(PARTITION BY path ORDER BY priority) AS pick FROM members WHERE priority IS NOT NULL) SELECT c.path,c.mask,(SELECT group_concat(leaf) FROM members m WHERE m.path=c.path),c.record FROM candidates c LEFT JOIN ranks r ON r.path=c.path AND r.pick=1 ORDER BY coalesce(r.priority,2147483647),coalesce(r.rank,c.position)")?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        if stopped.load(Relaxed) {
            break;
        }
        let mut mask: Vec<bool> = row
            .get::<_, Vec<u8>>(1)?
            .into_iter()
            .map(|v| v != 0)
            .collect();
        for e in external {
            mask[e.leaf] = false;
        }
        if let Some(leaves) = row.get::<_, Option<String>>(2)? {
            for leaf in leaves.split(',') {
                mask[leaf.parse::<usize>()?] = true;
            }
        }
        if tree.selected(&mask) {
            if preserve_masks {
                let mut record: paths::Record = serde_json::from_slice(&row.get::<_, Vec<u8>>(3)?)?;
                record.conditions = Some(mask);
                serde_json::to_writer(&mut write, &record)?;
            } else {
                write.write_all(&row.get::<_, Vec<u8>>(if records { 3 } else { 0 })?)?;
            }
            write.write_all(&[0])?;
        }
    }
    write.flush()?;
    drop(write);
    Ok((selected, summary.errors, records))
}
