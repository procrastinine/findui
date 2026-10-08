use crate::{
    content_index::{Cache, RecordingReader, Signature},
    documents::Document,
    *,
};
use std::{
    fs,
    io::{Cursor, Read},
};

struct Compiled {
    matchers: Vec<RegexMatcher>,
    indices: Vec<usize>,
    near: Vec<Option<proximity::Proximity>>,
    typos: Vec<Option<typos::Typos>>,
    fields: Vec<Option<String>>,
    file_indices: Vec<Option<usize>>,
    prefilter: RegexMatcher,
    highlights: Vec<usize>,
    exact_prefilter: bool,
}
struct Matches<'a> {
    plan: &'a Plan,
    compiled: &'a Compiled,
    output: &'a Output,
    path: &'a [u8],
    document: Option<&'a Document>,
    tags: Option<&'a [String]>,
    source_identity: &'a str,
    mask: Vec<bool>,
    unique: Vec<bool>,
    states: Vec<proximity::State>,
    found: bool,
    binary: bool,
    bytes: &'a AtomicU64,
    witness: Option<Vec<u8>>,
    record_bytes: Vec<u8>,
    buffered_output: Option<crate::output::BufferedOutput<'a>>,
    immediate_records: u8,
    ranges: Vec<(usize, usize)>,
}
impl<'a> Matches<'a> {
    fn new(
        plan: &'a Plan,
        compiled: &'a Compiled,
        output: &'a Output,
        path: &'a [u8],
        document: Option<&'a Document>,
        source_identity: &'a str,
        bytes: &'a AtomicU64,
        files: &[bool],
    ) -> Self {
        let unique: Vec<bool> = compiled
            .fields
            .iter()
            .enumerate()
            .map(|(i, field)| {
                if let Some(index) = compiled.file_indices[i] {
                    return files[index];
                }
                field.as_ref().is_some_and(|field| {
                    document.is_some_and(|doc| {
                        let value = if field == "member" {
                            Some(
                                doc.members
                                    .iter()
                                    .map(|m| m.name.as_str())
                                    .collect::<Vec<_>>()
                                    .join("/"),
                            )
                        } else {
                            doc.metadata.get(field).cloned()
                        };
                        value.is_some_and(|v| {
                            compiled.matchers[i].is_match(v.as_bytes()).unwrap_or(false)
                        })
                    })
                })
            })
            .collect();
        Self {
            plan,
            tags: None,
            compiled,
            output,
            path,
            document,
            source_identity,
            mask: compiled.indices.iter().map(|&i| unique[i]).collect(),
            unique,
            states: (0..compiled.matchers.len())
                .map(|_| proximity::State::default())
                .collect(),
            found: false,
            binary: false,
            bytes,
            witness: None,
            record_bytes: Vec::with_capacity(path.len() + 512),
            buffered_output: None,
            immediate_records: 0,
            ranges: Vec::new(),
        }
    }
    fn record(&mut self, bytes: &[u8], line: u64, offset: u64) -> io::Result<()> {
        let submatches = &mut self.ranges;
        submatches.clear();
        for &index in self.compiled.highlights.iter().filter(|i| self.unique[**i]) {
            if self.compiled.fields[index].is_some() {
                continue;
            }
            if self.compiled.near[index].is_some() || self.compiled.typos[index].is_some() {
                for &(start, end) in &self.states[index].ranges {
                    if end <= bytes.len() {
                        submatches.push((start, end));
                    }
                }
            } else {
                self.compiled.matchers[index]
                    .find_iter(bytes, |m| {
                        submatches.push((m.start(), m.end()));
                        true
                    })
                    .map_err(io::Error::other)?;
            }
        }
        submatches.sort_unstable();
        submatches.dedup();
        let origin = if let Some(doc) = self.document {
            let location = doc
                .locations
                .partition_point(|p| p.line <= line)
                .checked_sub(1)
                .map(|i| &doc.locations[i]);
            Some(json!({"extractor":"FindUI", "line":line,
                "page":location.and_then(|p|p.page),"sheet":location.and_then(|p|p.sheet.as_ref()),
                "slide":location.and_then(|p|p.slide),"members":doc.members,
                "documentTitle":doc.metadata.get("title"),"author":doc.metadata.get("author"),
                "sourceIdentity":self.source_identity,"metadataOnly":doc.metadata.contains_key("finduiNameOnly"),
                "reader":doc.metadata.get("finduiReader"), "timecode":location.and_then(|p|p.timecode.as_ref()), "memberKind":doc.metadata.get("finduiMemberKind"), "recordKey":doc.metadata.get("finduiRecord"), "table":doc.metadata.get("table"), "row":doc.metadata.get("row"), "message":doc.metadata.get("message")}))
        } else {
            None
        };
        crate::records::encode_into(
            &mut self.record_bytes,
            self.path,
            bytes,
            if self.document.is_some() {
                None
            } else {
                Some(line)
            },
            offset,
            submatches,
            origin,
            self.tags,
        )
    }
    fn complete(&mut self) -> io::Result<bool> {
        let matched = !self.binary
            && if self.plan.file_unit {
                self.plan.tree.selected(&self.mask)
            } else {
                self.found
            };
        if matched && self.plan.file_unit && !self.plan.files_only {
            if let Some(witness) = &self.witness {
                self.output.write(witness)?;
            } else {
                self.record(b"", 1, 0)?;
                self.output.write(&self.record_bytes)?;
            }
        }
        Ok(matched)
    }
}
impl Sink for Matches<'_> {
    type Error = io::Error;
    fn matched(&mut self, _: &Searcher, line: &SinkMatch<'_>) -> io::Result<bool> {
        if self.output.stopped.load(Relaxed) {
            return Ok(false);
        }
        if self.plan.index_only {
            return Ok(true);
        }
        let bytes = line.bytes();
        for (i, matcher) in self.compiled.matchers.iter().enumerate() {
            if self.compiled.fields[i].is_some() || self.compiled.file_indices[i].is_some() {
                continue;
            }
            if self.plan.file_unit && self.unique[i] {
                continue;
            }
            self.unique[i] = if let Some(typos) = &self.compiled.typos[i] {
                self.states[i].ranges = typos.ranges(bytes);
                !self.states[i].ranges.is_empty()
            } else if let Some(near) = &self.compiled.near[i] {
                near.matches(bytes, &mut self.states[i])
            } else if self.document.is_none() && self.compiled.exact_prefilter {
                // The searcher already matched this exact single predicate.
                // Re-run it only to obtain requested highlight ranges.
                true
            } else {
                matcher.is_match(bytes).map_err(io::Error::other)?
            };
        }
        for (i, source) in self.compiled.indices.iter().enumerate() {
            self.mask[i] = self.unique[*source];
        }
        let line_number = line.line_number().unwrap_or(1);
        if self.plan.file_unit {
            if !self.plan.files_only
                && self.witness.is_none()
                && (self.plan.positive.is_empty()
                    || self.plan.positive.iter().any(|i| self.mask[*i]))
            {
                self.record(bytes, line_number, line.absolute_byte_offset())?;
                self.witness = Some(self.record_bytes.clone());
            }
            let values: Vec<_> = self
                .mask
                .iter()
                .enumerate()
                .map(|(i, &seen)| {
                    if self.plan.leaves[i].file_index.is_some() {
                        (!seen, seen)
                    } else {
                        (!seen, true)
                    }
                })
                .collect();
            let possible = self.plan.tree.possibilities(&values);
            // A container-wide query still needs this member's complete mask.
            return Ok(
                self.document.is_some() && !self.plan.document_unit || possible == (true, true)
            );
        }
        if !self.plan.tree.selected(&self.mask) {
            return Ok(true);
        }
        self.found = true;
        if self.plan.files_only {
            if self.document.is_none() {
                self.output.path(self.path)?;
                return Ok(false);
            }
            return Ok(true);
        }
        self.record(bytes, line_number, line.absolute_byte_offset())?;
        if self.immediate_records < 8 {
            self.immediate_records += 1;
            self.output.write(&self.record_bytes)?;
        } else {
            self.buffered_output
                .get_or_insert_with(|| self.output.buffered())
                .write(&self.record_bytes)?;
        }
        Ok(true)
    }
    fn binary_data(&mut self, _: &Searcher, _: u64) -> io::Result<bool> {
        self.binary = true;
        Ok(false)
    }
    fn finish(&mut self, _: &Searcher, finish: &SinkFinish) -> io::Result<()> {
        if let Some(buffer) = &self.buffered_output {
            buffer.flush()?;
        }
        self.bytes.fetch_add(finish.byte_count(), Relaxed);
        Ok(())
    }
}

#[derive(Default)]
struct Stats {
    opened: AtomicU64,
    bytes: AtomicU64,
    skipped: AtomicU64,
    avoided: AtomicU64,
    converted: AtomicU64,
    archive_directories: AtomicU64,
    reused: AtomicU64,
    indexed: AtomicU64,
    errors: AtomicU64,
}

pub fn run(plan: Plan) -> Result<(), Box<dyn std::error::Error>> {
    run_with_input(plan, crate::input::Input::default())
}
pub(crate) fn run_with_input(
    mut plan: Plan,
    input: crate::input::Input,
) -> Result<(), Box<dyn std::error::Error>> {
    for leaf in &mut plan.leaves {
        if leaf.regex {
            leaf.required_literals = content_index::regex_literals(&leaf.pattern);
        }
    }
    if plan.archive_names_only {
        if plan.leaves.is_empty()
            || plan
                .leaves
                .iter()
                .any(|l| l.file_index.is_none() && l.field.as_deref() != Some("member"))
        {
            return Err("Archive-name mode only accepts member-name conditions".into());
        }
        // Metadata listing has its own cache namespace and never invokes a
        // converter, even when a caller supplies document extraction options.
        plan.extraction = Some(extraction::Extraction {
            encoding: None,
            documents: true,
            archives: false,
            media: false,
            ffmpeg: None,
            ffprobe: None,
            adapters: vec![],
            cache_directory: plan.index_directory.clone(),
            max_depth: 0,
            max_megabytes: 64,
            timeout_seconds: 60,
            rga: None,
            pandoc: None,
            pdftotext: None,
            pdfdetach: None,
            tika_jar: None,
        });
    }
    if plan.typo_tolerance > 2 {
        return Err("Typo tolerance must be 0, 1 or 2 edits".into());
    }
    let encoding = plan
        .encoding
        .as_deref()
        .filter(|s| !s.is_empty() && *s != "auto")
        .map(grep_searcher::Encoding::new)
        .transpose()?;
    if let Some(e) = &mut plan.extraction {
        e.encoding = plan.encoding.clone();
    }
    if plan.file_unit && !plan.document_unit {
        plan.files_only = true;
    }
    if let Some(e) = &plan.extraction {
        e.validate()?;
    }
    let _lease = match plan.extraction.as_ref().map(|e| e.lease()).transpose() {
        Ok(lease) => lease,
        Err(error) => {
            if plan.index_only {
                return Err(error.into());
            }
            eprintln!("findui-cache: {error}; searching without the document cache");
            plan.extraction.as_mut().unwrap().cache_directory = None;
            None
        }
    };
    let _index_lease = match plan
        .index_directory
        .as_deref()
        .map(extraction::lease_directory)
        .transpose()
    {
        Ok(lease) => lease,
        Err(error) => {
            if plan.index_only {
                return Err(error.into());
            }
            eprintln!("findui-cache: {error}; searching without the content index");
            plan.index_directory = None;
            None
        }
    };
    let _tika =
        extraction::tika_lease(plan.extraction.as_ref().and_then(|e| e.tika_jar.as_deref()))?;
    let config = plan.extraction.as_ref().map(|e| e.config()).transpose()?;
    plan.tree.validate(plan.leaves.len(), 0, &mut 0)?;
    let file_predicates = plan
        .file_predicates
        .clone()
        .map(crate::paths::Predicate::new)
        .transpose()?;
    let file_count = plan
        .file_predicates
        .as_ref()
        .and_then(|p| p.leaves.as_ref())
        .map_or(0, Vec::len);
    if plan
        .leaves
        .iter()
        .any(|l| l.file_index.is_some_and(|i| i >= file_count))
    {
        return Err("Invalid file condition index".into());
    }
    if plan.threads > 64 || plan.positive.iter().any(|i| *i >= plan.leaves.len()) {
        return Err("Invalid query plan".into());
    }
    let mut seen = HashMap::new();
    let mut compiled = Compiled {
        matchers: Vec::new(),
        indices: Vec::new(),
        near: Vec::new(),
        typos: Vec::new(),
        fields: Vec::new(),
        file_indices: Vec::new(),
        highlights: Vec::new(),
        exact_prefilter: false,
        prefilter: RegexMatcherBuilder::new().build("")?,
    };
    for leaf in &plan.leaves {
        if leaf
            .field
            .as_deref()
            .is_some_and(|f| !["author", "title", "member"].contains(&f))
        {
            return Err("Unknown document metadata field".into());
        }
        let index = if let Some(i) = seen.get(leaf) {
            *i
        } else {
            let matcher = RegexMatcherBuilder::new()
                .case_insensitive(!plan.case_sensitive)
                .word(plan.whole_words && !leaf.pattern.is_empty())
                .line_terminator(if plan.multiline { None } else { Some(b'\n') })
                .multi_line(true)
                .build(&if leaf.regex {
                    leaf.pattern.clone()
                } else {
                    regex_syntax::escape(&leaf.pattern)
                })?;
            let near = if leaf.terms.is_empty() {
                None
            } else {
                Some(proximity::Proximity::new(
                    &leaf.terms,
                    leaf.distance,
                    leaf.ordered,
                    plan.case_sensitive,
                )?)
            };
            let i = compiled.matchers.len();
            compiled.matchers.push(matcher);
            compiled.near.push(near);
            compiled.typos.push(
                if plan.typo_tolerance > 0
                    && !leaf.regex
                    && leaf.field.is_none()
                    && leaf.terms.is_empty()
                    && !leaf.pattern.is_empty()
                {
                    Some(typos::Typos::new(
                        &leaf.pattern,
                        plan.typo_tolerance,
                        plan.case_sensitive,
                    )?)
                } else {
                    None
                },
            );
            compiled.fields.push(leaf.field.clone());
            compiled.file_indices.push(leaf.file_index);
            seen.insert(leaf, i);
            i
        };
        compiled.indices.push(index);
    }
    for &leaf in &plan.positive {
        let index = compiled.indices[leaf];
        if !compiled.highlights.contains(&index) {
            compiled.highlights.push(index);
        }
    }
    let needs_all = plan.typo_tolerance > 0
        || plan.index_only
        || plan
            .tree
            .possibilities(
                &plan
                    .leaves
                    .iter()
                    .map(|l| {
                        if l.file_index.is_some() {
                            (true, true)
                        } else {
                            (true, false)
                        }
                    })
                    .collect::<Vec<_>>(),
            )
            .1
        || plan
            .leaves
            .iter()
            .any(|l| !l.terms.is_empty() || l.field.is_some());
    let patterns: Vec<String> = if needs_all || plan.leaves.is_empty() {
        vec![if plan.multiline {
            "(?s:.*)".into()
        } else {
            String::new()
        }]
    } else {
        plan.leaves
            .iter()
            .filter(|l| l.file_index.is_none())
            .map(|l| {
                if l.regex {
                    l.pattern.clone()
                } else {
                    regex_syntax::escape(&l.pattern)
                }
            })
            .collect()
    };
    compiled.prefilter = RegexMatcherBuilder::new()
        .case_insensitive(!plan.case_sensitive)
        .word(!needs_all && plan.whole_words && patterns.iter().any(|p| !p.is_empty()))
        .line_terminator(if plan.multiline { None } else { Some(b'\n') })
        .multi_line(true)
        .build_many(&patterns)?;
    compiled.exact_prefilter = !needs_all && compiled.matchers.len() == 1;
    let threads = crate::input::workers(plan.threads);
    crate::extraction::set_workers(threads);
    let stopped = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, stopped.clone())?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, stopped.clone())?;
    let output = Output::stdout(stopped);
    let ordered = OrderedOutput {
        next: Mutex::new(0),
        ready: Condvar::new(),
    };
    let stats = Stats::default();
    let search_file = |searcher: &mut Searcher,
                       out: &Output,
                       mut candidate: crate::input::Candidate| {
        if out.stopped.load(Relaxed) {
            return;
        }
        let label = candidate.path.display().to_string();
        let result = (|| -> io::Result<()> {
            if candidate.path.as_os_str().is_empty() || !input.accepts(&mut candidate)? {
                return Ok(());
            }
            let files = if let Some(predicate) = &file_predicates {
                let mask = if let Some(mask) =
                    candidate.record.as_ref().and_then(|r| r.conditions.clone())
                {
                    mask
                } else {
                    let Some(mask) = candidate.mask(predicate, input.follow)? else {
                        return Ok(());
                    };
                    mask
                };
                if mask.len() != file_count {
                    return Err(io::Error::other("Invalid file condition values"));
                }
                let possible = plan
                    .leaves
                    .iter()
                    .map(|l| l.file_index.map_or((true, true), |i| (!mask[i], mask[i])))
                    .collect::<Vec<_>>();
                match plan.tree.possibilities(&possible) {
                    (_, false) => return Ok(()),
                    (false, true) => {
                        out.path(candidate.path.as_os_str().as_bytes())?;
                        return Ok(());
                    }
                    _ => {}
                }
                mask
            } else {
                Vec::new()
            };
            let tags = candidate.record.as_ref().and_then(|r| r.tags.clone());
            let path = candidate.path.clone();
            let raw = path.as_os_str().as_bytes();
            if candidate.directory == Some(false)
                && plan.extraction.is_none()
                && !plan.archive_names_only
                && !plan.index_only
                && plan.use_index == Some(false)
            {
                // The walker already knows this is a regular file. Plain scans
                // need neither an extra stat nor format/cache setup. Explicit
                // metadata predicates have already consumed the shared record.
                stats.opened.fetch_add(1, Relaxed);
                let mut sink =
                    Matches::new(&plan, &compiled, out, raw, None, "", &stats.bytes, &files);
                sink.tags = tags.as_deref();
                searcher.search_path(&compiled.prefilter, &path, &mut sink)?;
                if sink.complete()? && plan.file_unit && plan.files_only {
                    out.path(raw)?;
                }
                return Ok(());
            }
            let metadata = candidate.metadata(true)?;
            if !metadata.is_file() {
                return Ok(());
            }
            if plan.archive_names_only && !archive::has_cheap_names(&path) {
                if archive::is_archive(&path) {
                    return Err(io::Error::other("This format needs archive expansion to search member names; enable it explicitly"));
                }
                return Ok(());
            }
            let extension = crate::formats::extension(&path);
            let format = if plan
                .extraction
                .as_ref()
                .is_some_and(|e| e.adapter(&extension).is_some())
            {
                extension
            } else if plan.extraction.is_some() && !plan.archive_names_only {
                crate::formats::detect_cached_with_metadata(
                    &path,
                    plan.extraction
                        .as_ref()
                        .and_then(|e| e.cache_directory.as_deref()),
                    &metadata,
                )?
            } else {
                crate::formats::extension(&path)
            };
            let is_document = crate::formats::document(&format);
            let is_archive = archive::is_format(&format);
            let attachments = matches!(format.as_str(), "pdf" | "eml" | "mbox");
            let structured = plan.archive_names_only
                || plan.extraction.as_ref().is_some_and(|e| {
                    e.converts(&format) || e.archives && (is_archive || attachments)
                });
            if !plan.archive_names_only
                && plan.extraction.as_ref().is_some_and(|e| {
                    !e.converts(&format)
                        && (is_document || crate::media::recognizes(&format))
                        && !(e.archives && attachments)
                        || !e.archives && is_archive && e.adapter(&format).is_none()
                })
            {
                return Ok(());
            }
            // A 16 KiB signature costs more than reading most source files.
            // Do not prepare records that normal searches would never use.
            if plan.index_only && !structured && metadata.len() < 256 * 1024 {
                return Ok(());
            }
            let root = if structured {
                plan.extraction
                    .as_ref()
                    .and_then(|e| e.cache_directory.as_ref())
                    .map(|p| {
                        p.join(if plan.archive_names_only {
                            "zip-names-v1"
                        } else {
                            "structured-v2"
                        })
                    })
            } else if metadata.len() >= 256 * 1024 || plan.index_only {
                plan.index_directory.as_ref().map(|p| p.join("content-v2"))
            } else {
                None
            };
            let cache_config = if structured {
                config.as_deref().unwrap_or("")
            } else {
                "plain-v2"
            };
            let mut cache = root
                .as_ref()
                .filter(|_| content_index::cacheable(&metadata))
                .map(|r| Cache::from_metadata(r, &path, cache_config, &metadata));
            if plan.index_only && !content_index::cacheable(&metadata) {
                return Err(io::Error::other("Coarse filesystem timestamps prevent safe indexing; this file will be searched normally"));
            }
            let summary = cache.as_ref().and_then(Cache::summary);
            if let Some(summary) = &summary {
                if plan.index_only
                    || (plan.use_index != Some(false) && !summary.signature.may_match(&plan))
                {
                    stats.skipped.fetch_add(1, Relaxed);
                    stats.avoided.fetch_add(metadata.len(), Relaxed);
                    return Ok(());
                }
            }
            if plan.index_only && !structured {
                let cache = cache.as_ref().ok_or_else(|| {
                    io::Error::other("Choose an index directory before preparing content")
                })?;
                let _lock = cache.lock(&out.stopped)?;
                if cache.summary().is_some() {
                    stats.skipped.fetch_add(1, Relaxed);
                    return Ok(());
                }
                let mut reader = RecordingReader::new(fs::File::open(&path)?);
                let mut buffer = [0u8; 65_536];
                let mut read = 0;
                loop {
                    if out.stopped.load(Relaxed) {
                        return Err(io::Error::other("Index preparation cancelled"));
                    }
                    let count = reader.read(&mut buffer)?;
                    if count == 0 {
                        break;
                    }
                    read += count as u64;
                }
                if cache.identity != content_index::identity(&path, cache_config)? {
                    return Err(io::Error::other(
                        "File changed while preparing its index; retry",
                    ));
                }
                cache.save(reader.signature, None)?;
                stats.opened.fetch_add(1, Relaxed);
                stats.bytes.fetch_add(read, Relaxed);
                stats.indexed.fetch_add(1, Relaxed);
                return Ok(());
            }
            if structured {
                if plan.index_only && cache.is_none() {
                    return Err(io::Error::other(
                        "Enable document caching before preparing documents",
                    ));
                }
                let e = plan.extraction.as_ref().unwrap();
                let identity = content_index::identity(&path, "open-v1")?;
                let lock = match cache.as_ref().map(|c| c.lock(&out.stopped)).transpose() {
                    Ok(lock) => lock,
                    Err(error) => {
                        if plan.index_only {
                            return Err(error);
                        }
                        eprintln!("findui-cache: {}: {error}", path.display());
                        cache = None;
                        None
                    }
                };
                let bundle = if let Some(bundle) = cache
                    .as_ref()
                    .and_then(|c| c.bundle(e.max_megabytes * 1024 * 1024))
                {
                    stats.reused.fetch_add(1, Relaxed);
                    bundle
                } else {
                    let bundle = if plan.archive_names_only {
                        stats.archive_directories.fetch_add(1, Relaxed);
                        documents::zip_names(&path, &out.stopped, e.timeout_seconds)?
                    } else {
                        stats.converted.fetch_add(1, Relaxed);
                        let select = |members: &[documents::Member]| {
                            let name = members
                                .iter()
                                .map(|m| m.name.as_str())
                                .collect::<Vec<_>>()
                                .join("/");
                            let values = compiled
                                .indices
                                .iter()
                                .map(|i| {
                                    if let Some(file) = compiled.file_indices[*i] {
                                        (!files[file], files[file])
                                    } else if compiled.fields[*i].as_deref() == Some("member") {
                                        let found = compiled.matchers[*i]
                                            .is_match(name.as_bytes())
                                            .unwrap_or(true);
                                        (!found, found)
                                    } else {
                                        (true, true)
                                    }
                                })
                                .collect::<Vec<_>>();
                            plan.tree.possibilities(&values).1
                        };
                        let selection: Option<&documents::Selection<'_>> = (!plan.index_only
                            && (!plan.file_unit || plan.document_unit))
                            .then_some(&select);
                        documents::extract_selected_as(
                            &path,
                            e,
                            config.as_deref().unwrap(),
                            &out.stopped,
                            selection,
                            Some(&format),
                        )?
                    };
                    if bundle.warnings.is_empty() && !bundle.incomplete {
                        if let Some(cache) = &cache {
                            if cache.identity == content_index::identity(&path, cache_config)? {
                                match cache.save(Signature::bundle(&bundle), Some(&bundle)) {
                                    Ok(()) => {
                                        stats.indexed.fetch_add(1, Relaxed);
                                    }
                                    Err(error) => {
                                        if plan.index_only {
                                            return Err(error);
                                        }
                                        eprintln!("findui-cache: {}: {error}", path.display())
                                    }
                                }
                            }
                        }
                    } else if let Some(cache) = &cache {
                        if !out.stopped.load(Relaxed)
                            && cache.identity == content_index::identity(&path, cache_config)?
                        {
                            if let Err(error) = cache.remember_failure(&bundle) {
                                eprintln!("findui-cache: {error}");
                            }
                        }
                    }
                    bundle
                };
                stats.reused.fetch_add(bundle.member_cache_hits, Relaxed);
                drop(lock);
                for warning in &bundle.warnings {
                    eprintln!("findui-skipped: {}: {warning}", path.display());
                    stats.errors.fetch_add(1, Relaxed);
                }
                if plan.index_only {
                    return Ok(());
                }
                if identity != content_index::identity(&path, "open-v1")? {
                    return Err(io::Error::other(
                        "Document changed while being read; retry the search",
                    ));
                }
                let mut container = plan
                    .leaves
                    .iter()
                    .map(|l| l.file_index.is_some_and(|i| files[i]))
                    .collect::<Vec<_>>();
                let mut any = false;
                let mut document_searcher = SearcherBuilder::new()
                    .multi_line(plan.multiline)
                    .heap_limit(Some(256 * 1024 * 1024 / threads.max(1)))
                    .line_number(true)
                    .build();
                for doc in &bundle.documents {
                    stats.opened.fetch_add(1, Relaxed);
                    let mut sink = Matches::new(
                        &plan,
                        &compiled,
                        out,
                        raw,
                        Some(doc),
                        &identity,
                        &stats.bytes,
                        &files,
                    );
                    sink.tags = tags.as_deref();
                    let input = if doc.text.is_empty() {
                        "\n"
                    } else if plan.file_unit && plan.leaves.iter().all(|leaf| leaf.field.is_some())
                    {
                        doc.text.split_inclusive('\n').next().unwrap_or("\n")
                    } else {
                        &doc.text
                    };
                    document_searcher.search_reader(
                        &compiled.prefilter,
                        Cursor::new(input.as_bytes()),
                        &mut sink,
                    )?;
                    for (i, value) in sink.mask.iter().enumerate() {
                        container[i] |= *value;
                    }
                    if !plan.file_unit || plan.document_unit {
                        any |= sink.complete()?;
                    }
                }
                if plan.file_unit && !plan.document_unit {
                    any = plan.tree.selected(&container);
                }
                if plan.files_only && any {
                    out.path(raw)?;
                }
            } else {
                stats.opened.fetch_add(1, Relaxed);
                let mut sink =
                    Matches::new(&plan, &compiled, out, raw, None, "", &stats.bytes, &files);
                sink.tags = tags.as_deref();
                // Building signatures is an explicit preparation cost. Normal
                // first searches retain grep's fast reader; indexed files are
                // repaired during their required rescan after edits.
                if summary.is_none()
                    && cache
                        .as_ref()
                        .is_some_and(|c| plan.index_only || c.was_indexed())
                {
                    let mut reader = RecordingReader::new(fs::File::open(&path)?);
                    searcher.search_reader(&compiled.prefilter, &mut reader, &mut sink)?;
                    if reader.complete && !out.stopped.load(Relaxed) {
                        let cache = cache.as_ref().unwrap();
                        if cache.identity == content_index::identity(&path, cache_config)? {
                            match cache.lock(&out.stopped).and_then(|_lock| {
                                if cache.summary().is_none() {
                                    cache.save(reader.signature, None)?;
                                    stats.indexed.fetch_add(1, Relaxed);
                                }
                                Ok(())
                            }) {
                                Ok(()) => {}
                                Err(error) => {
                                    eprintln!("findui-cache: {}: {error}", path.display())
                                }
                            }
                        }
                    }
                } else {
                    sink.tags = tags.as_deref();
                    searcher.search_path(&compiled.prefilter, &path, &mut sink)?;
                }
                if !plan.index_only && sink.complete()? && plan.file_unit && plan.files_only {
                    out.path(raw)?;
                }
            }
            Ok(())
        })();
        if let Err(e) = result {
            if e.kind() != io::ErrorKind::BrokenPipe {
                eprintln!("findui-skipped: {label}: {e}");
                stats.errors.fetch_add(1, Relaxed);
            }
        }
    };
    let summary = input.visit(
        threads,
        &output.stopped,
        || {
            SearcherBuilder::new()
                .multi_line(plan.multiline)
                .heap_limit(Some(256 * 1024 * 1024 / threads.max(1)))
                .line_number(!plan.files_only)
                .encoding(encoding.clone())
                .binary_detection(BinaryDetection::quit(0))
                .build()
        },
        |searcher, index, candidate| {
            if plan.ordered {
                let spool =
                    (!ordered.is_next(index)).then(|| Output::spool(output.stopped.clone()));
                search_file(searcher, spool.as_ref().unwrap_or(&output), candidate);
                ordered.emit(index, spool.as_ref(), &output)
            } else {
                search_file(searcher, &output, candidate);
                Ok(())
            }
        },
    )?;
    stats.errors.fetch_add(summary.errors as u64, Relaxed);
    if plan.stats || plan.index_only {
        eprintln!(
            "findui-stats: {}",
            json!({"filesOpened":stats.opened.load(Relaxed),"bytesSearched":stats.bytes.load(Relaxed),
        "uniqueMatchers":compiled.matchers.len(),"workers":threads,"filesSkippedByIndex":stats.skipped.load(Relaxed),"sourceBytesAvoided":stats.avoided.load(Relaxed),
        "documentsConverted":stats.converted.load(Relaxed),"archiveDirectoriesRead":stats.archive_directories.load(Relaxed),"documentCacheHits":stats.reused.load(Relaxed),"indexesUpdated":stats.indexed.load(Relaxed)})
        );
    }
    if stats.errors.load(Relaxed) > 0 {
        return Err(crate::execution::Incomplete(stats.errors.load(Relaxed)).into());
    }
    Ok(())
}
