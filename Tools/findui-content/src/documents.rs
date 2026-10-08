use crate::{
    archive,
    content_index::{Cache, Signature},
    extraction::Extraction,
};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        OnceLock,
    },
    time::{Duration, Instant},
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Member {
    pub name: String,
    pub index: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}
#[derive(Clone, Default, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Location {
    pub line: u64,
    pub page: Option<u64>,
    pub sheet: Option<String>,
    pub slide: Option<u64>,
    #[serde(default)]
    pub timecode: Option<String>,
}
#[derive(Clone, Default, Debug, Serialize, Deserialize)]
pub struct Document {
    pub members: Vec<Member>,
    pub text: String,
    pub metadata: BTreeMap<String, String>,
    pub locations: Vec<Location>,
}
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Bundle {
    pub documents: Vec<Document>,
    pub warnings: Vec<String>,
    #[serde(default)]
    pub incomplete: bool,
    /// Cancellation, timeouts and I/O failures must not become persistent misses.
    #[serde(default)]
    pub retryable: bool,
    #[serde(skip)]
    pub member_cache_hits: u64,
}

pub fn zip_names(path: &Path, stopped: &AtomicBool, timeout: u64) -> io::Result<Bundle> {
    let names =
        archive::Reader::zip_names(path, stopped, Instant::now() + Duration::from_secs(timeout))?;
    Ok(Bundle {
        documents: names
            .into_iter()
            .map(|(index, name, directory)| Document {
                members: vec![Member {
                    name,
                    index,
                    kind: None,
                }],
                metadata: [
                    ("finduiNameOnly".into(), "true".into()),
                    (
                        "finduiMemberKind".into(),
                        if directory { "directory" } else { "file" }.into(),
                    ),
                ]
                .into(),
                ..Default::default()
            })
            .collect(),
        ..Default::default()
    })
}

pub fn is_document(path: &Path) -> bool {
    crate::formats::document(&crate::formats::extension(path))
}

/// Selection is evaluated before member data is inflated. Unknown container
/// descendants remain candidates. The predicate never decides a text match.
pub type Selection<'a> = dyn Fn(&[Member]) -> bool + Sync + 'a;
struct Context<'a> {
    source: &'a Path,
    format: Option<&'a str>,
    metadata: fs::Metadata,
    selection: Option<&'a Selection<'a>>,
    expanded: AtomicU64,
    text: AtomicU64,
}
impl Context<'_> {
    fn reserve(budget: &AtomicU64, amount: u64) -> io::Result<()> {
        budget
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |left| {
                left.checked_sub(amount)
            })
            .map(|_| ())
            .map_err(|_| {
                io::Error::other(
                    "Archive expansion or extracted text exceeds the configured total size limit",
                )
            })
    }
    fn cache(&self, members: &[Member], e: &Extraction, config: &str) -> Option<Cache> {
        let root = e.cache_directory.as_ref()?.join("structured-members-v1");
        if !crate::content_index::cacheable(&self.metadata) {
            return None;
        }
        let key = PathBuf::from(format!(
            "{}\0{}",
            self.source.display(),
            members
                .iter()
                .map(|m| m.index.to_string())
                .collect::<Vec<_>>()
                .join("/")
        ));
        Some(Cache::from_metadata(&root, &key, config, &self.metadata))
    }
}
pub fn extract(
    path: &Path,
    extraction: &Extraction,
    config: &str,
    stopped: &AtomicBool,
) -> io::Result<Bundle> {
    extract_selected(path, extraction, config, stopped, None)
}
pub fn extract_selected(
    path: &Path,
    e: &Extraction,
    config: &str,
    stopped: &AtomicBool,
    selection: Option<&Selection<'_>>,
) -> io::Result<Bundle> {
    extract_selected_as(path, e, config, stopped, selection, None)
}
pub fn extract_selected_as(
    path: &Path,
    e: &Extraction,
    config: &str,
    stopped: &AtomicBool,
    selection: Option<&Selection<'_>>,
    format: Option<&str>,
) -> io::Result<Bundle> {
    let mut result = Bundle::default();
    let context = Context {
        source: path,
        format,
        metadata: fs::metadata(path)?,
        selection,
        expanded: AtomicU64::new(e.max_megabytes * 1024 * 1024),
        text: AtomicU64::new(e.max_megabytes * 1024 * 1024),
    };
    if let Err(error) = visit(
        path,
        Vec::new(),
        e,
        config,
        stopped,
        Instant::now() + Duration::from_secs(e.timeout_seconds),
        0,
        &context,
        &mut result,
    ) {
        result.retryable |= !matches!(
            error.kind(),
            io::ErrorKind::InvalidData | io::ErrorKind::Unsupported
        );
        result.warnings.push(error.to_string());
    }
    Ok(result)
}
struct Job {
    file: tempfile::NamedTempFile,
    members: Vec<Member>,
}
fn merge(target: &mut Bundle, mut source: Bundle) {
    target.documents.append(&mut source.documents);
    target.warnings.append(&mut source.warnings);
    target.incomplete |= source.incomplete;
    target.retryable |= source.retryable;
    target.member_cache_hits += source.member_cache_hits;
}
static MEMBERS: OnceLock<rayon::ThreadPool> = OnceLock::new();
#[allow(clippy::too_many_arguments)]
fn convert_jobs(
    jobs: &mut Vec<Job>,
    e: &Extraction,
    config: &str,
    stopped: &AtomicBool,
    deadline: Instant,
    depth: u32,
    context: &Context<'_>,
    out: &mut Bundle,
) {
    let convert = |job: Job| {
        let mut result = Bundle::default();
        let cache = context.cache(&job.members, e, config);
        let lock = cache.as_ref().and_then(|c| c.lock(stopped).ok());
        if lock.is_some() {
            if let Some(mut saved) = cache
                .as_ref()
                .and_then(|c| c.bundle(e.max_megabytes * 1024 * 1024))
            {
                let size = saved.documents.iter().map(|d| d.text.len() as u64).sum();
                if let Err(error) = Context::reserve(&context.text, size) {
                    result.warnings.push(error.to_string());
                    return result;
                }
                saved.member_cache_hits += 1;
                return saved;
            }
        }
        if let Err(error) = visit(
            job.file.path(),
            job.members,
            e,
            config,
            stopped,
            deadline,
            depth + 1,
            context,
            &mut result,
        ) {
            result.retryable |= !matches!(
                error.kind(),
                io::ErrorKind::InvalidData | io::ErrorKind::Unsupported
            );
            result.warnings.push(error.to_string());
        }
        if !result.incomplete && !stopped.load(Ordering::Relaxed) && lock.is_some() {
            if let Some(cache) = cache {
                // A changed source must never publish member data under its old identity.
                if crate::content_index::identity(context.source, config)
                    .ok()
                    .as_deref()
                    == Some(&cache.identity)
                {
                    let saved = if result.warnings.is_empty() {
                        cache.save(Signature::bundle(&result), Some(&result))
                    } else {
                        cache.remember_failure(&result)
                    };
                    if let Err(error) = saved {
                        eprintln!("findui-cache: {error}");
                    }
                }
            }
        }
        result
    };
    // Parallelize the outer archive; nested archives reuse these workers and
    // cannot recursively create more threads or hold an unbounded job queue.
    let batch = std::mem::take(jobs);
    let results: Vec<_> = if depth == 0 {
        MEMBERS
            .get_or_init(|| {
                rayon::ThreadPoolBuilder::new()
                    .num_threads(crate::extraction::conversion_workers())
                    .build()
                    .expect("member workers")
            })
            .install(|| batch.into_par_iter().map(convert).collect())
    } else {
        batch.into_iter().map(convert).collect()
    };
    for result in results {
        merge(out, result);
    }
}
#[allow(clippy::too_many_arguments)]
fn visit(
    path: &Path,
    members: Vec<Member>,
    e: &Extraction,
    config: &str,
    stopped: &AtomicBool,
    deadline: Instant,
    depth: u32,
    context: &Context<'_>,
    out: &mut Bundle,
) -> io::Result<()> {
    if stopped.load(Ordering::Relaxed) || Instant::now() > deadline {
        return Err(io::Error::other("Document search cancelled or timed out"));
    }
    let ext = if depth == 0 {
        context.format.map(str::to_owned)
    } else {
        None
    }
    .map(Ok)
    .unwrap_or_else(|| e.format(path))?;
    let detected_archive = archive::is_format(&ext) && e.adapter(&ext).is_none();
    if detected_archive {
        if !e.archives {
            return Ok(());
        }
        if depth >= e.max_depth {
            out.warnings
                .push("Maximum archive nesting depth reached".into());
            return Ok(());
        }
        let cached = std::cell::RefCell::new(Vec::new());
        let partial = std::cell::Cell::new(false);
        let mut jobs = Vec::new();
        let result = archive::Reader::open(path)?.visit_search(
            e.max_megabytes * 1024 * 1024,
            stopped,
            deadline,
            |index, name| {
                let mut chain = members.clone();
                chain.push(Member {
                    name: name.into(),
                    index,
                    kind: None,
                });
                // Containers can hold matching descendants even if their own name
                // does not match. Raw streams get their logical name after reading.
                if name != "data"
                    && !archive::is_archive(Path::new(name))
                    && context.selection.is_some_and(|select| !select(&chain))
                {
                    partial.set(true);
                    return false;
                }
                if let Some(mut bundle) = context
                    .cache(&chain, e, config)
                    .and_then(|c| c.bundle(e.max_megabytes * 1024 * 1024))
                {
                    let size = bundle.documents.iter().map(|d| d.text.len() as u64).sum();
                    if Context::reserve(&context.text, size).is_ok() {
                        bundle.member_cache_hits += 1;
                        cached.borrow_mut().push(bundle);
                        return false;
                    }
                }
                true
            },
            |index, name, bytes, raw| {
                Context::reserve(&context.expanded, bytes.len() as u64)?;
                let logical_path = members.last().map(|m| Path::new(&m.name)).unwrap_or(path);
                let name = if raw {
                    logical_path
                        .file_stem()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .into_owned()
                } else {
                    name
                };
                let mut suffix = Path::new(&name)
                    .extension()
                    .map(|s| format!(".{}", s.to_string_lossy()))
                    .unwrap_or_default();
                if !is_document(Path::new(&name)) && !archive::is_archive(Path::new(&name)) {
                    if let Some(ext) = archive::nested_extension(&bytes) {
                        suffix = format!(".{ext}");
                    }
                }
                let mut file = tempfile::Builder::new()
                    .prefix("findui-member-")
                    .suffix(&suffix)
                    .tempfile()?;
                file.write_all(&bytes)?;
                let mut nested = members.clone();
                nested.push(Member {
                    name,
                    index,
                    kind: None,
                });
                jobs.push(Job {
                    file,
                    members: nested,
                });
                if jobs.len() == 4 {
                    convert_jobs(&mut jobs, e, config, stopped, deadline, depth, context, out);
                }
                Ok(true)
            },
        );
        convert_jobs(&mut jobs, e, config, stopped, deadline, depth, context, out);
        for bundle in cached.into_inner() {
            merge(out, bundle);
        }
        out.incomplete |= partial.get();
        if let Err(error) = result {
            out.retryable |= !matches!(
                error.kind(),
                io::ErrorKind::InvalidData | io::ErrorKind::Unsupported
            );
            out.warnings.push(error.to_string());
        }
        return Ok(());
    }
    if crate::readers::for_format(&ext) == Some(crate::readers::Reader::Mail) {
        let mut bytes = Vec::new();
        fs::File::open(path)?
            .take(e.max_megabytes * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > e.max_megabytes * 1024 * 1024 {
            return Err(io::Error::other(
                "Mailbox exceeds the configured size limit",
            ));
        }
        let (documents, files) = crate::mail_reader::read(&bytes, &ext, &members, e.archives)?;
        if e.documents {
            for document in documents {
                Context::reserve(&context.text, document.text.len() as u64)?;
                out.documents.push(document);
            }
        }
        let mut jobs = Vec::new();
        if !files.is_empty() && depth >= e.max_depth {
            out.warnings
                .push("Maximum attachment nesting depth reached".into());
            return Ok(());
        }
        for attachment in files {
            let mut chain = members.clone();
            chain.push(attachment.member);
            if context.selection.is_some_and(|select| !select(&chain))
                && !archive::is_archive(Path::new(&chain.last().unwrap().name))
                && archive::nested_extension(&attachment.bytes).is_none()
            {
                out.incomplete = true;
                continue;
            }
            Context::reserve(&context.expanded, attachment.bytes.len() as u64)?;
            let suffix = Path::new(&chain.last().unwrap().name)
                .extension()
                .map(|s| format!(".{}", s.to_string_lossy()))
                .unwrap_or_default();
            let mut file = tempfile::Builder::new().suffix(&suffix).tempfile()?;
            file.write_all(&attachment.bytes)?;
            jobs.push(Job {
                file,
                members: chain,
            });
            if jobs.len() == 4 {
                convert_jobs(&mut jobs, e, config, stopped, deadline, depth, context, out);
            }
        }
        convert_jobs(&mut jobs, e, config, stopped, deadline, depth, context, out);
        return Ok(());
    }
    if ext == "pdf" && e.archives {
        if let Err(error) = pdf_attachments(
            path, &members, e, config, stopped, deadline, depth, context, out,
        ) {
            out.retryable |= !matches!(
                error.kind(),
                io::ErrorKind::InvalidData | io::ErrorKind::Unsupported
            );
            out.warnings.push(error.to_string());
        }
    }
    if e.adapter(&ext).is_some() || (e.media && crate::media::recognizes(&ext)) {
        let mut bundle = if let Some(adapter) = e.adapter(&ext) {
            adapter.read(path, e, stopped)?
        } else {
            crate::media::read(path, e, stopped, deadline)?
        };
        for doc in &mut bundle.documents {
            doc.members = members.clone();
        }
        Context::reserve(
            &context.text,
            bundle.documents.iter().map(|d| d.text.len() as u64).sum(),
        )?;
        merge(out, bundle);
        return Ok(());
    }
    if crate::media::recognizes(&ext) {
        return Ok(());
    }
    if crate::formats::document(&ext) && !e.documents {
        return Ok(());
    }
    if crate::readers::for_format(&ext) == Some(crate::readers::Reader::Sqlite) {
        let bundle = crate::database_reader::read(
            path,
            &members,
            context.text.load(Ordering::Relaxed),
            deadline,
            stopped,
        )?;
        Context::reserve(
            &context.text,
            bundle.documents.iter().map(|d| d.text.len() as u64).sum(),
        )?;
        merge(out, bundle);
        return Ok(());
    }
    let mut doc = Document {
        members,
        ..Default::default()
    };
    if crate::readers::for_format(&ext) == Some(crate::readers::Reader::Office) {
        let jar = e
            .tika_jar
            .as_deref()
            .ok_or_else(|| io::Error::other("Download and select Tika in Settings → Tools"))?;
        let (text, metadata, locations) =
            crate::extraction::office_document(path, jar, e, stopped)?;
        doc.text = text;
        doc.metadata = metadata;
        doc.locations = locations;
    } else if crate::readers::for_format(&ext) == Some(crate::readers::Reader::Pdf) {
        let converter = e.pdftotext.as_ref().ok_or_else(|| {
            io::Error::other("Install PDF support in Settings → Tools: brew install poppler")
        })?;
        let converted = crate::extraction::convert(
            std::process::Command::new(converter)
                .arg("-htmlmeta")
                .arg(path)
                .arg("-"),
            e,
            stopped,
        )?;
        let text = fs::read_to_string(converted.path())?;
        let (body, metadata) = html_text(&text)?;
        doc.metadata = metadata;
        let mut page = 1;
        let mut line = 1;
        for part in body.split('\u{c}') {
            doc.locations.push(Location {
                line,
                page: Some(page),
                ..Default::default()
            });
            doc.text.push_str(part);
            if !part.ends_with('\n') {
                doc.text.push('\n');
            }
            line += part.bytes().filter(|b| *b == b'\n').count() as u64
                + u64::from(!part.ends_with('\n'));
            page += 1;
        }
    } else {
        let mut bytes = Vec::new();
        if crate::formats::document(&ext) {
            let converter = e.pandoc.as_ref().ok_or_else(|| {
                io::Error::other(
                    "Install document support in Settings → Tools: brew install pandoc",
                )
            })?;
            let format = if ext == "htm" { "html" } else { ext.as_str() };
            let file = crate::extraction::convert(
                std::process::Command::new(converter)
                    .arg("--from")
                    .arg(format)
                    .args(["--to=plain", "--wrap=none", "--"])
                    .arg(path),
                e,
                stopped,
            )?;
            file.reopen()?.read_to_end(&mut bytes)?;
        } else {
            fs::File::open(path)?
                .take(e.max_megabytes * 1024 * 1024 + 1)
                .read_to_end(&mut bytes)?;
        }
        if bytes.len() as u64 > e.max_megabytes * 1024 * 1024 {
            return Err(io::Error::other(
                "Extracted text exceeds the configured size limit",
            ));
        }
        let decoded = if let Some(label) = e
            .encoding
            .as_deref()
            .filter(|s| *s != "auto" && !s.is_empty() && !crate::formats::document(&ext))
        {
            let encoding = encoding_rs::Encoding::for_label(label.as_bytes())
                .ok_or_else(|| io::Error::other("Unknown text encoding"))?;
            Some(encoding.decode(&bytes).0.into_owned())
        } else {
            decode_text(&bytes)
        };
        let Some(text) = decoded else { return Ok(()) };
        doc.text = text;
        if matches!(ext.as_str(), "docx" | "odt" | "epub") {
            match package_metadata(path, stopped, deadline) {
                Ok(value) => doc.metadata = value,
                Err(error) => {
                    out.retryable |= !matches!(
                        error.kind(),
                        io::ErrorKind::InvalidData | io::ErrorKind::Unsupported
                    );
                    out.warnings
                        .push(format!("Could not read document metadata: {error}"));
                }
            }
        }
    }
    Context::reserve(&context.text, doc.text.len() as u64)?;
    if crate::formats::document(&ext) {
        doc.metadata
            .insert("finduiRequiresDocuments".into(), "true".into());
    }
    out.documents.push(doc);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn pdf_attachments(
    path: &Path,
    members: &[Member],
    e: &Extraction,
    config: &str,
    stopped: &AtomicBool,
    deadline: Instant,
    depth: u32,
    context: &Context<'_>,
    out: &mut Bundle,
) -> io::Result<()> {
    let converter = e
        .pdfdetach
        .clone()
        .or_else(|| e.pdftotext.as_ref().map(|p| p.with_file_name("pdfdetach")))
        .filter(|p| p.is_file())
        .ok_or_else(|| io::Error::other("PDF attachments require Poppler: brew install poppler"))?;
    let list = crate::extraction::convert(
        std::process::Command::new(&converter)
            .args(["-list", "-enc", "UTF-8"])
            .arg(path),
        e,
        stopped,
    )?;
    let listing = fs::read_to_string(list.path())?;
    let count: usize = listing
        .split_whitespace()
        .next()
        .and_then(|n| n.parse().ok())
        .ok_or_else(|| io::Error::other("Cannot read PDF attachment directory"))?;
    if count > 100_000 {
        return Err(io::Error::other("PDF exceeds 100,000 attachments"));
    }
    if count > 0 && depth >= e.max_depth {
        return Err(io::Error::other("Maximum attachment nesting depth reached"));
    }
    let mut jobs = Vec::new();
    for index in 1..=count {
        let prefix = format!("{index}: ");
        let name = listing
            .lines()
            .find_map(|l| l.strip_prefix(&prefix))
            .map(str::to_owned)
            .unwrap_or_else(|| format!("attachment-{index}"));
        let mut chain = members.to_vec();
        chain.push(Member {
            name: name.clone(),
            index: index as u64,
            kind: Some("pdf".into()),
        });
        if !archive::is_archive(Path::new(&name))
            && context.selection.is_some_and(|select| !select(&chain))
        {
            out.incomplete = true;
            continue;
        }
        let file = crate::extraction::convert(
            std::process::Command::new(&converter)
                .arg("-save")
                .arg(index.to_string())
                .args(["-o", "/dev/stdout"])
                .arg(path),
            e,
            stopped,
        )?;
        Context::reserve(&context.expanded, file.as_file().metadata()?.len())?;
        jobs.push(Job {
            file,
            members: chain,
        });
        if jobs.len() == 4 {
            convert_jobs(&mut jobs, e, config, stopped, deadline, depth, context, out);
        }
    }
    convert_jobs(&mut jobs, e, config, stopped, deadline, depth, context, out);
    Ok(())
}

fn decode_text(bytes: &[u8]) -> Option<String> {
    if bytes.starts_with(&[0xff, 0xfe]) || bytes.starts_with(&[0xfe, 0xff]) {
        let little = bytes[0] == 0xff;
        return Some(String::from_utf16_lossy(
            &bytes[2..]
                .chunks_exact(2)
                .map(|p| {
                    if little {
                        u16::from_le_bytes([p[0], p[1]])
                    } else {
                        u16::from_be_bytes([p[0], p[1]])
                    }
                })
                .collect::<Vec<_>>(),
        ));
    }
    if bytes.contains(&0) {
        return None;
    }
    Some(String::from_utf8_lossy(bytes).into_owned())
}

fn html_text(xml: &str) -> io::Result<(String, BTreeMap<String, String>)> {
    use quick_xml::{events::Event, Reader};
    let mut reader = Reader::from_str(xml);
    reader.config_mut().check_end_names = false;
    let mut body = false;
    let mut title = false;
    let mut text = String::new();
    let mut metadata = BTreeMap::new();
    loop {
        match reader.read_event().map_err(io::Error::other)? {
            Event::Start(e) | Event::Empty(e) => match e.local_name().as_ref() {
                b"body" => body = true,
                b"title" => title = true,
                b"meta" => {
                    let attrs: BTreeMap<String, String> = e
                        .attributes()
                        .flatten()
                        .map(|a| {
                            (
                                String::from_utf8_lossy(a.key.as_ref()).to_lowercase(),
                                a.unescape_value().unwrap_or_default().into_owned(),
                            )
                        })
                        .collect();
                    if let (Some(key), Some(value)) = (attrs.get("name"), attrs.get("content")) {
                        if key.eq_ignore_ascii_case("author") || key.eq_ignore_ascii_case("title") {
                            metadata.insert(key.to_lowercase(), value.clone());
                        }
                    }
                }
                _ => {}
            },
            Event::Text(e) => {
                let raw = e.decode().map_err(io::Error::other)?;
                let value = quick_xml::escape::unescape(&raw).map_err(io::Error::other)?;
                if body {
                    text.push_str(&value);
                } else if title {
                    metadata
                        .entry("title".into())
                        .or_insert_with(String::new)
                        .push_str(&value);
                }
            }
            Event::GeneralRef(e) => {
                if body || title {
                    let raw = e.decode().map_err(io::Error::other)?;
                    let wrapped = format!("&{raw};");
                    let value = quick_xml::escape::unescape(&wrapped).map_err(io::Error::other)?;
                    if body {
                        text.push_str(&value);
                    } else {
                        metadata
                            .entry("title".into())
                            .or_insert_with(String::new)
                            .push_str(&value);
                    }
                }
            }
            Event::End(e) => match e.local_name().as_ref() {
                b"body" => body = false,
                b"title" => title = false,
                _ => {}
            },
            Event::Eof => break,
            _ => {}
        }
    }
    Ok((text, metadata))
}

fn package_metadata(
    path: &Path,
    stopped: &AtomicBool,
    deadline: Instant,
) -> io::Result<BTreeMap<String, String>> {
    let mut metadata = BTreeMap::new();
    archive::Reader::open(path)?.visit_selected(
        8 * 1024 * 1024,
        stopped,
        deadline,
        |_, name| name == "docProps/core.xml" || name == "meta.xml" || name.ends_with(".opf"),
        |_, name, bytes, _| {
            if name == "docProps/core.xml" || name == "meta.xml" || name.ends_with(".opf") {
                use quick_xml::{events::Event, Reader};
                let mut reader = Reader::from_reader(bytes.as_slice());
                let mut field = None;
                loop {
                    match reader.read_event().map_err(io::Error::other)? {
                        Event::Start(e) => {
                            field = match e.local_name().as_ref() {
                                b"title" => Some("title"),
                                b"creator" | b"initial-creator" => Some("author"),
                                _ => None,
                            }
                        }
                        Event::Text(e) => {
                            if let Some(field) = field {
                                let raw = e.decode().map_err(io::Error::other)?;
                                let value =
                                    quick_xml::escape::unescape(&raw).map_err(io::Error::other)?;
                                metadata
                                    .entry(field.into())
                                    .or_insert_with(String::new)
                                    .push_str(&value);
                            }
                        }
                        Event::GeneralRef(e) => {
                            if let Some(field) = field {
                                let raw = e.decode().map_err(io::Error::other)?;
                                let wrapped = format!("&{raw};");
                                let value = quick_xml::escape::unescape(&wrapped)
                                    .map_err(io::Error::other)?;
                                metadata
                                    .entry(field.into())
                                    .or_insert_with(String::new)
                                    .push_str(&value);
                            }
                        }
                        Event::End(_) => field = None,
                        Event::Eof => break,
                        _ => {}
                    }
                }
            }
            Ok(true)
        },
    )?;
    Ok(metadata)
}

/// Materialize only the selected member into a private temporary file. Numeric
/// member indexes disambiguate duplicate names and names containing separators.
pub fn materialize(
    path: &Path,
    members: &[Member],
    limit: u64,
    stopped: &AtomicBool,
    extraction: &Extraction,
) -> io::Result<tempfile::NamedTempFile> {
    let mut source = path.to_path_buf();
    let mut held = Vec::new();
    for member in members {
        let suffix = Path::new(&member.name)
            .extension()
            .map(|s| format!(".{}", s.to_string_lossy()))
            .unwrap_or_default();
        if member.kind.as_deref() == Some("mail") {
            let bytes = crate::mail_reader::attachment(&source, member, limit)?;
            let mut file = tempfile::Builder::new()
                .prefix("findui-open-")
                .suffix(&suffix)
                .tempfile()?;
            file.write_all(&bytes)?;
            source = file.path().into();
            held.push(file);
            continue;
        }
        if member.kind.as_deref() == Some("pdf") {
            let converter = extraction
                .pdfdetach
                .clone()
                .or_else(|| {
                    extraction
                        .pdftotext
                        .as_ref()
                        .map(|p| p.with_file_name("pdfdetach"))
                })
                .ok_or_else(|| io::Error::other("Install Poppler to open PDF attachments"))?;
            let converted = crate::extraction::convert(
                std::process::Command::new(converter)
                    .arg("-save")
                    .arg(member.index.to_string())
                    .args(["-o", "/dev/stdout"])
                    .arg(&source),
                extraction,
                stopped,
            )?;
            if converted.as_file().metadata()?.len() > limit {
                return Err(io::Error::other(
                    "PDF attachment exceeds the configured size limit",
                ));
            }
            let mut file = tempfile::Builder::new()
                .prefix("findui-open-")
                .suffix(&suffix)
                .tempfile()?;
            io::copy(&mut fs::File::open(converted.path())?, file.as_file_mut())?;
            source = file.path().into();
            held.push(file);
            continue;
        }
        let mut found = None;
        archive::Reader::open(&source)?.visit_selected(
            limit,
            stopped,
            Instant::now() + Duration::from_secs(60),
            |index, _| index == member.index,
            |index, name, bytes, _| {
                if index == member.index {
                    if name != member.name && name != "data" {
                        return Err(io::Error::other(
                            "Archive changed since this result; search again",
                        ));
                    }
                    let suffix = Path::new(&member.name)
                        .extension()
                        .map(|s| format!(".{}", s.to_string_lossy()))
                        .unwrap_or_default();
                    let mut file = tempfile::Builder::new()
                        .prefix("findui-open-")
                        .suffix(&suffix)
                        .tempfile()?;
                    file.write_all(&bytes)?;
                    found = Some(file);
                }
                Ok(false)
            },
        )?;
        let file =
            found.ok_or_else(|| io::Error::other("Archive member is no longer available"))?;
        source = file.path().to_path_buf();
        held.push(file);
    }
    held.pop()
        .ok_or_else(|| io::Error::other("Choose an archive member"))
}
