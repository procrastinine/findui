//! One typed capability catalog for recognition, diagnostics and native Settings.
use crate::extraction::Extraction;
use serde::Serialize;
#[derive(Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Reader {
    Pdf,
    Pandoc,
    Office,
    Mail,
    Sqlite,
    Archive,
    Media,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capability {
    pub id: String,
    pub title: String,
    pub formats: Vec<String>,
    pub option: &'static str,
    pub dependency: String,
    pub ready: bool,
    pub command: Option<&'static str>,
}
impl Reader {
    pub fn formats(self) -> &'static [&'static str] {
        match self {
            Self::Media => crate::media::FORMATS,
            Self::Pdf => &["pdf"],
            Self::Pandoc => &["docx", "odt", "epub", "fb2", "ipynb", "html", "htm"],
            Self::Office => &[
                "doc", "xls", "xlsx", "xlsm", "ppt", "pptx", "pptm", "ods", "odp", "rtf",
            ],
            Self::Mail => &["eml", "mbox"],
            Self::Sqlite => &["sqlite", "sqlite3", "db"],
            Self::Archive => &[
                "zip", "jar", "tar", "gz", "bz2", "xz", "zst", "tgz", "tbz2", "txz", "7z", "rar",
                "cpio", "xar", "iso", "cab", "pkg", "whl", "deb", "rpm",
            ],
        }
    }
}
pub fn for_format(format: &str) -> Option<Reader> {
    [
        Reader::Pdf,
        Reader::Pandoc,
        Reader::Office,
        Reader::Mail,
        Reader::Sqlite,
        Reader::Media,
    ]
    .into_iter()
    .find(|r| r.formats().contains(&format))
}
pub fn catalog(e: &Extraction) -> Vec<Capability> {
    use Reader::*;
    let mut result: Vec<_> = [
        (
            Pdf,
            "PDF text",
            "Poppler",
            e.pdftotext.as_ref().is_some_and(|p| p.is_file()),
            Some("brew install poppler"),
        ),
        (
            Pandoc,
            "DOCX, ODT and e-books",
            "Pandoc",
            e.pandoc.as_ref().is_some_and(|p| p.is_file()),
            Some("brew install pandoc"),
        ),
        (
            Office,
            "Office documents",
            "Tika",
            e.tika_jar.as_ref().is_some_and(|p| p.is_file()),
            None,
        ),
        (
            Mail,
            "Email and mailboxes",
            "Included · mailparse",
            true,
            None,
        ),
        (Sqlite, "SQLite tables", "Included · SQLite", true, None),
        (Media, "Media metadata and subtitles", "FFmpeg", e.ffmpeg.as_ref().is_some_and(|p| p.is_file()) && e.ffprobe.as_ref().is_some_and(|p| p.is_file()), Some("brew install ffmpeg")),
        (
            Archive,
            "Archives and packages",
            "Included · rawzip / libarchive",
            true,
            None,
        ),
    ]
    .into_iter()
    .map(|(id, title, dependency, ready, command)| Capability {
        id: serde_json::to_value(id).unwrap().as_str().unwrap().into(),
        title: title.into(),
        formats: id.formats().iter().map(|s| s.to_string()).collect(),
        option: if id == Archive {
            "archives"
        } else if id == Media { "media" } else {
            "documents"
        },
        dependency: dependency.into(),
        ready,
        command,
    })
    .collect();
    for adapter in &e.adapters {
        result.push(Capability { id: adapter.id.clone(), title: adapter.title.clone(), formats: adapter.extensions.clone(),
            option: "customReaders", dependency: adapter.executable.display().to_string(), ready: adapter.executable.is_file(), command: None });
    }
    result
}
pub fn run(json: &str) -> Result<(), Box<dyn std::error::Error>> {
    let e: Extraction = serde_json::from_str(json)?;
    println!("{}", serde_json::to_string(&catalog(&e))?);
    Ok(())
}
