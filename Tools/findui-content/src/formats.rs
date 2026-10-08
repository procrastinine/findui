//! Bounded recognition: no payload expansion and no converter during detection.
use std::{
    fs,
    io::{self, Read},
    path::Path,
    sync::atomic::AtomicBool,
    time::{Duration, Instant},
};
pub fn extension(path: &Path) -> String {
    path.extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_ascii_lowercase()
}
pub fn detect_cached(path: &Path, cache_root: Option<&Path>) -> io::Result<String> {
    detect_cached_with_metadata(path, cache_root, &fs::metadata(path)?)
}
pub fn detect_cached_with_metadata(
    path: &Path,
    cache_root: Option<&Path>,
    metadata: &fs::Metadata,
) -> io::Result<String> {
    let cache = cache_root
        .filter(|_| crate::content_index::cacheable(metadata))
        .map(|root| {
            crate::content_index::Cache::from_metadata(
                &root.join("formats-v1"),
                path,
                "format-v1",
                metadata,
            )
        });
    if let Some(format) = cache.as_ref().and_then(|c| c.format()) {
        return Ok(format);
    }
    let format = detect(path)?;
    // Tiny plain files are cheaper to sniff than to create and maintain a
    // separate cache record for. Structured recognition can scan ZIP catalogs.
    if let Some(cache) = cache.filter(|_| document(&format) || crate::archive::is_format(&format)) {
        if crate::content_index::identity(path, "format-v1")? == cache.identity {
            // A cache failure never changes detection or search membership.
            let _ = cache.save_format(&format);
        }
    }
    Ok(format)
}
pub fn detect(path: &Path) -> io::Result<String> {
    let fallback = extension(path);
    let mut prefix = [0u8; 8192];
    let count = fs::File::open(path)?.read(&mut prefix)?;
    let bytes = &prefix[..count];
    if bytes.starts_with(b"%PDF-") {
        return Ok("pdf".into());
    }
    if bytes.starts_with(b"SQLite format 3\0") {
        return Ok("sqlite".into());
    }
    if bytes.starts_with(b"{\\rtf") {
        return Ok("rtf".into());
    }
    if bytes.starts_with(b"PK\x03\x04") || bytes.starts_with(b"PK\x05\x06") {
        let entries = crate::archive::Reader::zip_names(
            path,
            &AtomicBool::new(false),
            Instant::now() + Duration::from_secs(5),
        )?;
        let names: std::collections::HashSet<_> = entries.iter().map(|e| e.1.as_str()).collect();
        for (name, format) in [
            ("word/document.xml", "docx"),
            ("xl/workbook.xml", "xlsx"),
            ("ppt/presentation.xml", "pptx"),
            ("META-INF/container.xml", "epub"),
        ] {
            if names.contains(name) {
                return Ok(format.into());
            }
        }
        if names.contains("content.xml") && names.contains("META-INF/manifest.xml") {
            return Ok(if matches!(fallback.as_str(), "ods" | "odp") {
                fallback
            } else {
                "odt".into()
            });
        }
        return Ok("zip".into());
    }
    let prefix = String::from_utf8_lossy(bytes);
    let lower = prefix.trim_start().to_ascii_lowercase();
    if lower.starts_with("<!doctype html") || lower.starts_with("<html") {
        return Ok("html".into());
    }
    if prefix.starts_with("From ")
        && prefix
            .lines()
            .take(20)
            .any(|l| l.starts_with("Subject:") || l.starts_with("From:"))
    {
        return Ok("mbox".into());
    }
    let headers = prefix
        .split("\r\n\r\n")
        .next()
        .unwrap_or(&prefix)
        .split("\n\n")
        .next()
        .unwrap_or(&prefix)
        .to_ascii_lowercase();
    if headers.lines().any(|l| l.starts_with("from:"))
        && headers
            .lines()
            .any(|l| l.starts_with("subject:") || l.starts_with("mime-version:"))
    {
        return Ok("eml".into());
    }
    Ok(fallback)
}
pub fn document(format: &str) -> bool {
    crate::readers::for_format(format).is_some()
}
