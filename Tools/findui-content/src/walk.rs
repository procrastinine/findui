//! The same ignore/walk library used by fd and ripgrep, with one explicit
//! policy for every FindUI route. Ignored subtrees are pruned during traversal.
use ignore::{WalkBuilder, WalkState};
use serde::Deserialize;
use std::{
    collections::HashMap,
    fs,
    io::{self, BufRead, Write},
    os::unix::ffi::{OsStrExt, OsStringExt},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering::Relaxed},
        Mutex,
    },
};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Configuration {
    pub roots: Vec<PathBuf>,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub ignored: bool,
    #[serde(default)]
    pub ignore_policy: String,
    #[serde(default)]
    pub follow: bool,
    #[serde(default)]
    pub minimum_depth: usize,
    pub maximum_depth: Option<usize>,
    #[serde(default)]
    pub excluded_folders: Vec<String>,
    #[serde(default)]
    pub excluded_paths: Vec<PathBuf>,
    #[serde(default)]
    pub path_rules: Vec<String>,
    pub rule_root: Option<PathBuf>,
    #[serde(default)]
    pub package_extensions: Vec<String>,
    #[serde(default)]
    pub packages: bool,
    #[serde(default)]
    pub threads: usize,
    #[serde(default)]
    pub kind: String,
    pub minimum: Option<u64>,
    pub maximum: Option<u64>,
}
impl Configuration {
    pub fn validate(&self) -> io::Result<()> {
        if self.roots.is_empty()
            || self.threads > 64
            || self.maximum_depth.is_some_and(|m| m < self.minimum_depth)
        {
            return Err(io::Error::other("Invalid traversal options"));
        }
        for root in &self.roots {
            if !root.is_dir() {
                return Err(io::Error::other(format!(
                    "Search folder is unavailable: {}",
                    root.display()
                )));
            }
        }
        Ok(())
    }
    pub fn builder(&self) -> io::Result<WalkBuilder> {
        let mut b = WalkBuilder::new(&self.roots[0]);
        for root in self.roots.iter().skip(1) {
            b.add(root);
        }
        b.standard_filters(!self.ignored)
            .hidden(!self.hidden)
            .follow_links(self.follow)
            .max_depth(self.maximum_depth)
            .min_depth(Some(self.minimum_depth))
            .threads(self.threads);
        if !self.ignored {
            if self.ignore_policy != "ripgrep" {
                b.add_custom_ignore_filename(".fdignore");
            }
            if self.ignore_policy != "fd" {
                b.add_custom_ignore_filename(".rgignore");
            }
            let config = std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")));
            if let Some(global) = config
                .filter(|_| self.ignore_policy != "ripgrep")
                .map(|p| p.join("fd/ignore"))
                .filter(|p| p.is_file())
            {
                if let Some(error) = b.add_ignore(global) {
                    eprintln!("findui-ignore: {error}");
                }
            }
        }
        if !self.path_rules.is_empty() {
            let root = self.rule_root.as_ref().unwrap_or(&self.roots[0]);
            let mut rules = ignore::overrides::OverrideBuilder::new(root);
            for pattern in &self.path_rules {
                rules.add(pattern).map_err(io::Error::other)?;
            }
            b.overrides(rules.build().map_err(io::Error::other)?);
        }
        let config = self.clone();
        let excluded = self.excluded_paths();
        b.filter_entry(move |entry| {
            if excluded.iter().any(|p| entry.path().starts_with(p)) {
                return false;
            }
            if entry.depth() == 0 {
                return true;
            }
            (config.hidden || !entry.file_name().as_bytes().starts_with(b"."))
                && !config.within_package(entry.path())
                && (!entry.file_type().is_some_and(|t| t.is_dir())
                    || !config.excluded_directory(entry.path()))
        });
        Ok(b)
    }
    pub(crate) fn excluded_directory(&self, path: &Path) -> bool {
        let name = path.file_name().unwrap_or_default().to_string_lossy();
        self.excluded_folders.iter().any(|n| n == &name)
    }
    pub(crate) fn excluded_paths(&self) -> Vec<PathBuf> {
        let aliases = RootAliases::new(&self.roots);
        self.excluded_paths
            .iter()
            .flat_map(|path| {
                let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.clone());
                [path.clone(), aliases.restore(canonical, true)]
            })
            .collect()
    }
    pub(crate) fn within_package(&self, path: &Path) -> bool {
        if self.packages {
            return false;
        }
        let mut relatives = self
            .roots
            .iter()
            .filter_map(|r| path.strip_prefix(r).ok())
            .peekable();
        relatives.peek().is_some()
            && relatives.all(|relative| {
                relative.parent().is_some_and(|p| {
                    p.components().any(|c| {
                        Path::new(c.as_os_str()).extension().is_some_and(|e| {
                            self.package_extensions
                                .iter()
                                .any(|x| e.to_string_lossy().eq_ignore_ascii_case(x))
                        })
                    })
                })
            })
    }
    pub(crate) fn kind_admitted(&self, directory: bool) -> bool {
        !(self.kind == "f" && directory || self.kind == "d" && !directory)
    }
}
/// Preserve the selected root's spelling when a NUL list uses its canonical
/// alias (e.g. /private/var versus /var). Never resolve child symlinks here.
#[derive(Clone)]
pub(crate) struct RootAliases(Vec<(PathBuf, PathBuf)>);
impl RootAliases {
    pub(crate) fn new(roots: &[PathBuf]) -> Self {
        Self(
            roots
                .iter()
                .map(|root| {
                    (
                        root.clone(),
                        fs::canonicalize(root).unwrap_or_else(|_| root.clone()),
                    )
                })
                .collect(),
        )
    }
    pub(crate) fn restore(&self, path: PathBuf, follow: bool) -> PathBuf {
        if self.0.iter().any(|(root, _)| path.starts_with(root)) {
            return path;
        }
        for (selected, canonical) in &self.0 {
            if let Ok(relative) = path.strip_prefix(canonical) {
                return selected.join(relative);
            }
        }
        // A supplied list can use another root alias too. Preserve the
        // no-follow policy for a leaf symlink before resolving its parents.
        if !follow && fs::symlink_metadata(&path).is_ok_and(|m| m.file_type().is_symlink()) {
            return path;
        }
        if let Ok(resolved) = fs::canonicalize(&path) {
            for (selected, canonical) in &self.0 {
                if let Ok(relative) = resolved.strip_prefix(canonical) {
                    return selected.join(relative);
                }
            }
        }
        path
    }
}
#[derive(Clone, Default)]
pub(crate) struct Ancestors(HashMap<(PathBuf, PathBuf), bool>);
impl Ancestors {
    pub(crate) fn reachable(&mut self, root: &Path, path: &Path) -> io::Result<bool> {
        if path == root {
            return Ok(true);
        }
        let Some(parent) = path.parent() else {
            return Ok(false);
        };
        if parent == root {
            return Ok(true);
        }
        if !parent.starts_with(root) {
            return Ok(false);
        }
        let key = (root.to_owned(), parent.to_owned());
        if let Some(allowed) = self.0.get(&key) {
            return Ok(*allowed);
        }
        let allowed = match fs::symlink_metadata(parent) {
            Ok(metadata) => metadata.is_dir() && self.reachable(root, parent)?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => false,
            Err(error) => return Err(error),
        };
        self.0.insert(key, allowed);
        Ok(allowed)
    }
}
pub fn run(json: &str) -> io::Result<()> {
    let config: Configuration = serde_json::from_str(json)?;
    config.validate()?;
    let mut b = config.builder()?;
    let coverage_path = std::env::var_os("FINDUI_WORD_COVERAGE");
    let word_roots = crate::word_state::RootMap::new(&config.roots);
    let coverage = Mutex::new(crate::word_state::Coverage {
        roots: word_roots.canonical().cloned().collect(),
        ..Default::default()
    });
    if coverage_path.is_some() {
        b.min_depth(Some(0));
    }
    // Prune package descendants but keep the package directory itself visible.
    let prune = config.clone();
    let excluded = config.excluded_paths();
    b.filter_entry(move |entry| {
        !excluded.iter().any(|p| entry.path().starts_with(p))
            && (entry.depth() == 0
                || ((prune.hidden || !entry.file_name().as_bytes().starts_with(b"."))
                    && !prune.within_package(entry.path())
                    && !(entry.file_type().is_some_and(|t| t.is_dir())
                        && prune.excluded_directory(entry.path()))))
    });
    let stopped = AtomicBool::new(false);
    let failed = AtomicBool::new(false);
    let output = Mutex::new((io::BufWriter::new(io::stdout()), true));
    b.build_parallel().run(|| {
        Box::new(|entry| {
            if stopped.load(Relaxed) {
                return WalkState::Quit;
            }
            let entry = match entry {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("findui-walk: {e}");
                    failed.store(true, Relaxed);
                    return WalkState::Continue;
                }
            };
            let Some(kind) = entry.file_type() else {
                return WalkState::Continue;
            };
            if coverage_path.is_some() && kind.is_dir() {
                match word_roots.stored(entry.path()).and_then(|p| {
                    crate::content_index::identity(&p, "word-directory-v1").map(|id| (p, id))
                }) {
                    Ok((path, identity)) => {
                        coverage.lock().unwrap().directories.insert(path, identity);
                    }
                    Err(_) => {
                        failed.store(true, Relaxed);
                    }
                }
            }
            if entry.depth() < config.minimum_depth
                || (!kind.is_file() && !kind.is_dir())
                || !config.kind_admitted(kind.is_dir())
            {
                return WalkState::Continue;
            }
            if config.minimum.is_some() || config.maximum.is_some() {
                let m = match entry.metadata() {
                    Ok(m) => m,
                    Err(e) => {
                        eprintln!("findui-walk: {e}");
                        failed.store(true, Relaxed);
                        return WalkState::Continue;
                    }
                };
                if kind.is_dir()
                    || config.minimum.is_some_and(|s| m.len() < s)
                    || config.maximum.is_some_and(|s| m.len() > s)
                {
                    return WalkState::Continue;
                }
            }
            let mut out = output.lock().unwrap();
            let result = (|| {
                out.0.write_all(entry.path().as_os_str().as_bytes())?;
                out.0.write_all(&[0])?;
                if out.1 {
                    out.0.flush()?;
                    out.1 = false;
                }
                Ok::<_, io::Error>(())
            })();
            if result.is_err() {
                stopped.store(true, Relaxed);
                WalkState::Quit
            } else {
                WalkState::Continue
            }
        })
    });
    output.lock().unwrap().0.flush()?;
    if let Some(path) = coverage_path {
        let mut coverage = coverage.into_inner().unwrap();
        coverage.complete = !failed.load(Relaxed) && !stopped.load(Relaxed);
        fs::write(path, serde_json::to_vec(&coverage)?)?;
    }
    // Recoverable directory errors remain explicit diagnostics. Like fd, a
    // partial traversal can still publish its useful results and warning.
    Ok(())
}
/// Incremental ignore admission for explicit candidate lists. The same matcher
/// configuration is used by a live walk; parent ignore files are cached.
#[derive(Clone)]
pub(crate) struct Admission {
    config: Configuration,
    aliases: RootAliases,
    excluded: Vec<PathBuf>,
    ancestors: Ancestors,
    matchers: Vec<ignore::IncrementalIgnore>,
}
impl Admission {
    pub(crate) fn new(config: Configuration) -> io::Result<Self> {
        config.validate()?;
        Ok(Self {
            aliases: RootAliases::new(&config.roots),
            excluded: config.excluded_paths(),
            matchers: config.builder()?.build_matchers(),
            ancestors: Ancestors::default(),
            config,
        })
    }
    pub(crate) fn normalize(&self, path: PathBuf) -> PathBuf {
        self.aliases.restore(path, self.config.follow)
    }
    pub(crate) fn admit(&mut self, raw: PathBuf) -> io::Result<Option<(PathBuf, fs::Metadata)>> {
        let config = &self.config;
        let path = self.normalize(raw);
        if self.excluded.iter().any(|p| path.starts_with(p)) {
            return Ok(None);
        }
        let m = match if config.follow || config.roots.contains(&path) {
            fs::metadata(&path)
        } else {
            fs::symlink_metadata(&path)
        } {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        };
        if (!m.is_file() && !m.is_dir())
            || !config.kind_admitted(m.is_dir())
            || config.within_package(&path)
            || ((config.minimum.is_some() || config.maximum.is_some())
                && (!m.is_file()
                    || config.minimum.is_some_and(|s| m.len() < s)
                    || config.maximum.is_some_and(|s| m.len() > s)))
        {
            return Ok(None);
        }
        for matcher in &mut self.matchers {
            let Some(relative) = matcher.normalize(&path) else {
                continue;
            };
            if !config.hidden
                && relative
                    .components()
                    .any(|c| c.as_os_str().as_bytes().starts_with(b"."))
            {
                continue;
            }
            if !config.follow && !self.ancestors.reachable(matcher.root(), &path)? {
                continue;
            }
            let parent = if m.is_dir() {
                relative.as_path()
            } else {
                relative.parent().unwrap_or(Path::new(""))
            };
            if parent
                .components()
                .any(|p| config.excluded_directory(Path::new(p.as_os_str())))
            {
                continue;
            }
            let (matched, error) = matcher.matched_with_errors(relative, m.is_dir());
            if let Some(error) = error {
                return Err(io::Error::other(error));
            }
            if !matched.is_ignore() && matched.is_within_depth() {
                return Ok(Some((path, m)));
            }
        }
        Ok(None)
    }
}
pub fn admit(json: &str) -> io::Result<()> {
    let mut admission = Admission::new(serde_json::from_str(json)?)?;
    let mut output = io::BufWriter::new(io::stdout());
    for raw in io::BufReader::new(io::stdin()).split(0) {
        let raw = raw?;
        if raw.is_empty() {
            continue;
        }
        if let Some((path, _)) =
            admission.admit(PathBuf::from(std::ffi::OsString::from_vec(raw)))?
        {
            output.write_all(path.as_os_str().as_bytes())?;
            output.write_all(&[0])?;
        }
    }
    output.flush()
}

pub fn explain(json: &str) -> io::Result<()> {
    #[derive(Deserialize)]
    struct Request {
        path: PathBuf,
        walk: Configuration,
    }
    let request: Request = serde_json::from_str(json)?;
    let config = request.walk;
    config.validate()?;
    let path = RootAliases::new(&config.roots).restore(request.path, config.follow);
    let mut reason = String::new();
    let mut accepted = false;
    let mut ancestors = Ancestors::default();
    let metadata = if config.follow || config.roots.contains(&path) {
        fs::metadata(&path)
    } else {
        fs::symlink_metadata(&path)
    };
    match metadata {
        Err(error) => reason = error.to_string(),
        Ok(m) => {
            if config.excluded_paths().iter().any(|p| path.starts_with(p)) {
                reason = "FindUI's generated search cache is excluded from content searches".into();
            } else if m.file_type().is_symlink() && !config.follow {
                reason = "Symbolic links are not followed in this search".into();
            } else if !m.is_file() && !m.is_dir() {
                reason = "This item is not a regular file or directory".into();
            } else if !config.kind_admitted(m.is_dir()) {
                reason = "The selected file/directory type excludes this item".into();
            } else if config.within_package(&path) {
                reason = "Package contents are disabled".into();
            } else {
                for mut matcher in config.builder()?.build_matchers() {
                    let Some(relative) = matcher.normalize(&path) else {
                        continue;
                    };
                    if !config.follow && !ancestors.reachable(matcher.root(), &path)? {
                        reason =
                            "Inside a symbolic-link directory; following links is disabled".into();
                        continue;
                    }
                    let depth = relative.components().count();
                    if depth < config.minimum_depth
                        || config.maximum_depth.is_some_and(|max| depth > max)
                    {
                        reason = "Outside the configured folder depth".into();
                        continue;
                    }
                    let directories = if m.is_dir() {
                        relative.as_path()
                    } else {
                        relative.parent().unwrap_or(Path::new(""))
                    };
                    if directories
                        .components()
                        .any(|c| config.excluded_directory(Path::new(c.as_os_str())))
                    {
                        reason = "Inside an excluded directory".into();
                        continue;
                    }
                    let (result, error) = matcher.matched_with_errors(relative, m.is_dir());
                    if let Some(error) = error {
                        reason = error.to_string();
                        continue;
                    }
                    if result.is_ignore() {
                        reason="Excluded by path patterns or the shared ignore-file policy (.gitignore, .ignore, .fdignore, .rgignore or global ignores)".into();
                        continue;
                    }
                    if ((config.minimum.is_some() || config.maximum.is_some()) && m.is_dir())
                        || config.minimum.is_some_and(|n| m.len() < n)
                        || config.maximum.is_some_and(|n| m.len() > n)
                    {
                        reason = "Outside the configured file size range".into();
                        continue;
                    }
                    accepted = true;
                    reason = "Included by scope, traversal and ignore settings".into();
                    break;
                }
                if reason.is_empty() {
                    reason = "Outside the selected search folders".into();
                }
            }
        }
    }
    let format = if accepted && path.is_file() {
        crate::formats::detect(&path).ok()
    } else {
        None
    };
    println!(
        "{}",
        serde_json::json!({"path":path,"admitted":accepted,"reason":reason,"format":format})
    );
    Ok(())
}
