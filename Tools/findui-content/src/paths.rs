//! Shared, headless path predicates. No per-query Perl interpreter or JSON::PP.
use crate::Tree;
use pcre2::bytes::{Regex, RegexBuilder};
use serde::Deserialize;
use std::{
    collections::HashSet,
    fs,
    io::{self, BufRead, Write},
    os::unix::fs::MetadataExt,
};
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Configuration {
    pub conditions: Vec<Condition>,
    pub case_sensitive: bool,
    pub semantics: String,
    pub snapshot: bool,
    pub follow: bool,
    pub tags: Vec<String>,
    pub tag_match: String,
    pub roots: Vec<String>,
    #[serde(rename = "type")]
    pub kind: String,
    pub minimum: Option<u64>,
    pub maximum: Option<u64>,
    pub from: Option<f64>,
    pub before: Option<f64>,
    pub born_from: Option<f64>,
    pub born_before: Option<f64>,
    pub hidden: bool,
    pub excluded_folders: Vec<String>,
    pub packages: bool,
    pub package_extensions: Vec<String>,
    pub minimum_depth: usize,
    pub maximum_depth: Option<usize>,
    pub leaves: Option<Vec<Configuration>>,
    pub tree: Option<Tree>,
    pub metadata_date: Option<MetadataDate>,
}
#[derive(Clone, Deserialize)]
pub struct MetadataDate {
    pub field: String,
    pub from: Option<f64>,
    pub before: Option<f64>,
}
#[derive(Clone, Deserialize, Default)]
#[serde(default)]
pub struct Condition {
    pub field: String,
    pub value: String,
    pub regex: bool,
    pub exclude: bool,
}
#[derive(Clone, Deserialize, serde::Serialize)]
pub struct Record {
    pub path: String,
    pub directory: bool,
    pub size: Option<u64>,
    pub modified: Option<f64>,
    pub created: Option<f64>,
    pub tags: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conditions: Option<Vec<bool>>,
}
impl Record {
    pub(crate) fn from_metadata(path: &str, m: &fs::Metadata) -> Self {
        Self {
            path: path.into(),
            directory: m.is_dir(),
            size: Some(m.len()),
            modified: Some(m.mtime() as f64 + m.mtime_nsec() as f64 / 1e9),
            created: m
                .created()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs_f64()),
            tags: None,
            conditions: None,
        }
    }
}
struct CompiledCondition {
    field: String,
    value: String,
    regex: Option<Regex>,
    native: Option<regex::bytes::Regex>,
    exclude: bool,
}
pub struct Predicate {
    config: Configuration,
    leaves: Vec<(Configuration, Vec<CompiledCondition>)>,
    canonical: Vec<String>,
}
fn normalized(s: &str, sensitive: bool) -> String {
    if s.is_ascii() {
        return if sensitive {
            s.into()
        } else {
            s.to_ascii_lowercase()
        };
    }
    let text: String = s.nfc().collect();
    if sensitive {
        text
    } else {
        text.to_lowercase()
    }
}
pub fn snapshot_records(path: &str, query: Option<&str>) -> Result<(), Box<dyn std::error::Error>> {
    let connection =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let config = query
        .map(serde_json::from_str::<Configuration>)
        .transpose()?;
    let (sql, args) = snapshot_query(&connection, config.as_ref());
    let mut statement = connection.prepare(&sql)?;
    let mut rows = statement.query(rusqlite::params_from_iter(args))?;
    let mut output = io::BufWriter::new(io::stdout());
    while let Some(row) = rows.next()? {
        let record = row.get_ref(0)?.as_blob()?;
        output.write_all(record)?;
        output.write_all(&[0])?;
    }
    output.flush()?;
    Ok(())
}
pub(crate) fn snapshot_query(
    connection: &rusqlite::Connection,
    config: Option<&Configuration>,
) -> (String, Vec<String>) {
    let version = connection
        .query_row("SELECT version FROM search_info WHERE id=1", [], |r| {
            r.get::<_, i64>(0)
        })
        .ok()
        .unwrap_or(0);
    let mut args = Vec::new();
    let candidate = config
        .filter(|c| version >= if c.semantics == "native" { 2 } else { 1 })
        .and_then(|c| candidate_expression(c, &mut args));
    let sql = candidate.map_or_else(|| "SELECT record FROM entries ORDER BY path".to_string(), |condition|
        format!("SELECT record FROM entries WHERE path IN (SELECT path FROM search_paths WHERE {condition}) ORDER BY path"));
    (sql, args)
}

/// Posting lists generate a superset. ASCII queries have identical folding in
/// Swift's writer and Rust's verifier; non-ASCII/short/negative/unsupported leaves
/// conservatively scan. Every returned record still passes Predicate::matches.
fn candidate_expression(config: &Configuration, args: &mut Vec<String>) -> Option<String> {
    fn leaf(c: &Configuration, args: &mut Vec<String>) -> Option<String> {
        let clauses: Vec<_> = c.conditions.iter().flat_map(|v| {
            if v.exclude { return vec![]; }
            let groups = if v.regex { crate::content_index::regex_literals(&v.value) } else { vec![vec![v.value.clone()]] };
            groups.into_iter().filter_map(|alternatives| {
            if alternatives.iter().any(|text| !text.is_ascii() || text.len() < 3) { return None; }
            let mut terms = Vec::new();
            for text in alternatives {
            let text = normalized(&text,false);
            // Root spelling can be restored after reading a frozen snapshot.
            // Name predicates never depend on it. Paths can cross its boundary.
            if v.field != "name" && (text.contains('/') || c.roots.iter().any(|r| normalized(r,false).contains(&text))) { return None; }
            let mut grams: Vec<_> = text.as_bytes().windows(3).map(|g| String::from_utf8(g.to_vec()).unwrap()).collect();
            grams.sort(); grams.dedup(); grams.truncate(16);
            terms.push(format!("({})",grams.iter().map(|g| format!("\"{}\"",g.replace('"',"\"\""))).collect::<Vec<_>>().join(" AND ")));
            }
            args.push(terms.join(" OR "));
            Some("id IN (SELECT rowid FROM name_candidates WHERE name_candidates MATCH ?)".to_string())
        }).collect::<Vec<_>>() }).collect();
        (!clauses.is_empty()).then(|| format!("({})", clauses.join(" AND ")))
    }
    fn tree(t: &Tree, leaves: &[Configuration], args: &mut Vec<String>) -> Option<String> {
        match t {
            Tree::Leaf { leaf: i } => leaves.get(*i).and_then(|l| leaf(l, args)),
            Tree::None { .. } => None,
            Tree::All { all } => {
                let clauses: Vec<_> = all.iter().filter_map(|t| tree(t, leaves, args)).collect();
                (!clauses.is_empty()).then(|| format!("({})", clauses.join(" AND ")))
            }
            Tree::Any { any } => {
                let initial = args.len();
                let clauses: Option<Vec<_>> = any.iter().map(|t| tree(t, leaves, args)).collect();
                if let Some(clauses) = clauses.filter(|c| !c.is_empty()) {
                    Some(format!("({})", clauses.join(" OR ")))
                } else {
                    args.truncate(initial);
                    None
                }
            }
        }
    }
    if let (Some(t), Some(leaves)) = (&config.tree, &config.leaves) {
        tree(t, leaves, args)
    } else {
        leaf(config, args)
    }
}
impl Predicate {
    pub(crate) fn configuration(&self) -> &Configuration {
        &self.config
    }
    pub(crate) fn needs_metadata(&self) -> bool {
        self.leaves.iter().any(|(c, _)| {
            c.minimum.is_some()
                || c.maximum.is_some()
                || c.from.is_some()
                || c.before.is_some()
                || c.born_from.is_some()
                || c.born_before.is_some()
        })
    }
    pub(crate) fn needs_tags(&self) -> bool {
        self.leaves.iter().any(|(c, _)| !c.tags.is_empty())
    }
    pub fn new(config: Configuration) -> io::Result<Self> {
        let leaves = config
            .leaves
            .clone()
            .unwrap_or_else(|| vec![config.clone()]);
        if let Some(tree) = &config.tree {
            tree.validate(leaves.len(), 0, &mut 0)
                .map_err(io::Error::other)?;
        }
        let leaves = leaves
            .into_iter()
            .map(|leaf| {
                let conditions = leaf
                    .conditions
                    .iter()
                    .map(|c| {
                        let native_semantics = leaf.semantics == "native";
                        let value: String = if native_semantics {
                            c.value.clone()
                        } else {
                            c.value.nfc().collect()
                        };
                        let native = if native_semantics {
                            let pattern = if c.regex {
                                value.clone()
                            } else {
                                regex_syntax::escape(&value)
                            };
                            // Same regex builder and flags as fd. Extended file
                            // regexes fall back to PCRE2 without normalizing bytes.
                            match regex::bytes::RegexBuilder::new(&pattern)
                                .case_insensitive(!leaf.case_sensitive)
                                .dot_matches_new_line(true)
                                .build()
                            {
                                Ok(regex) => Some(regex),
                                Err(_) if c.regex => None,
                                Err(e) => return Err(io::Error::other(e)),
                            }
                        } else {
                            None
                        };
                        let regex = if c.regex && native.is_none() {
                            Some(
                                RegexBuilder::new()
                                    .utf(true)
                                    .ucp(true)
                                    .dotall(true)
                                    .caseless(!leaf.case_sensitive)
                                    .jit_if_available(true)
                                    .build(&value)
                                    .map_err(io::Error::other)?,
                            )
                        } else {
                            None
                        };
                        Ok(CompiledCondition {
                            field: c.field.clone(),
                            value: normalized(&value, leaf.case_sensitive),
                            regex,
                            native,
                            exclude: c.exclude,
                        })
                    })
                    .collect::<io::Result<Vec<_>>>()?;
                Ok((leaf, conditions))
            })
            .collect::<io::Result<Vec<_>>>()?;
        let canonical = config
            .roots
            .iter()
            .map(|r| {
                fs::canonicalize(r)
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_else(|_| r.clone())
            })
            .collect();
        Ok(Self {
            config,
            leaves,
            canonical,
        })
    }
    pub fn restore_root(&self, path: &str) -> String {
        for (canonical, selected) in self.canonical.iter().zip(&self.config.roots) {
            if canonical != selected
                && path
                    .strip_prefix(canonical)
                    .is_some_and(|p| p.starts_with('/'))
            {
                return format!("{}{}", selected, &path[canonical.len()..]);
            }
        }
        path.to_owned()
    }
    pub fn mask(&self, path: &str, saved: Option<&Record>) -> io::Result<Option<Vec<bool>>> {
        let relative: Vec<&str> = self
            .config
            .roots
            .iter()
            .filter_map(|root| {
                if root == "/" {
                    path.strip_prefix('/')
                } else {
                    path.strip_prefix(root).and_then(|p| p.strip_prefix('/'))
                }
            })
            .collect();
        let Some(rel) = relative.iter().copied().find(|r| {
            let depth = r.split('/').count();
            !r.is_empty()
                && depth >= self.config.minimum_depth
                && self.config.maximum_depth.is_none_or(|max| depth <= max)
        }) else {
            return Ok(None);
        };
        let parts: Vec<&str> = rel.split('/').collect();
        let name = parts.last().copied().unwrap_or("");
        if !self.config.hidden && parts.iter().any(|p| p.starts_with('.')) {
            return Ok(None);
        }
        if !self.config.packages
            && parts[..parts.len() - 1].iter().any(|p| {
                p.rsplit_once('.').is_some_and(|(_, e)| {
                    self.config
                        .package_extensions
                        .iter()
                        .any(|x| x.eq_ignore_ascii_case(e))
                })
            })
        {
            return Ok(None);
        }
        // Scope constraints apply outside the Boolean expression. Otherwise a
        // NOT leaf can invert a rejected kind or excluded directory into a hit.
        let metadata = if saved.is_none() {
            let m = match if self.config.follow {
                fs::metadata(path)
            } else {
                fs::symlink_metadata(path)
            } {
                Ok(m) => m,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(e),
            };
            if !m.is_dir() && !m.is_file() {
                return Ok(None);
            }
            Some(Record::from_metadata(path, &m))
        } else {
            None
        };
        let m = saved.or(metadata.as_ref()).unwrap();
        if self.config.kind == "f" && m.directory || self.config.kind == "d" && !m.directory {
            return Ok(None);
        }
        let dirs = if m.directory {
            &parts[..]
        } else {
            &parts[..parts.len() - 1]
        };
        if dirs
            .iter()
            .any(|p| self.config.excluded_folders.iter().any(|x| x == p))
        {
            return Ok(None);
        }
        let mut mask = Vec::with_capacity(self.leaves.len());
        for (leaf, conditions) in &self.leaves {
            let mut matches = true;
            for c in conditions {
                let mut values: Vec<&str> = match c.field.as_str() {
                    "name" => vec![name],
                    "absolute" => vec![path],
                    "path" => relative.clone(),
                    _ => {
                        let mut v = relative.clone();
                        v.push(name);
                        v
                    }
                };
                if c.field != "name" && c.field != "absolute" {
                    values.push(path);
                }
                let mut found = false;
                for value in values {
                    if let Some(regex) = &c.native {
                        found |= regex.is_match(value.as_bytes());
                    } else if let Some(regex) = &c.regex {
                        found |= regex
                            .is_match(
                                if leaf.semantics == "native" {
                                    value.to_owned()
                                } else {
                                    value.nfc().collect::<String>()
                                }
                                .as_bytes(),
                            )
                            .map_err(io::Error::other)?;
                    } else {
                        found |= normalized(value, leaf.case_sensitive).contains(&c.value);
                    }
                    if found {
                        break;
                    }
                }
                if found == c.exclude {
                    matches = false;
                    break;
                }
            }
            if !matches {
                mask.push(false);
                continue;
            }
            if !leaf.tags.is_empty() {
                let tags = saved.and_then(|r|r.tags.as_ref()).ok_or_else(||io::Error::other(format!("Finder tags unavailable for {path}; refresh this snapshot or check file permissions")))?;
                let existing: HashSet<_> = tags
                    .iter()
                    .map(|v| normalized(v, leaf.case_sensitive))
                    .collect();
                let count = leaf
                    .tags
                    .iter()
                    .filter(|t| existing.contains(&normalized(t, leaf.case_sensitive)))
                    .count();
                matches = match leaf.tag_match.as_str() {
                    "none" => count == 0,
                    "any" => count > 0,
                    _ => count == leaf.tags.len(),
                };
                if !matches {
                    mask.push(false);
                    continue;
                }
            }
            matches &= !(leaf.kind == "f" && m.directory || leaf.kind == "d" && !m.directory);
            let dirs = if m.directory {
                &parts[..]
            } else {
                &parts[..parts.len() - 1]
            };
            matches &= !dirs
                .iter()
                .any(|p| self.config.excluded_folders.iter().any(|x| x == p));
            if let Some(lo) = leaf.minimum {
                matches &= !m.directory && m.size.is_some_and(|s| s >= lo);
            }
            if let Some(hi) = leaf.maximum {
                matches &= !m.directory && m.size.is_some_and(|s| s <= hi);
            }
            for (value, lo, hi) in [
                (m.modified, leaf.from, leaf.before),
                (m.created, leaf.born_from, leaf.born_before),
            ] {
                if let Some(lo) = lo {
                    matches &= value.is_some_and(|t| t >= lo)
                }
                if let Some(hi) = hi {
                    matches &= value.is_some_and(|t| t < hi)
                }
            }
            mask.push(matches);
        }
        Ok(Some(mask))
    }
    pub fn matches(&self, path: &str, saved: Option<&Record>) -> io::Result<bool> {
        Ok(self
            .mask(path, saved)?
            .is_some_and(|mask| self.selected(&mask)))
    }
    pub fn selected(&self, mask: &[bool]) -> bool {
        self.config
            .tree
            .as_ref()
            .map_or(mask.first().copied().unwrap_or(true), |tree| {
                tree.selected(mask)
            })
    }
}

pub fn run(json: &str) -> io::Result<()> {
    let config: Configuration = serde_json::from_str(json)?;
    let snapshot = config.snapshot;
    let deduplicate = config.roots.len() > 1;
    let predicate = Predicate::new(config)?;
    let mut seen = HashSet::new();
    let mut output = io::BufWriter::new(io::stdout());
    let mut input = io::BufReader::new(io::stdin());
    let mut bytes = Vec::new();
    while input.read_until(0, &mut bytes)? > 0 {
        if bytes.last() == Some(&0) {
            bytes.pop();
        }
        if !bytes.is_empty() {
            let record: Option<Record> = if snapshot {
                Some(serde_json::from_slice(&bytes)?)
            } else {
                None
            };
            let path = predicate.restore_root(
                record
                    .as_ref()
                    .map(|r| r.path.as_str())
                    .unwrap_or(std::str::from_utf8(&bytes).map_err(io::Error::other)?),
            );
            if predicate.matches(&path, record.as_ref())?
                && (!deduplicate || seen.insert(path.clone()))
            {
                output.write_all(path.as_bytes())?;
                output.write_all(&[0])?;
                output.flush()?;
            }
        }
        bytes.clear();
    }
    Ok(())
}
