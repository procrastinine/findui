//! Exact deduplication with a bounded resident set. Small streams stay in RAM;
//! very large explicit lists spill to a temporary SQLite primary-key table.
use std::{collections::HashSet, io};
pub(crate) struct Unique {
    values: HashSet<Vec<u8>>,
    bytes: usize,
    spill: Option<(tempfile::NamedTempFile, rusqlite::Connection)>,
}
impl Unique {
    pub fn new() -> Self { Self { values: HashSet::new(), bytes: 0, spill: None } }
    pub fn contains(&self, value: &[u8]) -> io::Result<bool> {
        if let Some((_, db)) = &self.spill {
            return db.prepare_cached("SELECT 1 FROM seen WHERE value=?").and_then(|mut s|s.exists([value])).map_err(io::Error::other)
        }
        Ok(self.values.contains(value))
    }
    pub fn insert(&mut self, value: &[u8]) -> io::Result<bool> {
        if let Some((_, db)) = &self.spill {
            return db.prepare_cached("INSERT OR IGNORE INTO seen VALUES(?)").and_then(|mut s|s.execute([value])).map(|n| n != 0).map_err(io::Error::other)
        }
        if self.values.contains(value) { return Ok(false) }
        self.bytes += value.len() + 64;
        self.values.insert(value.to_vec());
        if self.bytes > 8 * 1024 * 1024 {
            let file = tempfile::NamedTempFile::new()?;
            let db = rusqlite::Connection::open(file.path()).map_err(io::Error::other)?;
            db.execute_batch("PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA cache_size=-4096; BEGIN; CREATE TABLE seen(value BLOB PRIMARY KEY) WITHOUT ROWID;").map_err(io::Error::other)?;
            {
                let mut insert = db.prepare("INSERT INTO seen VALUES(?)").map_err(io::Error::other)?;
                for item in self.values.drain() { insert.execute([item]).map_err(io::Error::other)?; }
            }
            self.values = HashSet::new(); self.bytes = 0; self.spill = Some((file, db));
        }
        Ok(true)
    }
}
#[cfg(test)]
mod tests {
    #[test]
    fn spill_keeps_exact_membership() {
        let mut seen = super::Unique::new();
        let suffix = vec![b'x'; 2000];
        for i in 0u32..5000 { let mut value = i.to_le_bytes().to_vec(); value.extend_from_slice(&suffix); assert!(seen.insert(&value).unwrap()); }
        assert!(seen.spill.is_some()); assert!(seen.values.is_empty());
        for i in 0u32..5000 { let mut value = i.to_le_bytes().to_vec(); value.extend_from_slice(&suffix); assert!(!seen.insert(&value).unwrap()); }
        assert!(seen.insert(b"new\0path").unwrap());
    }
}
