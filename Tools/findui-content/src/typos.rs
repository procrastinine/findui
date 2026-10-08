//! Explicit word/phrase typo matching. A prepared bit-parallel Levenshtein
//! comparator is reused for every candidate, with a maximum edit cutoff.
use rapidfuzz::distance::levenshtein::{Args, BatchComparator};
use unicode_normalization::UnicodeNormalization;
pub struct Typos {
    matcher: BatchComparator<char>,
    words: regex::bytes::Regex,
    count: usize,
    edits: usize,
    sensitive: bool,
}
fn normalize(text: &str, sensitive: bool) -> String {
    let text: String = text.nfc().collect();
    if sensitive {
        text
    } else {
        text.to_lowercase()
    }
}
impl Typos {
    pub fn new(pattern: &str, edits: usize, sensitive: bool) -> Result<Self, String> {
        let words = regex::bytes::Regex::new(r"\w+").unwrap();
        let count = words.find_iter(pattern.as_bytes()).count();
        if !(1..=2).contains(&edits) || count == 0 || count > 32 || pattern.chars().count() > 512 {
            return Err(
                "Typo matching needs 1–32 words, at most 512 characters, and 1–2 edits".into(),
            );
        }
        Ok(Self {
            matcher: BatchComparator::new(normalize(pattern, sensitive).chars()),
            words,
            count,
            edits,
            sensitive,
        })
    }
    pub fn ranges(&self, bytes: &[u8]) -> Vec<(usize, usize)> {
        let words: Vec<_> = self.words.find_iter(bytes).collect();
        let mut result = Vec::new();
        for start in 0..words.len() {
            for length in self.count.saturating_sub(self.edits).max(1)..=self.count + self.edits {
                if start + length > words.len() {
                    break;
                }
                let a = words[start].start();
                let b = words[start + length - 1].end();
                let text = normalize(&String::from_utf8_lossy(&bytes[a..b]), self.sensitive);
                if self
                    .matcher
                    .distance_with_args(text.chars(), &Args::default().score_cutoff(self.edits))
                    .is_some()
                {
                    result.push((a, b));
                }
            }
        }
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn edits_and_raw_offsets() {
        let m = Typos::new("needle", 1, false).unwrap();
        assert_eq!(m.ranges(b"\xff needl"), vec![(2, 7)]);
        assert!(m.ranges(b"noodle").is_empty());
        assert_eq!(
            Typos::new("café", 1, false)
                .unwrap()
                .ranges("CAFÉ".as_bytes()),
            vec![(0, 5)]
        );
        assert!(!Typos::new("hello world", 1, false)
            .unwrap()
            .ranges(b"hello wurld")
            .is_empty());
    }
}
