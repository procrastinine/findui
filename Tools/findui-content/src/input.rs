//! Candidate sources share one worker budget. A live search runs its file
//! predicates and scan in the walk callback, retaining metadata and locality.
use crate::{paths::{Predicate, Record}, walk, word_state};
use ignore::WalkState;
use rayon::prelude::*;
use std::{ffi::OsString, fs, io::{self, BufRead}, os::unix::ffi::{OsStrExt, OsStringExt},
    path::PathBuf, sync::{Mutex, atomic::{AtomicBool, AtomicUsize, Ordering::Relaxed}}};

pub(crate) enum Source {
    Live(walk::Configuration),
    Stdin,
    Paths(PathBuf),
    Records(PathBuf),
    Snapshot(PathBuf),
}
pub(crate) struct Candidate {
    pub path: PathBuf,
    pub record: Option<Record>,
    pub metadata: Option<fs::Metadata>,
    pub directory: Option<bool>,
}
impl Candidate {
    pub fn path(path: PathBuf) -> Self { Self { path, record: None, metadata: None, directory: None } }
    pub fn metadata(&mut self, follow: bool) -> io::Result<&fs::Metadata> {
        if self.metadata.is_none() {
            self.metadata = Some(if follow { fs::metadata(&self.path)? } else { fs::symlink_metadata(&self.path)? });
        }
        Ok(self.metadata.as_ref().unwrap())
    }
    pub fn mask(&mut self, predicate: &Predicate, follow: bool) -> io::Result<Option<Vec<bool>>> {
        let Some(path) = self.path.to_str().map(str::to_owned) else {
            return Err(io::Error::other("This file predicate requires a UTF-8 path"))
        };
        if self.record.is_none() {
            let mut record = if predicate.needs_metadata() || self.directory.is_none() {
                Record::from_metadata(&path, self.metadata(follow)?)
            } else { Record { path: path.clone(), directory: self.directory.unwrap(), size: None, modified: None, created: None, tags: None, conditions: None } };
            if predicate.needs_tags() { record.tags = Some(crate::metadata::finder_tags(&self.path, follow)?); }
            self.record = Some(record);
        }
        predicate.mask(&path, self.record.as_ref())
    }
}
pub(crate) struct Input {
    pub source: Source,
    pub predicate: Option<Predicate>,
    pub admission: Option<walk::Configuration>,
    pub follow: bool,
    pub collect_coverage: bool,
}
pub(crate) struct Summary {
    pub errors: usize,
    pub coverage: word_state::Coverage,
}
impl Default for Input {
    fn default() -> Self { Self { source: Source::Stdin, predicate: None, admission: None, follow: false, collect_coverage: false } }
}
impl Input {
    pub fn accepts(&self, candidate: &mut Candidate) -> io::Result<bool> {
        if candidate.path.as_os_str().is_empty() { return Ok(false) }
        match &self.predicate {
            None => Ok(true),
            Some(predicate) => {
                if let Some(path) = candidate.path.to_str() { candidate.path = predicate.restore_root(path).into(); }
                Ok(candidate.mask(predicate, self.follow)?.is_some_and(|mask| predicate.selected(&mask)))
            }
        }
    }
    pub fn visit<S: Send, I, V>(&self, threads: usize, stopped: &AtomicBool, init: I, visit: V) -> io::Result<Summary>
    where I: Fn() -> S + Sync, V: Fn(&mut S, usize, Candidate) -> io::Result<()> + Sync {
        let errors = AtomicUsize::new(0);
        let coverage = Mutex::new(word_state::Coverage::default());
        let report = |result: io::Result<()>| { if let Err(e) = result {
            if e.kind() == io::ErrorKind::BrokenPipe { stopped.store(true, Relaxed); }
            else { errors.fetch_add(1, Relaxed); eprintln!("findui-skipped: {e}"); }
        }};
        match &self.source {
            Source::Live(config) => {
                config.validate()?;
                let mut builder = config.builder()?;
                builder.threads(threads);
                let roots = word_state::RootMap::new(&config.roots);
                if self.collect_coverage {
                    builder.min_depth(Some(0));
                    coverage.lock().unwrap().roots = roots.canonical().cloned().collect();
                }
                let seen = Mutex::new(crate::unique::Unique::new());
                let count = AtomicUsize::new(0);
                builder.build_parallel().run(|| {
                    let mut state = init();
                    let (roots, coverage, seen, count, visit, report) = (&roots, &coverage, &seen, &count, &visit, &report);
                    Box::new(move |entry| {
                        if stopped.load(Relaxed) { return WalkState::Quit }
                        let entry = match entry { Ok(entry) => entry, Err(e) => { report(Err(io::Error::other(e))); return WalkState::Continue } };
                        let Some(kind) = entry.file_type() else { return WalkState::Continue };
                        if self.collect_coverage && kind.is_dir() {
                            report(roots.stored(entry.path()).and_then(|p| crate::content_index::identity(&p, "word-directory-v1").map(|id| {
                                coverage.lock().unwrap().directories.insert(p, id);
                            })));
                        }
                        if entry.depth() < config.minimum_depth || (!kind.is_file() && !kind.is_dir()) || !config.kind_admitted(kind.is_dir()) {
                            return WalkState::Continue
                        }
                        if config.roots.len() > 1 {
                            let canonical = match roots.stored(entry.path()) { Ok(p) => p, Err(e) => { report(Err(e)); return WalkState::Continue } };
                            match seen.lock().unwrap().insert(canonical.as_os_str().as_bytes()) {
                                Ok(true) => {}, Ok(false) => return WalkState::Continue,
                                Err(e) => { report(Err(e)); return WalkState::Quit },
                            }
                        }
                        let mut candidate = Candidate::path(entry.path().to_owned());
                        candidate.directory = Some(kind.is_dir());
                        if config.minimum.is_some() || config.maximum.is_some() {
                            match entry.metadata() {
                                Err(e) => { report(Err(io::Error::other(e))); return WalkState::Continue },
                                Ok(m) => {
                                    if kind.is_dir() || config.minimum.is_some_and(|s| m.len() < s) || config.maximum.is_some_and(|s| m.len() > s) { return WalkState::Continue }
                                    candidate.metadata = Some(m);
                                }
                            }
                        }
                        report(visit(&mut state, count.fetch_add(1, Relaxed), candidate));
                        WalkState::Continue
                    })
                });
            }
            Source::Snapshot(path) => {
                // SQLite owns the frozen generation; never stat a saved record.
                // Name/metadata-only selection is a streaming cursor with no
                // JSON round trip through another process.
                let db = rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(io::Error::other)?;
                let (sql, args) = crate::paths::snapshot_query(&db, self.predicate.as_ref().map(Predicate::configuration));
                let mut stmt = db.prepare(&sql).map_err(io::Error::other)?;
                let mut rows = stmt.query(rusqlite::params_from_iter(args)).map_err(io::Error::other)?;
                let mut state = init(); let mut index = 0;
                while let Some(row) = rows.next().map_err(io::Error::other)? {
                    if stopped.load(Relaxed) { break }
                    let bytes = row.get_ref(0).map_err(io::Error::other)?.as_blob().map_err(io::Error::other)?;
                    let record: Record = serde_json::from_slice(bytes)?;
                    report(visit(&mut state, index, Candidate { path: record.path.clone().into(), directory: Some(record.directory), record: Some(record), metadata: None }));
                    index += 1;
                }
            }
            _ => {
                let records = matches!(self.source, Source::Records(_));
                let reader: Box<dyn BufRead + Send> = match &self.source {
                    Source::Stdin => Box::new(io::BufReader::new(io::stdin())),
                    Source::Paths(path) | Source::Records(path) => Box::new(io::BufReader::new(fs::File::open(path)?)),
                    _ => unreachable!(),
                };
                let admission = self.admission.clone().map(walk::Admission::new).transpose()?;
                let roots = self.admission.as_ref().map(|c| word_state::RootMap::new(&c.roots));
                let mut seen = crate::unique::Unique::new();
                let paths = reader.split(0).filter_map(|raw| {
                    let decoded = (|| -> io::Result<Option<Candidate>> {
                        let raw = raw?;
                        if raw.is_empty() { return Ok(None) }
                        let mut candidate = if records {
                            let record: Record = serde_json::from_slice(&raw)?;
                            Candidate { path: record.path.clone().into(), directory: Some(record.directory), record: Some(record), metadata: None }
                        } else { Candidate::path(OsString::from_vec(raw).into()) };
                        // Normalize known root aliases before deduplication, so
                        // saved lists do not repeat metadata or body reads. A
                        // frozen record is keyed by path, never by its JSON.
                        if let Some(admission) = &admission { candidate.path = admission.normalize(candidate.path); }
                        let key = roots.as_ref().and_then(|r| r.stored(&candidate.path).ok());
                        let key = key.as_deref().unwrap_or(&candidate.path);
                        Ok(if seen.insert(key.as_os_str().as_bytes())? { Some(candidate) } else { None })
                    })();
                    match decoded { Ok(candidate) => candidate.map(Ok), Err(e) => Some(Err(e)) }
                });
                let pool = rayon::ThreadPoolBuilder::new().num_threads(threads).build().map_err(io::Error::other)?;
                pool.install(|| paths.enumerate().par_bridge().for_each_init(|| (init(), admission.clone()), |(state, admission), (index, raw)| {
                    if stopped.load(Relaxed) { return }
                    // Keep the index even for rejected paths. Ordered sinks
                    // must advance across every candidate, including misses.
                    let decoded = (|| -> io::Result<Candidate> {
                        let mut candidate = raw?;
                        if let Some(admission) = admission {
                            match admission.admit(candidate.path.clone())? {
                                Some((path, metadata)) => { candidate.path = path; candidate.directory = Some(metadata.is_dir()); candidate.metadata = Some(metadata); },
                                None => { candidate.path = PathBuf::new(); },
                            }
                        }
                        Ok(candidate)
                    })();
                    // Advance ordered consumers across malformed records too.
                    // A source error is a partial search, not user cancellation.
                    let candidate = match decoded {
                        Ok(candidate) => candidate,
                        Err(e) => { report(Err(e)); Candidate::path(PathBuf::new()) },
                    };
                    report(visit(state, index, candidate));
                }));
            }
        }
        let mut coverage = coverage.into_inner().unwrap();
        coverage.complete = self.collect_coverage && errors.load(Relaxed) == 0 && !stopped.load(Relaxed);
        Ok(Summary { errors: errors.load(Relaxed), coverage })
    }
}
pub(crate) fn workers(requested: usize) -> usize {
    if requested == 0 { std::thread::available_parallelism().map_or(2, usize::from).min(12) } else { requested.clamp(1, 64) }
}
