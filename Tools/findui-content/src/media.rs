//! Header metadata and text subtitles only. No audio/video transcription or OCR.
use crate::{
    documents::{Bundle, Document, Location},
    extraction::{convert, Extraction},
};
use serde_json::Value;
use std::{fs, io, path::Path, process::Command, sync::atomic::AtomicBool, time::Instant};
pub const FORMATS: &[&str] = &[
    "mp4", "m4v", "mov", "mkv", "webm", "avi", "mp3", "m4a", "aac", "flac", "ogg", "opus", "wav",
    "aiff",
];
pub fn recognizes(format: &str) -> bool {
    FORMATS.contains(&format)
}
pub fn read(
    path: &Path,
    e: &Extraction,
    stopped: &AtomicBool,
    deadline: Instant,
) -> io::Result<Bundle> {
    let probe = e.ffprobe.as_ref().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::Unsupported,
            "Install media readers: brew install ffmpeg",
        )
    })?;
    let converted = convert(
        Command::new(probe)
            .args([
                "-v",
                "error",
                "-protocol_whitelist",
                "file,pipe",
                "-show_format",
                "-show_streams",
                "-show_chapters",
                "-of",
                "json",
            ])
            .arg(path),
        e,
        stopped,
    )?;
    let metadata: Value = serde_json::from_reader(converted.reopen()?)?;
    let mut header = Document {
        text: serde_json::to_string_pretty(&metadata)?,
        ..Default::default()
    };
    header
        .metadata
        .insert("finduiRequiresMedia".into(), "true".into());
    header
        .metadata
        .insert("finduiReader".into(), "Media metadata".into());
    for (field, tag) in [("title", "title"), ("author", "artist")] {
        if let Some(value) = metadata["format"]["tags"][tag].as_str() {
            header.metadata.insert(field.into(), value.into());
        }
    }
    let mut bundle = Bundle {
        documents: vec![header],
        ..Default::default()
    };
    let mut bytes = bundle.documents[0].text.len() as u64;
    if let Some(streams) = metadata["streams"].as_array() {
        for stream in streams
            .iter()
            .filter(|s| s["codec_type"] == "subtitle")
            .take(128)
        {
            let Some(index) = stream["index"].as_u64() else {
                continue;
            };
            let codec = stream["codec_name"].as_str().unwrap_or("");
            if ![
                "subrip", "ass", "ssa", "mov_text", "webvtt", "text", "microdvd",
            ]
            .contains(&codec)
            {
                bundle.warnings.push(format!(
                    "Subtitle stream {index} ({codec}) has no supported text layer"
                ));
                continue;
            }
            let Some(ffmpeg) = &e.ffmpeg else {
                bundle
                    .warnings
                    .push("Install subtitle support: brew install ffmpeg".into());
                continue;
            };
            let mut limits = e.clone();
            limits.timeout_seconds = e
                .timeout_seconds
                .min(deadline.saturating_duration_since(Instant::now()).as_secs());
            if limits.timeout_seconds == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "Media reader timed out",
                ));
            }
            let output = convert(
                Command::new(ffmpeg)
                    .args([
                        "-nostdin",
                        "-v",
                        "error",
                        "-protocol_whitelist",
                        "file,pipe",
                        "-i",
                    ])
                    .arg(path)
                    .args([
                        "-map",
                        &format!("0:{index}"),
                        "-vn",
                        "-an",
                        "-dn",
                        "-f",
                        "srt",
                        "-",
                    ]),
                &limits,
                stopped,
            )?;
            let text = fs::read_to_string(output.path())?;
            bytes += text.len() as u64;
            if bytes > e.max_megabytes * 1024 * 1024 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Media text exceeds the configured size limit",
                ));
            }
            let locations = text
                .lines()
                .enumerate()
                .filter(|(_, s)| s.contains(" --> "))
                .map(|(i, s)| Location {
                    line: i as u64 + 1,
                    timecode: Some(s.split(" --> ").next().unwrap().into()),
                    ..Default::default()
                })
                .collect();
            bundle.documents.push(Document {
                text,
                locations,
                metadata: [
                    ("finduiRequiresMedia".into(), "true".into()),
                    ("finduiReader".into(), format!("Subtitles · stream {index}")),
                    ("finduiRecord".into(), format!("subtitle:{index}")),
                    (
                        "title".into(),
                        stream["tags"]["title"]
                            .as_str()
                            .unwrap_or("Subtitles")
                            .into(),
                    ),
                ]
                .into(),
                ..Default::default()
            });
        }
        if streams
            .iter()
            .filter(|s| s["codec_type"] == "subtitle")
            .count()
            > 128
        {
            bundle
                .warnings
                .push("Media subtitle limit reached (128 streams)".into());
        }
    }
    Ok(bundle)
}
