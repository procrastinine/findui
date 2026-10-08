//! Conservative four-gram filters. They never decide membership: the existing
//! matcher verifies candidates. Unsupported encodings/queries always scan.
use crate::{documents::Bundle, Leaf, Plan, Tree};
use flate2::{read::GzDecoder, write::GzEncoder, Compression};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read, Write},
    os::{
        fd::AsRawFd,
        unix::{
            ffi::OsStrExt,
            fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
        },
    },
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

/// Each group is an OR of possible prefixes/suffixes; every group is required.
/// Compile once per query. Optional/empty/infinite sequences cannot reject a
/// file, and the full matcher remains authoritative for every survivor.
pub fn regex_literals(pattern: &str) -> Vec<Vec<String>> {
    use regex_syntax::hir::literal::{ExtractKind, Extractor};
    let Ok(hir) = regex_syntax::Parser::new().parse(pattern) else {
        return vec![];
    };
    [ExtractKind::Prefix, ExtractKind::Suffix]
        .into_iter()
        .filter_map(|kind| {
            let seq = Extractor::new()
                .kind(kind)
                .limit_total(64)
                .limit_literal_len(64)
                .extract(&hir);
            let literals = seq.literals()?;
            if literals.is_empty() || literals.iter().any(|l| l.len() < 4) {
                return None;
            }
            literals
                .iter()
                .map(|l| std::str::from_utf8(l.as_bytes()).ok().map(str::to_owned))
                .collect()
        })
        .collect()
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Signature {
    raw: Vec<u64>,
    folded: Vec<u64>,
    non_ascii: bool,
    nul: bool,
}
impl Default for Signature {
    fn default() -> Self {
        Self {
            raw: vec![0; 1024],
            folded: vec![0; 1024],
            non_ascii: false,
            nul: false,
        }
    }
}
fn positions(word: u32) -> (usize, usize) {
    let mut hash = word;
    hash ^= hash >> 16;
    hash = hash.wrapping_mul(0x7feb352d);
    hash ^= hash >> 15;
    (
        hash as usize & 65_535,
        hash.rotate_left(13) as usize & 65_535,
    )
}
fn insert(bits: &mut [u64], word: u32) {
    let (a, b) = positions(word);
    bits[a / 64] |= 1 << (a % 64);
    bits[b / 64] |= 1 << (b % 64);
}
fn contains(bits: &[u64], word: u32) -> bool {
    let (a, b) = positions(word);
    bits[a / 64] & (1 << (a % 64)) != 0 && bits[b / 64] & (1 << (b % 64)) != 0
}
impl Signature {
    pub fn add(&mut self, bytes: &[u8]) {
        self.non_ascii |= !bytes.is_ascii();
        self.nul |= bytes.contains(&0);
        for gram in bytes.windows(4) {
            insert(&mut self.raw, u32::from_le_bytes(gram.try_into().unwrap()));
            insert(
                &mut self.folded,
                u32::from_le_bytes([
                    gram[0].to_ascii_lowercase(),
                    gram[1].to_ascii_lowercase(),
                    gram[2].to_ascii_lowercase(),
                    gram[3].to_ascii_lowercase(),
                ]),
            );
        }
    }
    fn possible(&self, value: &str, sensitive: bool) -> bool {
        // grep-searcher can transcode UTF-16; Unicode case folding can match
        // ASCII patterns against non-ASCII letters (e.g. Kelvin sign and K).
        if self.nul || (!sensitive && (self.non_ascii || !value.is_ascii())) {
            return true;
        }
        let bytes = if sensitive {
            value.as_bytes().to_vec()
        } else {
            value.to_ascii_lowercase().into_bytes()
        };
        bytes.windows(4).all(|g| {
            contains(
                if sensitive { &self.raw } else { &self.folded },
                u32::from_le_bytes(g.try_into().unwrap()),
            )
        })
    }
    fn leaf(&self, leaf: &Leaf, sensitive: bool) -> (bool, bool) {
        let maybe = if leaf.regex {
            // Fold conservatively even in case-sensitive mode: inline (?i)
            // flags may appear anywhere. Non-ASCII/transcoded input scans.
            leaf.required_literals.iter().all(|alternatives| {
                alternatives
                    .iter()
                    .any(|literal| self.possible(literal, false))
            })
        } else if !leaf.terms.is_empty() {
            leaf.terms.iter().all(|t| self.possible(t, sensitive))
        } else {
            self.possible(&leaf.pattern, sensitive)
        };
        (true, maybe) // could be false, could be true; never assert a match
    }
    pub fn may_match(&self, plan: &Plan) -> bool {
        if plan.typo_tolerance > 0 || plan.encoding.is_some() {
            return true;
        }
        fn evaluate(tree: &Tree, values: &[(bool, bool)]) -> (bool, bool) {
            match tree {
                Tree::Leaf { leaf } => values[*leaf],
                Tree::All { all } => {
                    let v: Vec<_> = all.iter().map(|n| evaluate(n, values)).collect();
                    (v.iter().any(|v| v.0), v.iter().all(|v| v.1))
                }
                Tree::Any { any } => {
                    let v: Vec<_> = any.iter().map(|n| evaluate(n, values)).collect();
                    (v.iter().all(|v| v.0), v.iter().any(|v| v.1))
                }
                Tree::None { none } => {
                    let v: Vec<_> = none.iter().map(|n| evaluate(n, values)).collect();
                    (v.iter().any(|v| v.1), v.iter().all(|v| v.0))
                }
            }
        }
        evaluate(
            &plan.tree,
            &plan
                .leaves
                .iter()
                .map(|l| self.leaf(l, plan.case_sensitive))
                .collect::<Vec<_>>(),
        )
        .1
    }
    pub fn bundle(bundle: &Bundle) -> Self {
        let mut signature = Self::default();
        for doc in &bundle.documents {
            signature.add(doc.text.as_bytes());
            signature.add(
                doc.members
                    .iter()
                    .map(|m| m.name.as_str())
                    .collect::<Vec<_>>()
                    .join("/")
                    .as_bytes(),
            );
            for value in doc.metadata.values() {
                signature.add(value.as_bytes());
            }
        }
        signature
    }
}

#[derive(Serialize, Deserialize)]
pub struct Summary {
    pub identity: String,
    pub signature: Signature,
    pub has_bundle: bool,
}
const SUMMARY_SIZE: usize = 8 + 32 + 64 + 3 + 2048 * 8;
pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8] = b"0123456789abcdef";
    let mut out = Vec::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(DIGITS[(b >> 4) as usize]);
        out.push(DIGITS[(b & 15) as usize]);
    }
    String::from_utf8(out).expect("hex is ASCII")
}
pub fn hash(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}
pub fn identity(path: &Path, configuration: &str) -> io::Result<String> {
    let m = fs::metadata(path)?;
    Ok(identity_at_path(path, &m, configuration))
}
pub(crate) fn identity_at_path(path: &Path, m: &fs::Metadata, configuration: &str) -> String {
    // These records describe plain bytes, file format or directory membership;
    // SQLite WAL contents cannot change them. Keep their existing hash format.
    if configuration.starts_with("structured-v5-files:") || matches!(
        configuration,
        "plain-v2" | "format-v1" | "word-directory-v1"
    ) {
        return identity_for_metadata(m, &format!("{configuration}:"));
    }
    // A live SQLite database can change entirely through its WAL while the
    // main file keeps the same inode, size and timestamps.
    let mut wal = path.as_os_str().to_os_string();
    wal.push("-wal");
    let extra = fs::metadata(Path::new(&wal))
        .ok()
        .map(|m| identity_for_metadata(&m, "wal-v1"));
    identity_for_metadata(
        m,
        &format!("{configuration}:{}", extra.as_deref().unwrap_or("")),
    )
}
pub fn cacheable(m: &fs::Metadata) -> bool {
    m.mtime_nsec() != 0 || m.ctime_nsec() != 0
}
pub fn identity_for_metadata(m: &fs::Metadata, configuration: &str) -> String {
    hash(
        format!(
            "v2:{}:{}:{}:{}:{}:{}:{}:{}:{configuration}",
            m.dev(),
            m.ino(),
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.ctime(),
            m.ctime_nsec(),
            m.mode()
        )
        .as_bytes(),
    )
}
pub struct Cache {
    directory: PathBuf,
    pub identity: String,
}
impl Cache {
    pub fn format(&self) -> Option<String> {
        let mut bytes = Vec::new();
        fs::File::open(self.directory.join("format.json"))
            .ok()?
            .take(513)
            .read_to_end(&mut bytes)
            .ok()?;
        if bytes.len() > 512 {
            return None;
        }
        let (identity, format): (String, String) = serde_json::from_slice(&bytes).ok()?;
        (identity == self.identity).then_some(format)
    }
    pub fn save_format(&self, format: &str) -> io::Result<()> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.directory)?;
        let mut file = tempfile::NamedTempFile::new_in(&self.directory)?;
        serde_json::to_writer(&mut file, &(&self.identity, format))?;
        file.persist(self.directory.join("format.json"))
            .map_err(io::Error::other)?;
        Ok(())
    }
    pub fn was_indexed(&self) -> bool {
        self.directory.join("summary.bin").exists() || self.directory.join("summary.json").exists()
    }
    pub fn new(root: &Path, path: &Path, configuration: &str) -> io::Result<Self> {
        let metadata = fs::metadata(path)?;
        if !cacheable(&metadata) {
            return Err(io::Error::other(
                "Coarse filesystem timestamps; searching without cache reuse",
            ));
        }
        Ok(Self::from_metadata(root, path, configuration, &metadata))
    }
    pub fn from_metadata(
        root: &Path,
        path: &Path,
        configuration: &str,
        metadata: &fs::Metadata,
    ) -> Self {
        let directory = root.join(hash(path.as_os_str().as_bytes()));
        Self {
            directory,
            identity: identity_at_path(path, metadata, configuration),
        }
    }
    pub fn summary(&self) -> Option<Summary> {
        let mut bytes = Vec::new();
        fs::File::open(self.directory.join("summary.bin"))
            .ok()?
            .take(SUMMARY_SIZE as u64 + 1)
            .read_to_end(&mut bytes)
            .ok()?;
        if bytes.len() != SUMMARY_SIZE || &bytes[..8] != b"FUIIDX3\0" {
            return None;
        }
        let payload = &bytes[40..];
        if Sha256::digest(payload).as_slice() != &bytes[8..40]
            || &payload[..64] != self.identity.as_bytes()
        {
            return None;
        }
        if payload[64..67].iter().any(|v| *v > 1) {
            return None;
        }
        let words: Vec<_> = payload[67..]
            .chunks_exact(8)
            .map(|v| u64::from_le_bytes(v.try_into().unwrap()))
            .collect();
        Some(Summary {
            identity: self.identity.clone(),
            has_bundle: payload[64] != 0,
            signature: Signature {
                raw: words[..1024].to_vec(),
                folded: words[1024..].to_vec(),
                non_ascii: payload[65] != 0,
                nul: payload[66] != 0,
            },
        })
    }
    pub fn lock(&self, stopped: &AtomicBool) -> io::Result<fs::File> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.directory)?;
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(self.directory.join("lease"))?;
        let start = Instant::now();
        loop {
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(lock);
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::WouldBlock {
                return Err(error);
            }
            if stopped.load(Ordering::Relaxed) || start.elapsed() > Duration::from_secs(600) {
                return Err(io::Error::other("Content cache cancelled or busy"));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    pub fn bundle(&self, limit: u64) -> Option<Bundle> {
        if let Some(bundle) = self.failure(limit) { return Some(bundle); }
        if !self.summary()?.has_bundle {
            return None;
        }
        let reader = GzDecoder::new(fs::File::open(self.directory.join("documents.gz")).ok()?);
        // JSON escaping and location metadata can exceed the text budget.
        let mut bytes = Vec::new();
        reader
            .take(limit.saturating_mul(8).saturating_add(1024 * 1024))
            .read_to_end(&mut bytes)
            .ok()?;
        serde_json::from_slice(&bytes).ok()
    }
    pub fn save(&self, signature: Signature, bundle: Option<&Bundle>) -> io::Result<()> {
        let _ = fs::remove_file(self.directory.join("failed.gz"));
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.directory)?;
        if let Some(bundle) = bundle {
            let mut file = tempfile::NamedTempFile::new_in(&self.directory)?;
            let mut gzip = GzEncoder::new(file.as_file_mut(), Compression::fast());
            {
                // serde emits many tiny writes. Batch them before compression,
                // retaining bounded memory instead of serializing a second copy.
                let mut writer = io::BufWriter::with_capacity(65_536, &mut gzip);
                serde_json::to_writer(&mut writer, bundle)?;
                writer.flush()?;
            }
            gzip.finish()?.flush()?;
            file.persist(self.directory.join("documents.gz"))
                .map_err(io::Error::other)?;
        }
        let mut data = Vec::with_capacity(SUMMARY_SIZE - 40);
        data.extend_from_slice(self.identity.as_bytes());
        data.extend_from_slice(&[
            u8::from(bundle.is_some()),
            u8::from(signature.non_ascii),
            u8::from(signature.nul),
        ]);
        for word in signature.raw.iter().chain(&signature.folded) {
            data.extend_from_slice(&word.to_le_bytes());
        }
        let mut file = tempfile::NamedTempFile::new_in(&self.directory)?;
        file.write_all(b"FUIIDX3\0")?;
        file.write_all(&Sha256::digest(&data))?;
        file.write_all(&data)?;
        file.persist(self.directory.join("summary.bin"))
            .map_err(io::Error::other)?;
        Ok(())
    }

    fn failure(&self, limit: u64) -> Option<Bundle> {
        let reader = GzDecoder::new(fs::File::open(self.directory.join("failed.gz")).ok()?);
        let mut bytes = Vec::new();
        reader.take(limit.saturating_mul(8).saturating_add(1024 * 1024)).read_to_end(&mut bytes).ok()?;
        let (identity, expires, mut bundle): (String, u64, Bundle) = serde_json::from_slice(&bytes).ok()?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
        if identity != self.identity || now >= expires { return None; }
        for warning in &mut bundle.warnings {
            *warning = format!("{warning} (remembered failure; use Retry Failed Readers in Settings or FindUI --cli cache retry)");
        }
        Some(bundle)
    }
    pub fn remember_failure(&self, bundle: &Bundle) -> io::Result<()> {
        if bundle.warnings.is_empty() || bundle.incomplete || bundle.retryable { return Ok(()); }
        fs::create_dir_all(&self.directory)?;
        let mut file = tempfile::NamedTempFile::new_in(&self.directory)?;
        let mut gzip = GzEncoder::new(file.as_file_mut(), Compression::fast());
        // A reader's normal error exit can still depend on transient external
        // resources. Retry after 15 minutes even without an identity change.
        let expires = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(io::Error::other)?.as_secs() + 900;
        serde_json::to_writer(&mut gzip, &(&self.identity, expires, bundle))?;
        gzip.finish()?.flush()?;
        file.persist(self.directory.join("failed.gz")).map_err(io::Error::other)?;
        Ok(())
    }
}

/// Signature construction piggybacks on the actual scan; no second file read.
pub struct RecordingReader<R> {
    pub inner: R,
    pub signature: Signature,
    pub complete: bool,
    tail: Vec<u8>,
}
impl<R> RecordingReader<R> {
    pub fn new(inner: R) -> Self {
        Self {
            inner,
            signature: Signature::default(),
            complete: false,
            tail: Vec::new(),
        }
    }
}
impl<R: Read> Read for RecordingReader<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = self.inner.read(buffer)?;
        if count == 0 && !buffer.is_empty() {
            self.complete = true;
        }
        if count > 0 {
            let mut boundary = self.tail.clone();
            boundary.extend_from_slice(&buffer[..count.min(3)]);
            self.signature.add(&boundary);
            self.signature.add(&buffer[..count]);
            if count >= 3 {
                self.tail = buffer[count - 3..count].to_vec();
            } else {
                self.tail.extend_from_slice(&buffer[..count]);
                if self.tail.len() > 3 {
                    self.tail.drain(..self.tail.len() - 3);
                }
            }
        }
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recording_preserves_boundary_grams() {
        let mut r = RecordingReader::new(&b"abcdefghijkl"[..]);
        let mut b = [0; 2];
        while r.read(&mut b).unwrap() > 0 {}
        assert!(r.signature.possible("cdefghi", true));
        assert!(!r.signature.possible("missing", true));
        assert!(r.complete);
    }
    #[test]
    fn unicode_case_and_encoding_fall_back() {
        let mut s = Signature::default();
        s.add("KKKK".as_bytes());
        assert!(s.possible("kkkk", false));
        s.add(&[0]);
        assert!(s.possible("anything", true));
    }
    #[test]
    fn regex_required_literals_never_reject_real_matches() {
        let patterns = [
            "needle",
            "^needle$",
            "needle.*other",
            ".*needle",
            "needle|other",
            "(?:needle)?",
            "(?:needle|)",
            "(?:needle|other)+",
            "(?i:NEEDLE)",
            "\\bneedle\\b",
            "[a-z]*needle",
            "needle{0,2}",
            "n(?:eedle|onsense)",
            "(?s:needle.*other)",
            "K{4}",
            "(?i:k{4})",
            "needle\\.txt",
        ];
        let texts = [
            "",
            "needle",
            "other",
            "ordinary words",
            "NEEDLE",
            "needle\nother",
            "nonsense",
            "KKKK",
            "kkkk",
            "needle.txt",
            "needl",
        ];
        for pattern in patterns {
            for sensitive in [false, true] {
                let regex = regex::RegexBuilder::new(pattern)
                    .case_insensitive(!sensitive)
                    .build()
                    .unwrap();
                let mut plan: Plan = serde_json::from_value(serde_json::json!({"leaves":[{"pattern":pattern,"regex":true}],"tree":{"leaf":0},"caseSensitive":sensitive})).unwrap();
                plan.leaves[0].required_literals = regex_literals(pattern);
                for text in texts {
                    let mut signature = Signature::default();
                    signature.add(text.as_bytes());
                    if regex.is_match(text) {
                        assert!(signature.may_match(&plan), "{pattern:?} against {text:?}");
                    }
                }
            }
        }
        let mut plan: Plan = serde_json::from_value(serde_json::json!({"leaves":[{"pattern":"neverpresentneedle","regex":true}],"tree":{"leaf":0}})).unwrap();
        plan.leaves[0].required_literals = regex_literals(&plan.leaves[0].pattern);
        let mut signature = Signature::default();
        signature.add(b"ordinary text only");
        assert!(!signature.may_match(&plan));
        plan.tree = Tree::None {
            none: vec![Tree::Leaf { leaf: 0 }],
        };
        assert!(signature.may_match(&plan));
    }
}
