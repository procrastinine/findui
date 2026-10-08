//! fzf remains authoritative for ranking. Cache only proven subsets of an
//! immutable, ordered input generation, and retain original tie order.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Query {
    executable: PathBuf,
    query: String,
    basename: bool,
    case_sensitive: bool,
    cache_directory: Option<PathBuf>,
    #[serde(default)]
    stats: bool,
}
struct Cached {
    query: String,
    bits: Vec<u8>,
    output: Vec<u8>,
}
const BUDGET: u64 = 64 * 1024 * 1024;
fn simple(s: &str) -> bool {
    !s.is_empty()
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-./".contains(&b))
}
fn paths(bytes: &[u8]) -> Vec<&[u8]> {
    let mut start = 0;
    let mut paths = Vec::new();
    for end in memchr::memchr_iter(0, bytes).chain(std::iter::once(bytes.len())) {
        if end > start {
            paths.push(&bytes[start..end]);
        }
        start = end + 1;
    }
    paths
}
fn command(q: &Query) -> Command {
    let mut command = Command::new(&q.executable);
    command.args([
        "--read0",
        "--print0",
        "--no-extended",
        "--literal",
        "--scheme=path",
        "--algo=v2",
        if q.case_sensitive {
            "+i"
        } else {
            "--ignore-case"
        },
        "--filter",
        &q.query,
    ]);
    if q.basename {
        command.args(["--delimiter", "/", "--nth", "-1"]);
    }
    for name in [
        "FZF_DEFAULT_OPTS",
        "FZF_DEFAULT_OPTS_FILE",
        "FZF_DEFAULT_COMMAND",
    ] {
        command.env_remove(name);
    }
    command
}
fn check(status: std::process::ExitStatus) -> io::Result<()> {
    if matches!(status.code(), Some(0 | 1)) {
        Ok(())
    } else {
        Err(io::Error::other(format!("fzf failed: {status}")))
    }
}
fn read_cache(path: &Path) -> Option<Cached> {
    let mut data = Vec::new();
    fs::File::open(path)
        .ok()?
        .take(BUDGET + 1)
        .read_to_end(&mut data)
        .ok()?;
    if data.len() as u64 > BUDGET || data.len() < 12 {
        return None;
    }
    let query_len = u32::from_le_bytes(data[..4].try_into().ok()?) as usize;
    let bits_len = usize::try_from(u64::from_le_bytes(data[4..12].try_into().ok()?)).ok()?;
    let end = 12usize.checked_add(query_len)?;
    let output = end.checked_add(bits_len)?;
    if output > data.len() {
        return None;
    }
    Some(Cached {
        query: std::str::from_utf8(&data[12..end]).ok()?.to_owned(),
        bits: data[end..output].to_vec(),
        output: data[output..].to_vec(),
    })
}
fn save_cache(directory: &Path, cached: &Cached) -> io::Result<()> {
    if 12 + cached.query.len() + cached.bits.len() + cached.output.len() > BUDGET as usize {
        return Ok(());
    }
    fs::create_dir_all(directory)?;
    let mut file = tempfile::NamedTempFile::new_in(directory)?;
    {
        let mut writer = io::BufWriter::new(&mut file);
        writer.write_all(&(cached.query.len() as u32).to_le_bytes())?;
        writer.write_all(&(cached.bits.len() as u64).to_le_bytes())?;
        writer.write_all(cached.query.as_bytes())?;
        writer.write_all(&cached.bits)?;
        writer.write_all(&cached.output)?;
        writer.flush()?;
    }
    file.persist(directory.join(format!(
        "{}.bin",
        crate::content_index::hash(cached.query.as_bytes())
    )))
    .map_err(io::Error::other)?;
    Ok(())
}
pub fn run(json: &str) -> Result<(), Box<dyn std::error::Error>> {
    let q: Query = serde_json::from_str(json)?;
    let start = std::time::Instant::now();
    // Caching is optional. An unavailable/full cache must never lose matches.
    let lease = q
        .cache_directory
        .as_ref()
        .and_then(|root| crate::extraction::lease_directory(root).ok());
    let root = q
        .cache_directory
        .as_ref()
        .filter(|_| lease.is_some())
        .map(|r| r.join("fuzzy-v2"));
    if root.is_none() {
        check(command(&q).status()?)?;
        return Ok(());
    }
    let mut bytes = Vec::new();
    io::stdin()
        .lock()
        .take(BUDGET + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > BUDGET {
        let mut child = command(&q).stdin(Stdio::piped()).spawn()?;
        let written = (|| {
            let mut stdin = child.stdin.take().unwrap();
            stdin.write_all(&bytes)?;
            io::copy(&mut io::stdin().lock(), &mut stdin)?;
            Ok::<_, io::Error>(())
        })();
        let status = child.wait()?;
        written?;
        check(status)?;
        return Ok(());
    }
    let mut hash = Sha256::new();
    hash.update(&bytes);
    hash.update(crate::content_index::identity(
        &q.executable,
        "fzf-v2-path-literal-v2",
    )?);
    hash.update([q.basename as u8, q.case_sensitive as u8]);
    let generation = root
        .as_ref()
        .unwrap()
        .join(crate::content_index::hex(&hash.finalize()));
    let read_time = start.elapsed();
    let mut subset: Option<Cached> = None;
    if let Ok(entries) = fs::read_dir(&generation) {
        for entry in entries.flatten() {
            let Some(cached) = read_cache(&entry.path()) else {
                continue;
            };
            if cached.query == q.query {
                if q.stats {
                    eprintln!(
                        "findui-stats: {}",
                        serde_json::json!({"fuzzyCacheHit":true,"fuzzyCandidates":0,"fuzzyInputPaths":memchr::memchr_iter(0,&bytes).count()})
                    );
                }
                io::stdout().lock().write_all(&cached.output)?;
                return Ok(());
            }
            if simple(&q.query)
                && simple(&cached.query)
                && q.query.starts_with(&cached.query)
                && subset
                    .as_ref()
                    .is_none_or(|s| s.query.len() < cached.query.len())
            {
                subset = Some(cached);
            }
        }
    }
    let paths = paths(&bytes);
    if subset
        .as_ref()
        .is_some_and(|s| s.bits.len() != paths.len().div_ceil(8))
    {
        subset = None;
    }
    let mut narrowed = Vec::new();
    if let Some(previous) = &subset {
        for (i, path) in paths.iter().enumerate() {
            if previous.bits[i / 8] & (1 << (i % 8)) != 0 {
                narrowed.extend_from_slice(path);
                narrowed.push(0);
            }
        }
    }
    let source = if subset.is_some() { &narrowed } else { &bytes };
    let candidate_time = start.elapsed();
    let mut child = command(&q)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().unwrap();
    let result = std::thread::scope(|scope| {
        let writer = scope.spawn(move || stdin.write_all(source));
        let output = child.wait_with_output();
        writer
            .join()
            .map_err(|_| io::Error::other("fzf input writer failed"))??;
        output
    })?;
    check(result.status)?;
    let fzf_time = start.elapsed();
    io::stdout().lock().write_all(&result.stdout)?;
    if result.stdout.len() as u64 <= BUDGET / 2 {
        let matches: HashSet<_> = result
            .stdout
            .split(|b| *b == 0)
            .filter(|s| !s.is_empty())
            .collect();
        let mut bits = vec![0u8; paths.len().div_ceil(8)];
        for (i, path) in paths.iter().enumerate() {
            if subset
                .as_ref()
                .is_none_or(|s| s.bits[i / 8] & (1 << (i % 8)) != 0)
                && matches.contains(path)
            {
                bits[i / 8] |= 1 << (i % 8);
            }
        }
        let _ = save_cache(
            &generation,
            &Cached {
                query: q.query.clone(),
                bits,
                output: result.stdout,
            },
        );
    }
    prune(root.as_ref().unwrap());
    if q.stats {
        eprintln!(
            "findui-stats: {}",
            serde_json::json!({"fuzzyCacheHit":false,"fuzzyInputPaths":paths.len(),"fuzzyCandidates":subset.as_ref().map_or(paths.len(),|s|s.bits.iter().map(|b|b.count_ones() as usize).sum()),"readMs":read_time.as_secs_f64()*1000.0,"candidateMs":(candidate_time-read_time).as_secs_f64()*1000.0,"fzfMs":(fzf_time-candidate_time).as_secs_f64()*1000.0,"saveMs":(start.elapsed()-fzf_time).as_secs_f64()*1000.0})
        );
    }
    Ok(())
}
fn prune(root: &Path) {
    let mut files = Vec::new();
    if let Ok(generations) = fs::read_dir(root) {
        for dir in generations.flatten() {
            if let Ok(entries) = fs::read_dir(dir.path()) {
                for file in entries.flatten() {
                    if let Ok(m) = file.metadata() {
                        files.push((m.modified().ok(), m.len(), file.path()));
                    }
                }
            }
        }
    }
    files.sort_by(|a, b| b.0.cmp(&a.0));
    let mut total = 0;
    for (i, (_, size, path)) in files.into_iter().enumerate() {
        total += size;
        if total > BUDGET || i >= 8 {
            let _ = fs::remove_file(path);
        }
    }
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let _ = fs::remove_dir(entry.path());
        }
    }
}
