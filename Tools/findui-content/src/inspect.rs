//! GUI-free access to the same document identities used by search results.
use crate::{
    content_index::{self, Cache, Signature},
    documents::{self, Member},
    extraction::Extraction,
};
use serde::Deserialize;
use serde_json::json;
use std::{
    io,
    path::PathBuf,
    sync::{atomic::AtomicBool, Arc},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Origin {
    #[serde(default)]
    metadata_only: bool,
    #[serde(default)]
    members: Vec<Member>,
    source_identity: String,
    #[serde(default)]
    record_key: Option<String>,
    line: usize,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    path: PathBuf,
    origin: Origin,
    extraction: Extraction,
    #[serde(default = "radius")]
    context: usize,
    expected_snippet: Option<String>,
}
fn radius() -> usize {
    3
}

/// Use the search engine's decoder for context too, including automatic BOMs.
pub fn text_preview(json: &str) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct TextRequest {
        path: PathBuf,
        line: u64,
        #[serde(default = "radius")]
        context: usize,
        encoding: Option<String>,
        expected_snippet: Option<String>,
    }
    let request: TextRequest = serde_json::from_str(json)?;
    let target = request.line.max(1);
    let first = target
        .saturating_sub(request.context.min(100) as u64)
        .max(1);
    let expected: Vec<_> = request.expected_snippet.as_deref().map(|s| s.lines().collect()).unwrap_or_default();
    let span = expected.len().max(1) as u64;
    let last_match = target.saturating_add(span - 1);
    let last = last_match.saturating_add(request.context.min(100) as u64);
    let mut verified = 0;
    let encoding = request
        .encoding
        .as_deref()
        .filter(|s| !s.is_empty() && *s != "auto")
        .map(grep_searcher::Encoding::new)
        .transpose()?;
    let matcher = grep_regex::RegexMatcher::new("")?;
    let mut lines = Vec::new();
    let mut warning = None;
    let file = std::fs::File::open(&request.path)?;
    let capped = file.metadata()?.len() > 16 * 1024 * 1024;
    grep_searcher::SearcherBuilder::new().line_number(true).encoding(encoding).build()
        .search_reader(&matcher, file.take(16 * 1024 * 1024), grep_searcher::sinks::Bytes(|number, bytes| {
            if number >= first && number <= last {
                let decoded = String::from_utf8_lossy(bytes);
                let text = decoded.trim_end_matches('\n').trim_end_matches('\r');
                if number >= target && number <= last_match {
                    verified += 1;
                    if expected.get((number - target) as usize).is_some_and(|s| *s != text) {
                        warning = Some("This file changed since the search. Run the search again to update matches.");
                    }
                }
                if number > target && number <= last_match { return Ok(number < last); }
                let mut shortened: String = text.chars().take(4000).collect();
                if shortened.len() < text.len() { shortened.push('…'); warning.get_or_insert("Long preview lines are shortened."); }
                lines.push(json!({"number":number,"text":shortened,"isMatch":number==target}));
            }
            Ok(number < last)
        }))?;
    if !lines.iter().any(|l| l["isMatch"] == true) || verified < span {
        warning = Some(if capped {
            "Context preview reached its 16 MB read limit. Open the file for full context."
        } else {
            "The matching line is no longer available. Run the search again."
        });
    }
    println!("{}", json!({"lines":lines,"warning":warning}));
    Ok(())
}

pub fn run(action: &str, json: &str) -> Result<(), Box<dyn std::error::Error>> {
    let mut request: Request = serde_json::from_str(json)?;
    request.extraction.validate()?;
    let stopped = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, stopped.clone())?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, stopped.clone())?;
    let verify = || -> io::Result<()> {
        if content_index::identity(&request.path, "open-v1")? != request.origin.source_identity {
            return Err(io::Error::other(
                "This document changed since the search. Search again before opening the match",
            ));
        }
        Ok(())
    };
    verify()?;
    if request.origin.metadata_only && action != "--verify-document" {
        return Err("Only archive names were searched. Enable expansion and search again to preview or extract member contents".into());
    }
    if action == "--verify-document" {
        println!("{}", json!({"path":request.path,"valid":true}));
        return Ok(());
    }
    if action == "--materialize-member" {
        let file = documents::materialize(
            &request.path,
            &request.origin.members,
            request.extraction.max_megabytes * 1024 * 1024,
            &stopped,
            &request.extraction,
        )?;
        verify()?;
        let (_, path) = file.keep()?;
        println!("{}", json!({"path":path,"temporary":true}));
        return Ok(());
    }
    let _lease = match request.extraction.lease() {
        Ok(value) => value,
        Err(error) => {
            eprintln!("findui-cache: {error}");
            request.extraction.cache_directory = None;
            None
        }
    };
    let _tika = crate::extraction::tika_lease(request.extraction.tika_jar.as_deref())?;
    let config = request.extraction.config()?;
    let mut cache = request
        .extraction
        .cache_directory
        .as_ref()
        .and_then(|r| Cache::new(&r.join("structured-v2"), &request.path, &config).ok());
    let _lock = match cache.as_ref().map(|c| c.lock(&stopped)).transpose() {
        Ok(lock) => lock,
        Err(error) => {
            eprintln!("findui-cache: {error}");
            cache = None;
            None
        }
    };
    let bundle = if let Some(bundle) = cache
        .as_ref()
        .and_then(|c| c.bundle(request.extraction.max_megabytes * 1024 * 1024))
    {
        bundle
    } else {
        let bundle = documents::extract(&request.path, &request.extraction, &config, &stopped)?;
        verify()?;
        if bundle.warnings.is_empty() {
            if let Some(cache) = &cache {
                if let Err(error) = cache.save(Signature::bundle(&bundle), Some(&bundle)) {
                    eprintln!("findui-cache: {error}");
                }
            }
        }
        bundle
    };
    verify()?;
    let document = bundle
        .documents
        .iter()
        .find(|d| {
            d.members == request.origin.members
                && d.metadata.get("finduiRecord") == request.origin.record_key.as_ref()
        })
        .ok_or_else(|| io::Error::other("The matching document is unavailable. Search again"))?;
    let body = if document.text.is_empty() {
        "\n"
    } else {
        &document.text
    };
    let target = request.origin.line.max(1);
    let radius = request.context.min(100);
    let expected: Vec<_> = request.expected_snippet.as_deref().map(|s| s.lines().collect()).unwrap_or_default();
    let span = expected.len().max(1);
    let mut verified = 0;
    let mut lines = Vec::new();
    for (index, text) in body.lines().enumerate().skip(target.saturating_sub(radius+1)).take(span+radius*2) {
        let number = index + 1;
        if number >= target && number < target + span {
            verified += 1;
            if expected.get(number-target).is_some_and(|s| *s != text.trim_end_matches('\r')) {
                return Err("The document reader produced different text. Search again to update this match".into());
            }
            if number != target { continue; }
        }
        lines.push(json!({"number":number,"text":text.chars().take(4000).collect::<String>(),"isMatch":number==target}));
    }
    if verified < span { return Err("The matching text is no longer available. Search again.".into()); }
    println!(
        "{}",
        json!({"lines":lines,"metadata":document.metadata,"members":document.members,
        "warning":if bundle.warnings.is_empty(){None}else{Some(bundle.warnings.join("\n"))}})
    );
    Ok(())
}
