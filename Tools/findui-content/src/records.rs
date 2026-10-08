//! Borrowed serialization for the hot result path. Avoid allocating a JSON
//! object/map for every key, path, snippet and submatch of every matching line.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Serialize, ser::SerializeSeq};
use serde_json::Value;
use std::io;

#[derive(Serialize)]
struct Text<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    bytes: Option<String>,
}
impl<'a> Text<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        match std::str::from_utf8(bytes) {
            Ok(text) => Self { text: Some(text), bytes: None },
            Err(_) => Self { text: None, bytes: Some(STANDARD.encode(bytes)) },
        }
    }
}
#[derive(Serialize)]
struct Submatch<'a> {
    r#match: Text<'a>,
    start: usize,
    end: usize,
}
struct Submatches<'a> { bytes: &'a [u8], ranges: &'a [(usize, usize)] }
impl Serialize for Submatches<'_> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(Some(self.ranges.len()))?;
        for &(start, end) in self.ranges {
            sequence.serialize_element(&Submatch { r#match: Text::new(&self.bytes[start..end]), start, end })?;
        }
        sequence.end()
    }
}
#[derive(Serialize)]
struct MatchData<'a> {
    path: Text<'a>,
    lines: Text<'a>,
    line_number: Option<u64>,
    absolute_offset: u64,
    submatches: Submatches<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    findui_origin: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    findui_tags: Option<&'a [String]>,
}
#[derive(Serialize)]
struct Record<'a> {
    r#type: &'static str,
    data: MatchData<'a>,
}
pub(crate) fn encode_into(output: &mut Vec<u8>, path: &[u8], bytes: &[u8], line: Option<u64>, offset: u64,
                    ranges: &[(usize, usize)], origin: Option<Value>, tags: Option<&[String]>) -> io::Result<()> {
    let record = Record {
        r#type: "match",
        data: MatchData {
            path: Text::new(path), lines: Text::new(bytes), line_number: line, absolute_offset: offset,
            submatches: Submatches { bytes, ranges },
            findui_origin: origin, findui_tags: tags,
        },
    };
    output.clear();
    serde_json::to_writer(&mut *output, &record)?;
    output.push(b'\n');
    Ok(())
}
