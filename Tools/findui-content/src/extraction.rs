use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::hash_map::DefaultHasher,
    fs,
    hash::{Hash, Hasher},
    io::{self, Read, Write},
    os::fd::AsRawFd,
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering::Relaxed},
        Condvar, Mutex,
    },
    time::{Duration, Instant},
};
use tempfile::NamedTempFile;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Extraction {
    #[serde(default)]
    pub encoding: Option<String>,
    pub documents: bool,
    pub archives: bool,
    #[serde(default)]
    pub media: bool,
    #[serde(default)]
    pub ffmpeg: Option<PathBuf>,
    #[serde(default)]
    pub ffprobe: Option<PathBuf>,
    #[serde(default)]
    pub adapters: Vec<crate::adapters::Adapter>,
    pub cache_directory: Option<PathBuf>,
    pub max_depth: u32,
    pub max_megabytes: u64,
    pub timeout_seconds: u64,
    pub rga: Option<PathBuf>,
    pub pandoc: Option<PathBuf>,
    pub pdftotext: Option<PathBuf>,
    #[serde(default)]
    pub pdfdetach: Option<PathBuf>,
    pub tika_jar: Option<PathBuf>,
}
const MARKER: &str = ".findui-extracted-cache-v1";

// Plain text keeps the full search pool even when document support is enabled.
// Bound expensive converter processes separately, including JVMs.
static CONVERSIONS: (Mutex<usize>, Condvar) = (Mutex::new(0), Condvar::new());
static CONVERSION_LIMIT: AtomicUsize = AtomicUsize::new(4);
pub fn set_workers(workers: usize) {
    CONVERSION_LIMIT.store(workers.clamp(1, 4), Relaxed);
}
pub fn conversion_workers() -> usize {
    CONVERSION_LIMIT.load(Relaxed)
}
struct Conversion;
impl Conversion {
    fn acquire(stopped: &AtomicBool) -> io::Result<Self> {
        let mut active = CONVERSIONS.0.lock().unwrap();
        while *active >= conversion_workers() {
            if stopped.load(Relaxed) {
                return Err(io::Error::other("Extraction cancelled"));
            }
            active = CONVERSIONS
                .1
                .wait_timeout(active, Duration::from_millis(50))
                .unwrap()
                .0;
        }
        *active += 1;
        Ok(Self)
    }
}
impl Drop for Conversion {
    fn drop(&mut self) {
        *CONVERSIONS.0.lock().unwrap() -= 1;
        CONVERSIONS.1.notify_one();
    }
}

pub fn tika_lease(jar: Option<&Path>) -> io::Result<Option<fs::File>> {
    let Some(directory) = jar
        .and_then(Path::parent)
        .filter(|p| p.join("installed.json").is_file())
    else {
        return Ok(None);
    };
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(directory.join(".in-use"))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_SH | libc::LOCK_NB) } != 0 {
        return Err(io::Error::other(
            "This Tika version is being removed. Select an installed version and search again",
        ));
    }
    Ok(Some(file))
}

pub(crate) fn lock_file(path: &Path, stopped: &AtomicBool, seconds: u64) -> io::Result<fs::File> {
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)?;
    let start = Instant::now();
    loop {
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            return Ok(file);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::WouldBlock {
            return Err(error);
        }
        if stopped.load(Relaxed) || start.elapsed() > Duration::from_secs(seconds) {
            return Err(io::Error::other(
                "Cancelled or timed out waiting for the extraction cache",
            ));
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn prepare_cache(path: &Path) -> io::Result<()> {
    if !path.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(path)?;
    }
    if fs::symlink_metadata(path)?.file_type().is_symlink() {
        return Err(io::Error::other(
            "Cache directory must not be a symbolic link",
        ));
    }
    if !path.join(MARKER).exists() {
        // Serialize initialization separately from the shared search lease.
        // A second search must not mistake the first search's new files for an
        // unrelated directory, or wait for its entire search to finish.
        let init = path.parent().unwrap().join(format!(
            ".{}.findui-init",
            path.file_name().unwrap().to_string_lossy()
        ));
        let _init = lock_file(&init, &AtomicBool::new(false), 60)?;
        if !path.join(MARKER).exists() {
            if fs::read_dir(path)?.next().is_some() {
                return Err(io::Error::other(
                    "Choose an empty directory for the FindUI extraction cache",
                ));
            }
            let mut marker = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(path.join(MARKER))?;
            marker.write_all(b"FindUI extracted text cache; may contain full document text\n")?;
        }
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}
fn cache_lease(path: &Path, exclusive: bool) -> io::Result<fs::File> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("Cache path must have a parent"))?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(parent)?;
    let name = format!(
        ".{}.findui-lock",
        path.file_name().unwrap_or_default().to_string_lossy()
    );
    let file = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(parent.join(name))?;
    let operation = if exclusive {
        libc::LOCK_EX | libc::LOCK_NB
    } else {
        libc::LOCK_SH
    };
    if unsafe { libc::flock(file.as_raw_fd(), operation) } != 0 {
        return Err(io::Error::other(
            "Finish or cancel document searches before clearing their cache",
        ));
    }
    Ok(file)
}
pub fn lease_directory(path: &Path) -> io::Result<fs::File> {
    let lock = cache_lease(path, false)?;
    prepare_cache(path)?;
    Ok(lock)
}
pub fn cache_action(action: &str, path: &Path) -> io::Result<()> {
    if !path.exists() {
        println!("{}", json!({"path":path,"bytes":0}));
        return Ok(());
    }
    let _lease = cache_lease(path, action != "--cache-info")?;
    if fs::symlink_metadata(path)?.file_type().is_symlink() || !path.join(MARKER).is_file() {
        return Err(io::Error::other("This is not a FindUI extraction cache"));
    }
    fn size(path: &Path) -> io::Result<u64> {
        let meta = fs::symlink_metadata(path)?;
        if !meta.is_dir() {
            return Ok(meta.len());
        }
        fs::read_dir(path)?.try_fold(0, |n, entry| Ok(n + size(&entry?.path())?))
    }
    let bytes = size(path)?;
    fn retry(path: &Path) -> io::Result<u64> {
        if fs::symlink_metadata(path)?.is_dir() {
            return fs::read_dir(path)?.try_fold(0, |n, entry| Ok(n + retry(&entry?.path())?));
        }
        if path.file_name().is_some_and(|n| n == "failed.gz") {
            fs::remove_file(path)?;
            Ok(1)
        } else {
            Ok(0)
        }
    }
    let retried = if action == "--cache-retry" {
        retry(path)?
    } else {
        0
    };
    if action == "--cache-clear" {
        // Rename first: active readers may finish on the old directory, while a
        // new search creates a fresh cache. Never delete an arbitrary directory.
        let retired = tempfile::Builder::new()
            .prefix(".findui-retired-")
            .tempdir_in(path.parent().unwrap_or(Path::new(".")))?;
        fs::rename(path, retired.path().join("cache"))?;
    }
    println!(
        "{}",
        json!({"path":path,"bytes":bytes,"cleared":action == "--cache-clear","failuresCleared":retried})
    );
    Ok(())
}
impl Extraction {
    pub fn adapter(&self, format: &str) -> Option<&crate::adapters::Adapter> {
        self.adapters
            .iter()
            .find(|a| a.enabled && a.extensions.iter().any(|x| x == format))
    }
    pub fn format(&self, path: &Path) -> io::Result<String> {
        let extension = crate::formats::extension(path);
        if self.adapter(&extension).is_some() {
            Ok(extension)
        } else {
            crate::formats::detect_cached(path, self.cache_directory.as_deref())
        }
    }
    pub fn converts(&self, format: &str) -> bool {
        self.adapter(format).is_some()
            || (self.media && crate::media::recognizes(format))
            || (self.documents
                && crate::formats::document(format)
                && !crate::media::recognizes(format))
    }
    pub fn validate(&self) -> io::Result<()> {
        for adapter in &self.adapters {
            adapter.validate()?;
        }
        if !self.documents && !self.archives && !self.media && self.adapters.is_empty() {
            return Err(io::Error::other(
                "Select documents or archives, or omit extraction from the plan",
            ));
        }
        if self.max_depth > 10
            || !(1..=1024).contains(&self.max_megabytes)
            || !(1..=600).contains(&self.timeout_seconds)
        {
            return Err(io::Error::other(
                "Extraction limits: depth 0–10, size 1–1024 MiB, timeout 1–600 seconds",
            ));
        }
        Ok(())
    }
    pub fn lease(&self) -> io::Result<Option<fs::File>> {
        if let Some(path) = &self.cache_directory {
            let lease = cache_lease(path, false)?;
            prepare_cache(path)?;
            Ok(Some(lease))
        } else {
            Ok(None)
        }
    }
    pub fn config(&self) -> io::Result<String> {
        let mut hash = DefaultHasher::new();
        let mut options = serde_json::to_value(self)?;
        // Legacy plans may still contain rga, but it no longer adds a second
        // cache or converter process around Pandoc and libarchive.
        options.as_object_mut().unwrap().remove("rga");
        options.to_string().hash(&mut hash);
        let worker = std::env::current_exe()?;
        for path in [
            self.pandoc.as_ref(),
            self.pdftotext.as_ref(),
            self.pdfdetach.as_ref(),
            self.tika_jar.as_ref(),
            Some(&worker),
            self.ffmpeg.as_ref(),
            self.ffprobe.as_ref(),
        ]
        .into_iter()
        .flatten()
        {
            crate::content_index::identity(path, "converter-v1")
                .ok()
                .hash(&mut hash);
        }
        for adapter in &self.adapters {
            crate::content_index::identity(&adapter.executable, "adapter-v1")
                .ok()
                .hash(&mut hash);
        }
        crate::archive::version().hash(&mut hash);
        // A neighbouring SQLite WAL is relevant only for database-capable
        // readers. Plain text, archives and media cannot consume it.
        let family = if self.documents || self.adapters.iter().any(|a| a.enabled) {
            "structured-v5"
        } else {
            "structured-v5-files"
        };
        Ok(format!("{family}:{:x}", hash.finish()))
    }
}

/// Explicit Office-only parser list: no OCR parser, PDF OCR, model, server, or
/// network fetcher. Works with the supported Tika 3.x runnable application jar.
pub fn tika_stdin(jar: &Path) -> io::Result<()> {
    let _lease = tika_lease(Some(jar))?;
    let mut config = NamedTempFile::new()?;
    config.write_all(
        br#"<?xml version="1.0"?><properties><parsers>
<parser class="org.apache.tika.parser.microsoft.OfficeParser"/>
<parser class="org.apache.tika.parser.microsoft.ooxml.OOXMLParser"/>
<parser class="org.apache.tika.parser.microsoft.OldExcelParser"/>
<parser class="org.apache.tika.parser.odf.OpenDocumentParser"/>
<parser class="org.apache.tika.parser.microsoft.rtf.RTFParser"/>
</parsers></properties>"#,
    )?;
    let mut child = Command::new("/usr/bin/java")
        .args(["-Xmx512m", "-jar"])
        .arg(jar)
        .arg(format!("--config={}", config.path().display()))
        .arg("--xml")
        .stdin(Stdio::inherit())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;
    let parsed = labeled_office_text(
        io::BufReader::new(child.stdout.take().unwrap()),
        io::BufWriter::new(io::stdout()),
    );
    if parsed.is_err() {
        let _ = child.kill();
    }
    let status = child.wait()?;
    parsed?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("Tika exited with {status}")))
    }
}

/// One bounded converter invocation. Both text and metadata come from its
/// output, so a metadata query never launches a second parser for a document.
pub fn convert(
    command: &mut Command,
    e: &Extraction,
    stopped: &AtomicBool,
) -> io::Result<NamedTempFile> {
    let _slot = Conversion::acquire(stopped)?;
    let output = NamedTempFile::new()?;
    let diagnostics = NamedTempFile::new()?;
    let mut child = command
        .stdin(Stdio::null())
        .stdout(output.reopen()?)
        .stderr(diagnostics.reopen()?)
        .process_group(0)
        .spawn()?;
    let start = Instant::now();
    loop {
        let oversized = output.as_file().metadata()?.len() > e.max_megabytes * 1024 * 1024;
        if stopped.load(Relaxed)
            || oversized
            || start.elapsed() > Duration::from_secs(e.timeout_seconds)
        {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            let _ = child.wait();
            return Err(io::Error::new(
                if oversized {
                    io::ErrorKind::InvalidData
                } else {
                    io::ErrorKind::Interrupted
                },
                if oversized {
                    "Converted document exceeds the size limit"
                } else {
                    "Conversion cancelled or timed out"
                },
            ));
        }
        if let Some(status) = child.try_wait()? {
            let mut diagnostic = String::new();
            diagnostics
                .reopen()?
                .take(16 * 1024)
                .read_to_string(&mut diagnostic)?;
            if !status.success() {
                return Err(io::Error::new(
                    if status.code().is_some() {
                        io::ErrorKind::InvalidData
                    } else {
                        io::ErrorKind::Interrupted
                    },
                    format!("Document conversion failed: {}", diagnostic.trim()),
                ));
            }
            if !diagnostic.trim().is_empty() {
                eprintln!("findui-extraction: {}", diagnostic.trim());
            }
            return Ok(output);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

pub fn office_document(
    path: &Path,
    jar: &Path,
    e: &Extraction,
    stopped: &AtomicBool,
) -> io::Result<(
    String,
    std::collections::BTreeMap<String, String>,
    Vec<crate::documents::Location>,
)> {
    let mut config = NamedTempFile::new()?;
    config.write_all(
        br#"<?xml version="1.0"?><properties><parsers>
<parser class="org.apache.tika.parser.microsoft.OfficeParser"/>
<parser class="org.apache.tika.parser.microsoft.ooxml.OOXMLParser"/>
<parser class="org.apache.tika.parser.microsoft.OldExcelParser"/>
<parser class="org.apache.tika.parser.odf.OpenDocumentParser"/>
<parser class="org.apache.tika.parser.microsoft.rtf.RTFParser"/>
</parsers></properties>"#,
    )?;
    let xml = convert(
        Command::new("/usr/bin/java")
            .args(["-Xmx512m", "-jar"])
            .arg(jar)
            .arg(format!("--config={}", config.path().display()))
            .arg("--xml")
            .arg(path),
        e,
        stopped,
    )?;
    let mut text = Vec::new();
    let mut metadata = Default::default();
    let mut locations = Vec::new();
    office_xml(
        io::BufReader::new(xml.reopen()?),
        &mut text,
        true,
        &mut locations,
        &mut metadata,
    )?;
    Ok((
        String::from_utf8(text).map_err(io::Error::other)?,
        metadata,
        locations,
    ))
}

/// Preserve sheet/slide provenance exposed by Tika's XHTML. This converter is
/// also directly usable from a terminal: findui-content --tika-stdin APP.jar.
fn labeled_office_text(input: impl io::BufRead, mut output: impl Write) -> io::Result<()> {
    office_xml(
        input,
        &mut output,
        false,
        &mut Vec::new(),
        &mut Default::default(),
    )
}
fn office_xml<W: Write>(
    input: impl io::BufRead,
    mut output: W,
    structured: bool,
    locations: &mut Vec<crate::documents::Location>,
    metadata: &mut std::collections::BTreeMap<String, String>,
) -> io::Result<()> {
    use quick_xml::{events::Event, Reader};
    let mut reader = Reader::from_reader(input);
    let mut buffer = Vec::new();
    let mut body = false;
    let mut line = String::new();
    let mut divs = Vec::new();
    let mut sheet: Option<String> = None;
    let mut heading = false;
    let mut slide: Option<usize> = None;
    let mut slide_number = 0;
    let mut line_number = 1u64;
    let mut flush = |out: &mut W,
                     line: &mut String,
                     sheet: &Option<String>,
                     slide: Option<usize>|
     -> io::Result<()> {
        for text in line.lines().map(str::trim).filter(|s| !s.is_empty()) {
            if structured {
                locations.push(crate::documents::Location {
                    timecode: None,
                    line: line_number,
                    page: None,
                    sheet: sheet.clone(),
                    slide: slide.map(|n| n as u64),
                });
            } else {
                if let Some(sheet) = sheet {
                    write!(out, "Sheet {}: ", sheet.replace(['\r', '\n'], " "))?;
                }
                if let Some(slide) = slide {
                    write!(out, "Slide {slide}: ")?;
                }
            }
            writeln!(out, "{text}")?;
            line_number += 1;
        }
        line.clear();
        Ok(())
    };
    loop {
        match reader
            .read_event_into(&mut buffer)
            .map_err(io::Error::other)?
        {
            Event::Empty(event) if !body && event.local_name().as_ref() == b"meta" => {
                let attrs: std::collections::BTreeMap<String, String> = event
                    .attributes()
                    .flatten()
                    .map(|a| {
                        (
                            String::from_utf8_lossy(a.key.as_ref()).into_owned(),
                            a.unescape_value().unwrap_or_default().into_owned(),
                        )
                    })
                    .collect();
                if let (Some(name), Some(value)) = (attrs.get("name"), attrs.get("content")) {
                    let field = match name.to_ascii_lowercase().as_str() {
                        "dc:title" | "title" => Some("title"),
                        "dc:creator" | "creator" | "author" | "meta:author" => Some("author"),
                        _ => None,
                    };
                    if let Some(field) = field {
                        if !value.is_empty() {
                            metadata.entry(field.into()).or_insert(value.clone());
                        }
                    }
                }
            }
            Event::Start(event) => {
                let tag = event.local_name();
                if tag.as_ref() == b"body" {
                    body = true;
                }
                if !body {
                    continue;
                }
                if tag.as_ref() == b"div" {
                    let class = event
                        .attributes()
                        .filter_map(Result::ok)
                        .find(|a| a.key.as_ref() == b"class")
                        .map(|a| String::from_utf8_lossy(&a.value).into_owned())
                        .unwrap_or_default();
                    if class == "sheet" {
                        flush(&mut output, &mut line, &sheet, slide)?;
                        sheet = Some(String::new());
                    }
                    if class == "slide-content" {
                        flush(&mut output, &mut line, &sheet, slide)?;
                        slide_number += 1;
                        slide = Some(slide_number);
                    }
                    divs.push(class);
                }
                if tag.as_ref() == b"h1" && sheet.is_some() {
                    heading = true;
                }
            }
            Event::Text(event) if body => {
                let decoded = event.decode().map_err(io::Error::other)?;
                let value = quick_xml::escape::unescape(&decoded).map_err(io::Error::other)?;
                if heading {
                    sheet.as_mut().unwrap().push_str(&value);
                } else {
                    line.push_str(&value);
                }
            }
            Event::GeneralRef(event) if body => {
                let name = event.decode().map_err(io::Error::other)?;
                let raw = format!("&{name};");
                let value = quick_xml::escape::unescape(&raw).map_err(io::Error::other)?;
                if heading {
                    sheet.as_mut().unwrap().push_str(&value);
                } else {
                    line.push_str(&value);
                }
            }
            Event::End(event) if body => {
                let tag = event.local_name();
                if tag.as_ref() == b"h1" && heading {
                    heading = false;
                } else if [b"p".as_slice(), b"tr", b"h1", b"h2", b"h3", b"li"]
                    .contains(&tag.as_ref())
                {
                    flush(&mut output, &mut line, &sheet, slide)?;
                }
                if tag.as_ref() == b"td" {
                    line.push('\t');
                }
                if tag.as_ref() == b"div" {
                    flush(&mut output, &mut line, &sheet, slide)?;
                    match divs.pop().as_deref() {
                        Some("sheet") => sheet = None,
                        Some("slide-content") => slide = None,
                        _ => {}
                    }
                }
                if tag.as_ref() == b"body" {
                    flush(&mut output, &mut line, &sheet, slide)?;
                    body = false;
                }
            }
            Event::Empty(event) if body && event.local_name().as_ref() == b"br" => {
                flush(&mut output, &mut line, &sheet, slide)?;
            }
            Event::DocType(_) => return Err(io::Error::other("Unexpected DTD in Tika output")),
            Event::Eof => break,
            _ => {}
        }
        buffer.clear();
    }
    output.flush()
}
