//! Validated content expressions shared by the CLI adapters and executor.
use crate::*;

#[derive(Clone, Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub(crate) enum Tree {
    Leaf { leaf: usize },
    All { all: Vec<Tree> },
    Any { any: Vec<Tree> },
    None { none: Vec<Tree> },
}
impl Tree {
    /// (can be false, can be true). Unknown leaves remain conservative, including
    /// negation; callers may stop only when later input cannot change the result.
    pub(crate) fn possibilities(&self, values: &[(bool, bool)]) -> (bool, bool) {
        match self {
            Self::Leaf { leaf } => values[*leaf],
            Self::All { all } => all.iter().fold((false, true), |a, n| {
                let b = n.possibilities(values);
                (a.0 || b.0, a.1 && b.1)
            }),
            Self::Any { any } => any.iter().fold((true, false), |a, n| {
                let b = n.possibilities(values);
                (a.0 && b.0, a.1 || b.1)
            }),
            Self::None { none } => {
                let any = none.iter().fold((true, false), |a, n| {
                    let b = n.possibilities(values);
                    (a.0 && b.0, a.1 || b.1)
                });
                (any.1, any.0)
            }
        }
    }
    pub(crate) fn selected(&self, mask: &[bool]) -> bool {
        match self {
            Self::Leaf { leaf } => mask[*leaf],
            Self::All { all } => all.iter().all(|t| t.selected(mask)),
            Self::Any { any } => any.iter().any(|t| t.selected(mask)),
            Self::None { none } => !none.iter().any(|t| t.selected(mask)),
        }
    }
    pub(crate) fn validate(
        &self,
        count: usize,
        depth: usize,
        nodes: &mut usize,
    ) -> Result<(), String> {
        *nodes += 1;
        if depth > 12 || *nodes > 256 {
            return Err("Query exceeds 256 normalized nodes or 12 levels".into());
        }
        match self {
            Self::Leaf { leaf } if *leaf >= count => return Err("Invalid condition index".into()),
            Self::Leaf { .. } => {}
            Self::All { all: children }
            | Self::Any { any: children }
            | Self::None { none: children } => {
                for t in children {
                    t.validate(count, depth + 1, nodes)?;
                }
            }
        }
        Ok(())
    }
}
#[derive(Clone, Deserialize, Hash, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Leaf {
    #[serde(skip)]
    pub(crate) required_literals: Vec<Vec<String>>,
    #[serde(default)]
    pub(crate) pattern: String,
    #[serde(default)]
    pub(crate) regex: bool,
    #[serde(default)]
    pub(crate) terms: Vec<String>,
    #[serde(default)]
    pub(crate) distance: usize,
    #[serde(default)]
    pub(crate) ordered: bool,
    #[serde(default)]
    pub(crate) field: Option<String>,
    #[serde(default, rename = "fileIndex")]
    pub(crate) file_index: Option<usize>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Plan {
    pub(crate) tree: Tree,
    pub(crate) leaves: Vec<Leaf>,
    #[serde(default)]
    pub(crate) file_predicates: Option<crate::paths::Configuration>,
    #[serde(default)]
    pub(crate) positive: Vec<usize>,
    #[serde(default)]
    pub(crate) case_sensitive: bool,
    #[serde(default)]
    pub(crate) whole_words: bool,
    #[serde(default)]
    pub(crate) multiline: bool,
    #[serde(default)]
    pub(crate) files_only: bool,
    #[serde(default)]
    pub(crate) file_unit: bool,
    #[serde(default)]
    pub(crate) threads: usize,
    #[serde(default)]
    pub(crate) stats: bool,
    #[serde(default)]
    pub(crate) ordered: bool,
    #[serde(default)]
    pub(crate) extraction: Option<extraction::Extraction>,
    #[serde(default)]
    pub(crate) document_unit: bool,
    #[serde(default)]
    pub(crate) index_directory: Option<PathBuf>,
    #[serde(default)]
    pub(crate) index_only: bool,
    #[serde(default)]
    pub(crate) archive_names_only: bool,
    #[serde(default)]
    pub(crate) use_index: Option<bool>,
    #[serde(default)]
    pub(crate) encoding: Option<String>,
    #[serde(default)]
    pub(crate) typo_tolerance: usize,
    #[serde(default)]
    pub(crate) stem_words: bool,
    #[serde(default)]
    pub(crate) word_language: Option<String>,
    #[serde(default)]
    pub(crate) word_roots: Vec<PathBuf>,
    #[serde(default)]
    pub(crate) word_scope: Option<Value>,
    #[serde(skip)]
    pub(crate) word_candidates: bool,
    #[serde(skip)]
    pub(crate) word_selection: Option<PathBuf>,
    #[serde(skip)]
    pub(crate) word_fuzzy_order: bool,
    #[serde(skip)]
    pub(crate) word_file_masks: Option<PathBuf>,
}
