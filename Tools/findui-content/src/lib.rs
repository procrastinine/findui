//! Reads NUL-delimited paths and a JSON query plan; writes rg-compatible JSON
//! matches or NUL-delimited matching paths. No GUI, shell evaluation, or network.
mod archive;
mod adapters;
mod media;
mod benchmark;
mod content_index;
mod database_reader;
mod documents;
mod extraction;
mod formats;
mod execution;
mod input;
mod fulltext;
mod fuzzy;
mod inspect;
mod mail_reader;
mod metadata;
mod paths;
mod proximity;
mod readers;
mod records;
mod search;
mod typos;
mod unique;
mod walk;
mod word_state;
mod word_journal;
mod word_tokenizer;
use base64::{engine::general_purpose::STANDARD, Engine};
use grep_matcher::Matcher;
use grep_regex::{RegexMatcher, RegexMatcherBuilder};
use grep_searcher::{BinaryDetection, Searcher, SearcherBuilder, Sink, SinkFinish, SinkMatch};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io::{self, Seek, Write},
    os::unix::ffi::OsStrExt,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering::Relaxed},
        Arc, Condvar, Mutex,
    },
    time::Duration,
};

mod query;
mod output;
use query::{Tree, Leaf, Plan};
use output::{Output, OrderedOutput};

fn text(bytes: &[u8]) -> Value {
    match std::str::from_utf8(bytes) {
        Ok(s) => json!({"text":s}),
        Err(_) => json!({"bytes":STANDARD.encode(bytes)}),
    }
}
pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 3 && args[1] == "--execute" { return execution::run(&args[2]); }
    if args.len() == 2 && args[1] == "--benchmark-primitives" {
        return benchmark::run();
    }
    if args.len() == 3 && args[1] == "--fuzzy" {
        return fuzzy::run(&args[2]);
    }
    if args.len() == 3 && args[1] == "--readers" {
        return readers::run(&args[2]);
    }
    if args.len() == 3 && args[1] == "--cache-ensure" {
        let _lease = extraction::lease_directory(std::path::Path::new(&args[2]))?;
        return Ok(());
    }
    if args.len() == 3 && args[1] == "--text-preview" {
        return inspect::text_preview(&args[2]);
    }
    if args.len() == 3 && args[1] == "--prepare-words" {
        return fulltext::prepare(serde_json::from_str(&args[2])?);
    }
    if args.len() == 3 && args[1] == "--word-matches" {
        return fulltext::search(serde_json::from_str(&args[2])?);
    }
    if args.len() == 3 && args[1] == "--word-candidates" {
        let mut plan: Plan = serde_json::from_str(&args[2])?;
        plan.word_candidates = true;
        return fulltext::search(plan);
    }
    if args.len() == 3 && args[1] == "--word-status" {
        return fulltext::status(serde_json::from_str(&args[2])?);
    }
    if args.len() == 4 && args[1] == "--word-suggest" {
        return fulltext::suggest(serde_json::from_str(&args[2])?, &args[3]);
    }
    if args.len() == 5 && args[1] == "--word-render" {
        let mut plan: Plan = serde_json::from_str(&args[2])?;
        plan.word_selection = Some(args[3].clone().into());
        plan.files_only = args[4] == "files";
        plan.word_fuzzy_order = args[4] == "fuzzy";
        return fulltext::search(plan);
    }
    if args.len() == 3 && args[1] == "--word-paths" {
        return fulltext::spool(&args[1], &args[2], false, false);
    }
    if args.len() == 4 && args[1] == "--word-select" {
        return fulltext::spool(&args[1], &args[2], args[3] == "files", args[3] == "fuzzy");
    }
    if args.len() == 3 && args[1] == "--snapshot-records" {
        return paths::snapshot_records(&args[2], None);
    }
    if args.len() == 4 && args[1] == "--snapshot-records" {
        return paths::snapshot_records(&args[2], Some(&args[3]));
    }
    if args.len() == 3 && args[1] == "--paths" {
        return Ok(paths::run(&args[2])?);
    }
    if args.len() == 3 && args[1] == "--walk" {
        return Ok(walk::run(&args[2])?);
    }
    if args.len() == 3 && args[1] == "--admit" {
        return Ok(walk::admit(&args[2])?);
    }
    if args.len() == 3 && args[1] == "--explain-path" {
        return Ok(walk::explain(&args[2])?);
    }
    if args.get(1).is_some_and(|s| s == "--metadata") {
        return Ok(metadata::run(&args[2..])?);
    }
    if args.len() == 3 && ["--cache-info", "--cache-clear", "--cache-retry"].contains(&args[1].as_str()) {
        return Ok(extraction::cache_action(
            &args[1],
            std::path::Path::new(&args[2]),
        )?);
    }
    if args.len() == 3 && args[1] == "--tika-stdin" {
        return Ok(extraction::tika_stdin(std::path::Path::new(&args[2]))?);
    }
    if args.len() == 3
        && [
            "--document-preview",
            "--materialize-member",
            "--verify-document",
        ]
        .contains(&args[1].as_str())
    {
        return inspect::run(&args[1], &args[2]);
    }
    if args.len() != 3 || args[1] != "--plan" {
        println!("findui-content --plan JSON < paths.nul\n\nSingle-pass parallel search; Rust regex syntax (ripgrep's grep crates).\nPlan: {{\"leaves\":[{{\"pattern\":\"hello\",\"regex\":false}}],\"tree\":{{\"leaf\":0}},\"positive\":[0]}}\nOptions: caseSensitive, wholeWords, filesOnly, fileUnit, documentUnit, threads (0=auto), ordered, stats, encoding, typoTolerance (0–2), stemWords, extraction, indexDirectory, indexOnly, useIndex, archiveNamesOnly. archiveNamesOnly reads ZIP central-directory names without decompression and only accepts member-field leaves. Leaves support pattern/regex, field (title/author/member), or terms/distance/ordered for proximity.\nOutputs match JSON, or NUL paths for filesOnly. fileUnit + documentUnit matches each member separately; fileUnit alone returns outer files. ordered preserves candidate order with bounded buffering. Diagnostics go to stderr.\n\nOther commands:\n  --walk JSON\n  --admit JSON < paths.nul\n  --paths JSON < paths.nul\n  --snapshot-records index.sqlite\n  --explain-path JSON\n  --prepare-words JSON < paths.nul\n  --word-matches JSON\n  --metadata [--tags] [--follow] [--threads N] < paths.nul\n  --text-preview JSON\n  --document-preview JSON\n  --materialize-member JSON\n  --verify-document JSON\n  --cache-info DIRECTORY\n  --cache-clear DIRECTORY\n  --tika-stdin APP.jar < office-file");
        return if args.len() == 2 && args[1] == "--help" {
            Ok(())
        } else {
            Err("Expected --plan JSON".into())
        };
    }
    search::run(serde_json::from_str(&args[2])?)
}
