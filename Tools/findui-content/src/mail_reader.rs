use crate::documents::{Document, Member};
use mailparse::{DispositionType, MailHeaderMap, ParsedMail};
use std::{io, path::Path};
pub struct Attachment {
    pub member: Member,
    pub bytes: Vec<u8>,
}
pub fn messages(bytes: &[u8], mailbox: bool) -> Vec<&[u8]> {
    if !mailbox {
        return vec![bytes];
    }
    let mut starts = Vec::new();
    let mut offset = 0;
    for line in bytes.split_inclusive(|b| *b == b'\n') {
        if line.starts_with(b"From ") {
            starts.push((offset, offset + line.len()));
        }
        offset += line.len();
    }
    if starts.is_empty() {
        return vec![bytes];
    }
    starts
        .iter()
        .enumerate()
        .map(|(i, (_, body))| &bytes[*body..starts.get(i + 1).map_or(bytes.len(), |s| s.0)])
        .collect()
}
fn filename(part: &ParsedMail<'_>) -> Option<String> {
    part.get_content_disposition()
        .params
        .get("filename")
        .cloned()
        .or_else(|| part.ctype.params.get("name").cloned())
}
fn is_attachment(part: &ParsedMail<'_>) -> bool {
    part.get_content_disposition().disposition == DispositionType::Attachment
        || filename(part).is_some()
        || part.ctype.mimetype == "message/rfc822"
}
fn body(part: &ParsedMail<'_>, depth: usize) -> io::Result<String> {
    if depth > 32 {
        return Err(io::Error::other("Email exceeds 32 MIME nesting levels"));
    }
    if is_attachment(part) {
        return Ok(String::new());
    }
    if !part.subparts.is_empty() {
        if part.ctype.mimetype == "multipart/alternative" {
            if let Some(plain) = part
                .subparts
                .iter()
                .find(|p| p.ctype.mimetype == "text/plain" && !is_attachment(p))
            {
                return body(plain, depth + 1);
            }
            if let Some(html) = part
                .subparts
                .iter()
                .find(|p| p.ctype.mimetype == "text/html" && !is_attachment(p))
            {
                return body(html, depth + 1);
            }
        }
        return part
            .subparts
            .iter()
            .map(|p| body(p, depth + 1))
            .collect::<io::Result<Vec<_>>>()
            .map(|v| v.join("\n"));
    }
    if part.ctype.mimetype == "text/plain" {
        return part.get_body().map_err(io::Error::other);
    }
    if part.ctype.mimetype == "text/html" {
        return html2text::from_read(
            part.get_body().map_err(io::Error::other)?.as_bytes(),
            usize::MAX / 16,
        )
        .map_err(io::Error::other);
    }
    Ok(String::new())
}
pub fn read(
    bytes: &[u8],
    format: &str,
    members: &[Member],
    attachments: bool,
) -> io::Result<(Vec<Document>, Vec<Attachment>)> {
    let mut documents = Vec::new();
    let mut files = Vec::new();
    let messages = messages(bytes, format == "mbox");
    if messages.len() > 100_000 {
        return Err(io::Error::other("Mailbox exceeds 100,000 messages"));
    }
    for (number, bytes) in messages.into_iter().enumerate() {
        let mail = mailparse::parse_mail(bytes).map_err(io::Error::other)?;
        let mut text = String::new();
        for header in ["From", "To", "Cc", "Subject", "Date"] {
            if let Some(value) = mail.headers.get_first_value(header) {
                text.push_str(&format!("{header}: {value}\n"));
            }
        }
        text.push('\n');
        text.push_str(&body(&mail, 0)?);
        let mut metadata = std::collections::BTreeMap::new();
        metadata.insert("finduiRequiresDocuments".into(), "true".into());
        if let Some(value) = mail.headers.get_first_value("Subject") {
            metadata.insert("title".into(), value);
        }
        if let Some(value) = mail.headers.get_first_value("From") {
            metadata.insert("author".into(), value);
        }
        metadata.insert("message".into(), (number + 1).to_string());
        metadata.insert("finduiRecord".into(), format!("message:{}", number + 1));
        documents.push(Document {
            members: members.into(),
            text,
            metadata,
            ..Default::default()
        });
        if attachments {
            for (part_index, part) in mail.parts().enumerate().filter(|(_, p)| is_attachment(p)) {
                let name = filename(part).unwrap_or_else(|| {
                    if part.ctype.mimetype == "message/rfc822" {
                        "message.eml".into()
                    } else {
                        format!("attachment-{part_index}")
                    }
                });
                files.push(Attachment {
                    member: Member {
                        name,
                        index: ((number as u64) << 32) | part_index as u64,
                        kind: Some("mail".into()),
                    },
                    bytes: part.get_body_raw().map_err(io::Error::other)?,
                });
            }
        }
    }
    Ok((documents, files))
}
pub fn attachment(path: &Path, member: &Member, limit: u64) -> io::Result<Vec<u8>> {
    use std::io::Read;
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::other("Mailbox exceeds the size limit"));
    }
    let messages = messages(&bytes, crate::formats::detect(path)? == "mbox");
    let source = messages
        .get((member.index >> 32) as usize)
        .ok_or_else(|| io::Error::other("Message no longer exists"))?;
    let mail = mailparse::parse_mail(source).map_err(io::Error::other)?;
    let part = mail
        .parts()
        .nth((member.index & 0xffff_ffff) as usize)
        .ok_or_else(|| io::Error::other("Attachment no longer exists"))?;
    part.get_body_raw().map_err(io::Error::other)
}
