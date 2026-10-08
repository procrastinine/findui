//! Explicit argv adapters. Configuration is data, never a shell command.
use crate::{
    documents::{Bundle, Document},
    extraction::{convert, Extraction},
};
use serde::{Deserialize, Serialize};
use std::{
    fs, io,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::AtomicBool,
};

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Adapter {
    pub id: String,
    pub title: String,
    pub extensions: Vec<String>,
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    #[serde(default = "enabled")]
    pub enabled: bool,
}
fn enabled() -> bool {
    true
}
impl Adapter {
    pub fn validate(&self) -> io::Result<()> {
        if self.id.is_empty()
            || self.id.len() > 128
            || self.title.is_empty()
            || !self.executable.is_absolute()
            || self.extensions.is_empty()
            || self.extensions.len() > 64
            || self.extensions.iter().any(|s| {
                s.is_empty()
                    || s.len() > 32
                    || !s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
            })
            || self.arguments.len() > 128
            || !self.arguments.iter().any(|s| s.contains("{path}"))
            || self
                .arguments
                .iter()
                .any(|s| s.contains('\0') || s.len() > 65536)
        {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "A reader needs an ID, title, extensions, absolute executable and argv containing {path}"));
        }
        Ok(())
    }
    pub fn read(&self, path: &Path, e: &Extraction, stopped: &AtomicBool) -> io::Result<Bundle> {
        self.validate()?;
        let mut command = Command::new(&self.executable);
        for arg in &self.arguments {
            command.arg(arg.replace("{path}", &path.to_string_lossy()));
        }
        let file = convert(&mut command, e, stopped)?;
        let text = fs::read_to_string(file.path())?;
        Ok(Bundle {
            documents: vec![Document {
                text,
                metadata: [
                    ("finduiAdapter".into(), self.id.clone()),
                    ("finduiReader".into(), self.title.clone()),
                ]
                .into(),
                ..Default::default()
            }],
            ..Default::default()
        })
    }
}
