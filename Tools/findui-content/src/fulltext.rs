//! Explicit, local FTS5 preparation and word search. Normal searches never
//! create this index. Readers use one SQLite snapshot and BM25 ranking.
use crate::{
    content_index::{self, Cache, Signature},
    documents::{self, Document},
    extraction::Extraction,
    text, Plan, Tree,
};
use rusqlite::{params, params_from_iter, Connection, OpenFlags};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    fs,
    io::{self, BufRead, Write},
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering::Relaxed},
        Arc, Mutex,
    },
    time::Duration,
};
fn empty_extraction() -> Extraction {
    Extraction {
        documents: false,
        archives: false,
        media: false,
        ffmpeg: None,
        ffprobe: None,
        adapters: vec![],
        encoding: None,
        cache_directory: None,
        max_depth: 5,
        max_megabytes: 64,
        timeout_seconds: 60,
        rga: None,
        pandoc: None,
        pdftotext: None,
        pdfdetach: None,
        tika_jar: None,
    }
}
fn adapter_ids(plan: &Plan) -> String {
    serde_json::to_string(
        &plan
            .extraction
            .as_ref()
            .map(|e| {
                e.adapters
                    .iter()
                    .filter(|a| a.enabled)
                    .map(|a| &a.id)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default(),
    )
    .unwrap()
}
fn directory(plan: &Plan) -> io::Result<&Path> {
    plan.index_directory
        .as_deref()
        .ok_or_else(|| io::Error::other("Choose a local directory for the word index"))
}
fn plan_config(plan: &Plan) -> io::Result<String> {
    let mut e = plan.extraction.clone().unwrap_or_else(empty_extraction);
    e.encoding = plan.encoding.clone();
    e.config()
}
fn report_status(db: &Connection, plan: &Plan) -> Result<(), Box<dyn std::error::Error>> {
    require_profile(db, plan)?;
    let value = crate::word_state::status(db, plan, &plan_config(plan)?)?;
    eprintln!("findui-word-status: {value}");
    if value["state"] != "updated" {
        eprintln!(
            "findui-index: {}",
            value["message"]
                .as_str()
                .unwrap_or("Update the word index.")
        );
    }
    Ok(())
}
pub fn status(plan: Plan) -> Result<(), Box<dyn std::error::Error>> {
    let root = directory(&plan)?;
    let value = if root.join("words-v1.sqlite").is_file() {
        let db = database(root, false)?;
        match require_profile(&db, &plan) {
            Ok(()) => crate::word_state::status(&db, &plan, &plan_config(&plan)?)?,
            Err(error) => json!({"state":"needsUpdate","message":error.to_string()}),
        }
    } else {
        json!({"state":"notPrepared","message":"Prepare words in this folder to use indexed search."})
    };
    println!("{value}");
    Ok(())
}
fn require_profile(db: &Connection, plan: &Plan) -> Result<(), Box<dyn std::error::Error>> {
    let table = crate::word_tokenizer::table(plan)?;
    let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    let exists: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name=?)",
        [&table],
        |r| r.get(0),
    )?;
    if version < 2 || !exists {
        return Err(
            "Update the word index to prepare this language. Stored document text is reused."
                .into(),
        );
    }
    Ok(())
}
fn database(root: &Path, writable: bool) -> rusqlite::Result<Connection> {
    let path = root.join("words-v1.sqlite");
    let connection = Connection::open_with_flags(
        path,
        if writable {
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE
        } else {
            OpenFlags::SQLITE_OPEN_READ_ONLY
        },
    )?;
    crate::word_tokenizer::register(&connection)?;
    connection.busy_timeout(Duration::from_secs(10))?;
    if writable {
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS sources(path TEXT PRIMARY KEY,identity TEXT NOT NULL,complete INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS documents(id INTEGER PRIMARY KEY,path TEXT NOT NULL,body TEXT NOT NULL,title TEXT NOT NULL,author TEXT NOT NULL,member TEXT NOT NULL,origin TEXT,identity TEXT NOT NULL,requires_documents INTEGER NOT NULL,requires_archives INTEGER NOT NULL,encoding TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS by_path ON documents(path);
")?;
        let columns: Vec<String> = connection
            .prepare("PRAGMA table_info(documents)")?
            .query_map([], |r| r.get(1))?
            .collect::<Result<_, _>>()?;
        for (name, sql) in [
            (
                "requires_media",
                "ALTER TABLE documents ADD COLUMN requires_media INTEGER NOT NULL DEFAULT 0",
            ),
            (
                "adapter",
                "ALTER TABLE documents ADD COLUMN adapter TEXT NOT NULL DEFAULT ''",
            ),
        ] {
            if !columns.iter().any(|s| s == name) {
                connection.execute_batch(sql)?;
            }
        }
        crate::word_state::schema(&connection)?;
    } else {
        connection.execute_batch("PRAGMA query_only=ON; BEGIN")?;
    }
    Ok(connection)
}
pub fn suggest(plan: Plan, prefix: &str) -> Result<(), Box<dyn std::error::Error>> {
    let root = directory(&plan)?;
    let prefix = crate::word_tokenizer::normalize(prefix.trim());
    if prefix.chars().count() < 2 || prefix.len() > 128 || !root.join("words-v1.sqlite").is_file() {
        println!("[]");
        return Ok(());
    }
    let db = database(root, false)?;
    require_profile(&db, &plan)?;
    let roots = crate::word_state::canonical_roots(&plan.word_roots);
    let scopes = if roots.is_empty() {
        "1".into()
    } else {
        roots
            .iter()
            .map(|_| "(path>=? AND path<?)")
            .collect::<Vec<_>>()
            .join(" OR ")
    };
    let sql = format!("SELECT term,count(DISTINCT doc) AS frequency FROM word_terms WHERE term>=? AND term<? AND doc IN (SELECT id FROM documents WHERE ({scopes}) AND (requires_documents=0 OR ?) AND (requires_archives=0 OR ?) AND (requires_media=0 OR ?) AND (adapter='' OR adapter IN (SELECT value FROM json_each(?))) AND encoding=?) GROUP BY term ORDER BY frequency DESC,term LIMIT 8");
    let mut args: Vec<rusqlite::types::Value> =
        vec![prefix.clone().into(), format!("{prefix}\u{10ffff}").into()];
    for root in roots {
        let root = root.to_string_lossy();
        let prefix = root.trim_end_matches('/');
        args.extend([format!("{prefix}/").into(), format!("{prefix}0").into()]);
    }
    args.push((plan.extraction.as_ref().is_some_and(|e| e.documents) as i64).into());
    args.push((plan.extraction.as_ref().is_some_and(|e| e.archives) as i64).into());
    args.push((plan.extraction.as_ref().is_some_and(|e| e.media) as i64).into());
    args.push(adapter_ids(&plan).into());
    args.push(plan.encoding.unwrap_or_default().into());
    let values: Vec<Value> = db
        .prepare(&sql)?
        .query_map(params_from_iter(args), |r| {
            Ok(json!({"text":r.get::<_,String>(0)?,"documents":r.get::<_,i64>(1)?}))
        })?
        .collect::<Result<_, _>>()?;
    println!("{}", serde_json::to_string(&values)?);
    Ok(())
}
fn origin(doc: &Document, identity: &str, line: u64) -> Value {
    let location = doc.locations.iter().rev().find(|p| p.line <= line);
    json!({"extractor":"FindUI word index","line":line,"page":location.and_then(|p|p.page),"sheet":location.and_then(|p|p.sheet.as_ref()),"slide":location.and_then(|p|p.slide),
        "members":doc.members,"documentTitle":doc.metadata.get("title"),"author":doc.metadata.get("author"),"sourceIdentity":identity,
        "reader":doc.metadata.get("finduiReader"),"timecode":location.and_then(|p|p.timecode.as_ref()),"recordKey":doc.metadata.get("finduiRecord"),"table":doc.metadata.get("table"),"row":doc.metadata.get("row"),"message":doc.metadata.get("message")})
}
pub fn prepare(plan: Plan) -> Result<(), Box<dyn std::error::Error>> {
    prepare_with_input(plan, crate::input::Input::default())
}
pub(crate) fn prepare_with_input(
    mut plan: Plan,
    input: crate::input::Input,
) -> Result<(), Box<dyn std::error::Error>> {
    let root = directory(&plan)?.to_owned();
    let _lease = crate::extraction::lease_directory(&root)?;
    let language = crate::word_tokenizer::language(&plan)?;
    let connection = database(&root, true)?;
    crate::word_tokenizer::prepare(&connection, language)?;
    let db = Mutex::new(connection);
    let mut e = plan.extraction.take().unwrap_or_else(empty_extraction);
    e.encoding = plan.encoding.clone();
    if e.documents || e.archives || e.media || !e.adapters.is_empty() {
        e.validate()?;
    }
    let _text_lease = e.lease()?;
    let _tika = crate::extraction::tika_lease(e.tika_jar.as_deref())?;
    let config = e.config()?;
    let locks = root.join("word-locks-v1");
    fs::create_dir_all(&locks)?;
    let stopped = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, stopped.clone())?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, stopped.clone())?;
    let updated = AtomicU64::new(0);
    let reused = AtomicU64::new(0);
    let errors = AtomicU64::new(0);
    let threads = crate::input::workers(plan.threads);
    crate::extraction::set_workers(threads);
    let prepared_paths = Mutex::new(std::collections::HashMap::new());
    let roots = crate::word_state::RootMap::new(&plan.word_roots);
    let summary = input.visit(threads, &stopped, || (), |_, _, mut candidate| {
        if stopped.load(Relaxed) {return Ok(())}
        let result=(||->Result<(),Box<dyn std::error::Error>> {
            if !input.accepts(&mut candidate)? { return Ok(()) }
            let path=candidate.path;
            if path.starts_with(&root) || !path.is_file() {return Ok(())}
            let display=path.to_str().ok_or("Word indexes require UTF-8 paths")?.to_owned();
            let path=roots.stored(&path)?;
            let path_text=path.to_str().ok_or("Word indexes require UTF-8 paths")?;
            {
                let mut paths=prepared_paths.lock().unwrap();
                if paths.contains_key(path_text) { return Ok(()) }
                paths.insert(path_text.to_owned(),display);
            }
            // Unchanged sources do not acquire a per-source lease. Contending
            // updates recheck after locking. Hash stripes bound lock storage
            // to 4096 files instead of creating a directory for every source.
            let saved_identity=|| db.lock().unwrap().prepare_cached("SELECT identity FROM sources WHERE path=? AND complete=1").and_then(|mut s|s.query_row([path_text],|r|r.get::<_,String>(0))).ok();
            if saved_identity().as_deref()==Some(&content_index::identity(&path,&config)?) {reused.fetch_add(1,Relaxed);return Ok(())}
            let key=content_index::hash(path_text.as_bytes());
            let _source_lock=crate::extraction::lock_file(&locks.join(&key[..3]),&stopped,600)?;
            let identity=content_index::identity(&path,&config)?;
            let source_identity=content_index::identity(&path,"open-v1")?;
            let saved=saved_identity();
            if saved.as_deref()==Some(&identity) {reused.fetch_add(1,Relaxed);return Ok(())}
            let format=e.format(&path)?;
            let structured=e.converts(&format)||crate::archive::is_format(&format);
            let cache=if structured {e.cache_directory.as_ref().and_then(|r|Cache::new(&r.join("structured-v2"),&path,&config).ok())} else {None};
            let _lock=cache.as_ref().map(|c|c.lock(&stopped)).transpose()?;
            let bundle=if let Some(bundle)=cache.as_ref().and_then(|c|c.bundle(e.max_megabytes*1024*1024)) {bundle}
                else {let bundle=documents::extract_selected_as(&path,&e,&config,&stopped,None,Some(&format))?;
                    if bundle.warnings.is_empty()&&!bundle.incomplete&&content_index::identity(&path,&config)?==identity {
                        if let Some(cache)=&cache {cache.save(Signature::bundle(&bundle),Some(&bundle))?;}
                    } else if !stopped.load(Relaxed) && content_index::identity(&path,&config)?==identity {
                        if let Some(cache)=&cache {cache.remember_failure(&bundle)?;}
                    } bundle};
            if stopped.load(Relaxed) {return Err("Word index preparation cancelled".into())}
            if content_index::identity(&path,&config)?!=identity {return Err("File changed while preparing words; retry".into())}
            if content_index::identity(&path,"open-v1")?!=source_identity {return Err("File changed while preparing words; retry".into())}
            let mut connection=db.lock().unwrap();let transaction=connection.transaction()?;
            transaction.execute("DELETE FROM documents WHERE path=?",[path_text])?;
            for doc in &bundle.documents {
                let converted=doc.metadata.get("finduiRequiresDocuments").is_some_and(|s|s=="true");
                let provenance=if structured {Some(serde_json::to_string(&json!({"origin":origin(doc,&source_identity,1),"locations":doc.locations}))?)} else {None};
                transaction.execute("INSERT INTO documents(path,body,title,author,member,origin,identity,requires_documents,requires_archives,encoding,requires_media,adapter) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                    params![path_text,doc.text,doc.metadata.get("title").map_or("",String::as_str),doc.metadata.get("author").map_or("",String::as_str),
                        doc.members.iter().map(|m|m.name.as_str()).collect::<Vec<_>>().join("/"),provenance,source_identity,converted,!doc.members.is_empty(),plan.encoding.as_deref().unwrap_or(""),doc.metadata.contains_key("finduiRequiresMedia"),doc.metadata.get("finduiAdapter").map_or("", String::as_str)])?;
            }
            transaction.execute("INSERT OR REPLACE INTO sources VALUES(?,?,?)",params![path_text,identity,bundle.warnings.is_empty()&&!bundle.incomplete])?;
            transaction.commit()?;updated.fetch_add(1,Relaxed);
            for warning in bundle.warnings {eprintln!("findui-skipped: {}: {warning}",path.display());errors.fetch_add(1,Relaxed);}
            Ok(())
        })();
        if let Err(error)=result {eprintln!("findui-skipped: {error}");errors.fetch_add(1,Relaxed);}
        Ok(())
    })?;
    errors.fetch_add(summary.errors as u64, Relaxed);
    let pruned = crate::word_state::save(
        &mut db.lock().unwrap(),
        &plan,
        &config,
        &prepared_paths
            .into_inner()
            .unwrap()
            .into_iter()
            .collect::<Vec<_>>(),
        !stopped.load(Relaxed) && errors.load(Relaxed) == 0,
        input.collect_coverage.then_some(summary.coverage),
    )?;
    eprintln!(
        "findui-stats: {}",
        json!({"indexesUpdated":updated.load(Relaxed),"filesSkippedByIndex":reused.load(Relaxed),"sourcesPruned":pruned,"workers":threads,"wordIndex":true})
    );
    if stopped.load(Relaxed) || errors.load(Relaxed) > 0 {
        return Err("Some files could not be prepared; completed files are retained".into());
    }
    Ok(())
}
fn quoted(text: &str) -> String {
    format!("\"{}\"", text.replace('"', "\"\""))
}
fn expression(
    tree: &Tree,
    leaves: &[Option<String>],
    table: &str,
    args: &mut Vec<String>,
    container: bool,
    files: &[Option<usize>],
) -> String {
    match tree {
        Tree::Leaf { leaf } => {
            if let Some(index) = files[*leaf] {
                return format!("coalesce((SELECT json_extract(mask,'$[{index}]') FROM file_masks WHERE path=d.path),0)=1");
            }
            if let Some(query) = &leaves[*leaf] {
                args.push(query.clone());
                if container {
                    format!("d.path IN (SELECT e.path FROM eligible e WHERE e.id IN (SELECT rowid FROM {table} WHERE {table} MATCH ?))")
                } else {
                    format!("d.id IN (SELECT rowid FROM {table} WHERE {table} MATCH ?)")
                }
            } else {
                "1".into()
            }
        }
        Tree::All { all } => {
            if all.is_empty() {
                "1".into()
            } else {
                format!(
                    "({})",
                    all.iter()
                        .map(|t| expression(t, leaves, table, args, container, files))
                        .collect::<Vec<_>>()
                        .join(" AND ")
                )
            }
        }
        Tree::Any { any } => {
            if any.is_empty() {
                "0".into()
            } else {
                format!(
                    "({})",
                    any.iter()
                        .map(|t| expression(t, leaves, table, args, container, files))
                        .collect::<Vec<_>>()
                        .join(" OR ")
                )
            }
        }
        Tree::None { none } => {
            if none.is_empty() {
                "1".into()
            } else {
                format!(
                    "NOT ({})",
                    none.iter()
                        .map(|t| expression(t, leaves, table, args, container, files))
                        .collect::<Vec<_>>()
                        .join(" OR ")
                )
            }
        }
    }
}
fn highlight_markers(body: &str) -> (String, String) {
    if !body.contains(['\u{1}', '\u{2}']) {
        return ("\u{1}".into(), "\u{2}".into());
    }
    // SQLite inserts the delimiters verbatim. Choose markers proven absent
    // from this row; a fixed delimiter can consume real source characters.
    for id in 0u64.. {
        let open = format!("\u{1}findui:{id}:open\u{2}");
        let close = format!("\u{1}findui:{id}:close\u{2}");
        if !body.contains(&open) && !body.contains(&close) {
            return (open, close);
        }
    }
    unreachable!()
}
fn highlights(marked: &str, open: &str, close: &str) -> (String, Vec<(usize, usize)>) {
    let mut text = String::new();
    let mut ranges = Vec::new();
    let mut remaining = marked;
    while let Some(start) = remaining.find(open) {
        text.push_str(&remaining[..start]);
        let after = &remaining[start + open.len()..];
        let Some(end) = after.find(close) else { break };
        let from = text.len();
        text.push_str(&after[..end]);
        ranges.push((from, text.len()));
        remaining = &after[end + close.len()..];
    }
    text.push_str(remaining);
    (text, ranges)
}
pub fn search(plan: Plan) -> Result<(), Box<dyn std::error::Error>> {
    search_to(plan, &mut io::BufWriter::new(io::stdout()), None)
}
pub(crate) fn search_to(
    plan: Plan,
    output: &mut dyn Write,
    selection: Option<&mut dyn BufRead>,
) -> Result<(), Box<dyn std::error::Error>> {
    let root = directory(&plan)?;
    if !root.join("words-v1.sqlite").is_file() {
        return Err("Use Update Word Index in Scope & Options → Content matches, or run FindUI --cli index words first".into());
    }
    let _lease = crate::extraction::lease_directory(root)?;
    let connection = database(root, false)?;
    if let Some(path) = &plan.word_file_masks {
        // The persistent index stays read-only. SQLite's query_only also blocks
        // temporary tables, so allow only this connection-local candidate join.
        connection.execute_batch("PRAGMA query_only=OFF; CREATE TEMP TABLE file_masks(path TEXT PRIMARY KEY,mask TEXT,position INTEGER) WITHOUT ROWID;")?;
        let mut insert = connection.prepare("INSERT OR IGNORE INTO file_masks VALUES(?,?,?)")?;
        for (position, bytes) in io::BufReader::new(fs::File::open(path)?)
            .split(0)
            .enumerate()
        {
            let bytes = bytes?;
            if bytes.is_empty() {
                continue;
            }
            let record: crate::paths::Record = serde_json::from_slice(&bytes)?;
            let canonical = fs::canonicalize(&record.path)?;
            let mask = record.conditions.ok_or("Missing file condition values")?;
            insert.execute(params![
                canonical
                    .to_str()
                    .ok_or("Word indexes require UTF-8 paths")?,
                serde_json::to_string(&mask)?,
                position as i64
            ])?;
        }
        drop(insert);
        connection.execute_batch("PRAGMA query_only=ON")?;
    }
    plan.tree.validate(plan.leaves.len(), 0, &mut 0)?;
    if plan.word_selection.is_none() {
        report_status(&connection, &plan)?;
    }
    if let Some(file) = &plan.word_selection {
        select_candidates(&connection, file, selection)?;
    }
    if plan.typo_tolerance > 0 || plan.case_sensitive {
        return Err("Indexed words are case-insensitive. Turn off typo matching and Match case, or use a live text search".into());
    }
    let table = crate::word_tokenizer::table(&plan)?;
    let leaves=plan.leaves.iter().map(|l| {
        if l.regex||!l.terms.is_empty() {return Err("Indexed words support literal words, phrases and Boolean groups; use live search for regex or proximity")}
        if l.pattern.is_empty() {return Ok(None)}
        let column=match l.field.as_deref(){None=>"body:",Some("author")=>"author:",Some("title")=>"title:",Some("member")=>"member:",_=>return Err("Unknown word-index field")};
        Ok(Some(format!("{column}{}",quoted(&l.pattern))))
    }).collect::<Result<Vec<_>,_>>()?;
    let ranking = plan
        .positive
        .iter()
        .filter_map(|i| leaves.get(*i).and_then(|v| v.clone()))
        .collect::<Vec<_>>()
        .join(" OR ");
    let mut args = Vec::new();
    let mut condition = expression(
        &plan.tree,
        &leaves,
        &table,
        &mut args,
        plan.file_unit && !plan.document_unit,
        &plan.leaves.iter().map(|l| l.file_index).collect::<Vec<_>>(),
    );
    if plan.word_selection.is_some() {
        condition = "d.id IN (SELECT id FROM selected_documents)".into();
        args.clear();
    }
    let scopes = if plan.word_roots.is_empty() {
        "1".to_string()
    } else {
        plan.word_roots
            .iter()
            .map(|_| "(path>=? AND path<?)")
            .collect::<Vec<_>>()
            .join(" OR ")
    };
    let selection = if plan.word_file_masks.is_some() {
        " AND path IN (SELECT path FROM file_masks)"
    } else if plan.word_selection.is_some() {
        " AND id IN (SELECT id FROM selected_documents)"
    } else {
        ""
    };
    let eligible=format!("WITH eligible AS NOT MATERIALIZED (SELECT id,path FROM documents WHERE (requires_documents=0 OR ?) AND (requires_archives=0 OR ?) AND (requires_media=0 OR ?) AND (adapter='' OR adapter IN (SELECT value FROM json_each(?))) AND encoding=? AND ({scopes}){selection})");
    let display = if plan.files_only || plan.word_candidates {
        "'',NULL"
    } else {
        "d.body,d.origin"
    };
    let mut sql = if ranking.is_empty() || plan.word_candidates {
        format!("{eligible} SELECT d.id,d.path,{display},d.identity,0 FROM documents d JOIN eligible permitted ON permitted.id=d.id WHERE {condition} ORDER BY d.path,d.id")
    } else {
        args.insert(0, ranking.clone());
        format!("{eligible}, hits AS MATERIALIZED (SELECT rowid,bm25({table},1.0,3.0,2.0,1.0) AS score FROM {table} WHERE {table} MATCH ? AND rowid IN (SELECT id FROM eligible)) SELECT d.id,d.path,{display},d.identity,coalesce(hits.score,0) AS relevance FROM documents d JOIN eligible permitted ON permitted.id=d.id LEFT JOIN hits ON hits.rowid=d.id WHERE {condition} ORDER BY relevance,d.path,d.id")
    };
    if plan.word_file_masks.is_some() && plan.word_fuzzy_order {
        sql = sql
            .replace(
                "ORDER BY relevance,d.path,d.id",
                "ORDER BY (SELECT position FROM file_masks WHERE path=d.path),relevance,d.id",
            )
            .replace(
                "ORDER BY d.path,d.id",
                "ORDER BY (SELECT position FROM file_masks WHERE path=d.path),d.id",
            );
    } else if plan.word_fuzzy_order {
        sql = sql
            .replace(
                "ORDER BY relevance,d.path,d.id",
                "ORDER BY (SELECT position FROM selected_documents WHERE id=d.id),relevance,d.id",
            )
            .replace(
                "ORDER BY d.path,d.id",
                "ORDER BY (SELECT position FROM selected_documents WHERE id=d.id),d.id",
            );
    }
    let mut values: Vec<rusqlite::types::Value> = vec![
        (plan.extraction.as_ref().is_some_and(|e| e.documents) as i64).into(),
        (plan.extraction.as_ref().is_some_and(|e| e.archives) as i64).into(),
        (plan.extraction.as_ref().is_some_and(|e| e.media) as i64).into(),
        adapter_ids(&plan).into(),
        plan.encoding.clone().unwrap_or_default().into(),
    ];
    let roots = crate::word_state::RootMap::new(&plan.word_roots);
    for root in roots.canonical() {
        let prefix = root
            .to_str()
            .ok_or("Word indexes require UTF-8 roots")?
            .trim_end_matches('/');
        values.push(format!("{prefix}/").into());
        values.push(format!("{prefix}0").into());
    }
    values.extend(args.into_iter().map(rusqlite::types::Value::from));
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(params_from_iter(values))?;
    let mut highlight = if !plan.files_only && !plan.word_candidates && !ranking.is_empty() {
        Some(connection.prepare(&format!(
            "SELECT highlight({table},0,?,?) FROM {table} WHERE rowid=? AND {table} MATCH ?"
        ))?)
    } else {
        None
    };
    let mut output = output;
    let mut identities = std::collections::HashMap::new();
    let mut stale = HashSet::new();
    let mut emitted = HashSet::new();
    let generation = crate::word_state::generation(&connection);
    let mut snippets = 0;
    while let Some(row) = rows.next()? {
        let id: i64 = row.get(0)?;
        let stored: String = row.get(1)?;
        let path = if plan.word_roots.is_empty() {
            connection
                .query_row(
                    "SELECT display FROM word_aliases WHERE path=?",
                    [&stored],
                    |r| r.get::<_, String>(0),
                )
                .unwrap_or_else(|_| stored.clone())
        } else {
            roots
                .selected(Path::new(&stored))
                .to_string_lossy()
                .into_owned()
        };
        let body: String = row.get(2)?;
        let origin: Option<String> = row.get(3)?;
        let saved: String = row.get(4)?;
        let score: f64 = row.get(5)?;
        if plan.word_candidates {
            serde_json::to_writer(
                &mut output,
                &json!({"type":"match","data":{"path":text(path.as_bytes()),"findui_word_id":id,"findui_generation":generation,"findui_stored_path":stored,"findui_identity":saved}}),
            )?;
            output.write_all(b"\n")?;
            continue;
        }
        let current = identities
            .entry(path.clone())
            .or_insert_with(|| content_index::identity(Path::new(&path), "open-v1").ok());
        if current.as_deref() != Some(&saved) {
            stale.insert(path);
            continue;
        }
        if plan.files_only {
            if emitted.insert(path.clone()) {
                if plan.word_selection.is_some() || plan.word_file_masks.is_some() {
                    output.write_all(path.as_bytes())?;
                    output.write_all(&[0])?;
                    continue;
                }
                serde_json::to_writer(
                    &mut output,
                    &json!({"type":"match","data":{"path":text(path.as_bytes()),"findui_relevance":score}}),
                )?;
                output.write_all(b"\n")?;
            }
            continue;
        }
        let (plain, ranges) = if ranking.is_empty() {
            (body, Vec::new())
        } else {
            let (open, close) = highlight_markers(&body);
            match highlight
                .as_mut()
                .unwrap()
                .query_row(params![open, close, id, ranking], |r| r.get::<_, String>(0))
            {
                Ok(marked) => highlights(&marked, &open, &close),
                Err(rusqlite::Error::QueryReturnedNoRows) => (body, Vec::new()),
                Err(error) => return Err(error.into()),
            }
        };
        snippets += 1;
        let first = ranges.first().map_or(0, |r| r.0);
        let start = plain[..first].rfind('\n').map_or(0, |i| i + 1);
        let end = plain[first..]
            .find('\n')
            .map_or(plain.len(), |i| first + i + 1);
        let line = plain[..start].bytes().filter(|b| *b == b'\n').count() + 1;
        let snippet = &plain[start..end];
        let submatches:Vec<_>=ranges.into_iter().filter(|r|r.0>=start&&r.1<=end).map(|(a,b)|json!({"start":a-start,"end":b-start,"match":text(&plain.as_bytes()[a..b])})).collect();
        let mut data = json!({"path":text(path.as_bytes()),"lines":text(snippet.as_bytes()),"line_number":line,"absolute_offset":start,"submatches":submatches,"findui_relevance":score});
        if let Some(origin) = origin {
            let mut saved: Value = serde_json::from_str(&origin)?;
            let location = saved["locations"]
                .as_array()
                .and_then(|a| {
                    a.iter()
                        .rev()
                        .find(|p| p["line"].as_u64().unwrap_or(0) <= line as u64)
                })
                .cloned();
            let origin = &mut saved["origin"];
            origin["line"] = json!(line);
            if let Some(location) = location {
                for key in ["page", "sheet", "slide", "timecode"] {
                    origin[key] = location[key].clone();
                }
            }
            data["findui_origin"] = origin.clone();
            data["line_number"] = Value::Null;
        }
        serde_json::to_writer(&mut output, &json!({"type":"match","data":data}))?;
        output.write_all(b"\n")?;
    }
    output.flush()?;
    if plan.stats {
        eprintln!(
            "findui-stats: {}",
            json!({"wordSnippets":snippets,"wordCandidatePhase":plan.word_candidates})
        );
    }
    if !stale.is_empty() {
        eprintln!(
            "findui-index: {} changed or missing files were skipped; update the word index",
            stale.len()
        );
    }
    Ok(())
}

/// Retain only IDs and source identities between phases. Reuse those IDs, not
/// the Boolean query or bodies. Reject a concurrently replaced index generation.
fn select_candidates(
    db: &Connection,
    file: &Path,
    selection: Option<&mut dyn BufRead>,
) -> Result<(), Box<dyn std::error::Error>> {
    db.execute_batch("PRAGMA query_only=OFF; CREATE TEMP TABLE selected_paths(path TEXT PRIMARY KEY,position INTEGER); CREATE TEMP TABLE selected_documents(id INTEGER PRIMARY KEY,position INTEGER);")?;
    let mut stdin = io::BufReader::new(io::stdin());
    let reader = selection.unwrap_or(&mut stdin);
    for (position, path) in reader.split(0).enumerate() {
        let path = String::from_utf8(path?)?;
        if !path.is_empty() {
            db.execute(
                "INSERT OR IGNORE INTO selected_paths VALUES(?,?)",
                params![path, position as i64],
            )?;
        }
    }
    let generation = crate::word_state::generation(db);
    let mut insert = db.prepare("INSERT OR IGNORE INTO selected_documents SELECT ?,position FROM selected_paths WHERE path=?")?;
    for line in io::BufReader::new(fs::File::open(file)?).lines() {
        let row: Value = serde_json::from_str(&line?)?;
        let d = &row["data"];
        if d["findui_generation"].as_i64() != Some(generation) {
            return Err("Word index changed during search; run the search again".into());
        }
        insert.execute(params![
            d["findui_word_id"]
                .as_i64()
                .ok_or("Invalid word candidate")?,
            d["path"]["text"].as_str().ok_or("Invalid word path")?
        ])?;
    }
    drop(insert);
    db.execute_batch("PRAGMA query_only=ON")?;
    Ok(())
}
/// Disk spool joins FTS results to the existing file-predicate pipeline. FTS is
/// queried once; fuzzy filters can still rank paths using fzf without rescans.
pub fn spool(
    action: &str,
    file: &str,
    files_only: bool,
    fuzzy: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut output = io::BufWriter::new(io::stdout());
    if action == "--word-paths" {
        let mut seen = HashSet::new();
        for line in io::BufReader::new(fs::File::open(file)?).lines() {
            let row: Value = serde_json::from_str(&line?)?;
            if let Some(path) = row["data"]["path"]["text"].as_str() {
                if seen.insert(path.to_string()) {
                    output.write_all(path.as_bytes())?;
                    output.write_all(&[0])?;
                }
            }
        }
    } else {
        let staging = tempfile::NamedTempFile::new()?;
        let db = Connection::open(staging.path())?;
        db.execute_batch("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=FILE; BEGIN; CREATE TABLE selected(path TEXT PRIMARY KEY, position INTEGER); CREATE TABLE matches(path TEXT, record TEXT, position INTEGER);")?;
        for (i, path) in io::BufReader::new(io::stdin()).split(0).enumerate() {
            let path = String::from_utf8(path?)?;
            if !path.is_empty() {
                db.execute(
                    "INSERT OR IGNORE INTO selected VALUES(?,?)",
                    params![path, i as i64],
                )?;
            }
        }
        for (i, line) in io::BufReader::new(fs::File::open(file)?)
            .lines()
            .enumerate()
        {
            let line = line?;
            let row: Value = serde_json::from_str(&line)?;
            if let Some(path) = row["data"]["path"]["text"].as_str() {
                db.execute(
                    "INSERT INTO matches VALUES(?,?,?)",
                    params![path, if files_only { "" } else { &line }, i as i64],
                )?;
            }
        }
        db.execute_batch("CREATE INDEX match_paths ON matches(path)")?;
        if files_only {
            let mut read=db.prepare("SELECT path FROM selected WHERE path IN (SELECT path FROM matches) ORDER BY position")?;
            for path in read.query_map([], |r| r.get::<_, String>(0))? {
                output.write_all(path?.as_bytes())?;
                output.write_all(&[0])?;
            }
        } else {
            let mut read=db.prepare(if fuzzy {"SELECT record FROM matches JOIN selected USING(path) ORDER BY selected.position,matches.position"} else {"SELECT record FROM matches JOIN selected USING(path) ORDER BY matches.position"})?;
            for line in read.query_map([], |r| r.get::<_, String>(0))? {
                output.write_all(line?.as_bytes())?;
                output.write_all(b"\n")?;
            }
        }
    }
    output.flush()?;
    Ok(())
}
