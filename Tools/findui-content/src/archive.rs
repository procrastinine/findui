//! Streaming libarchive access. Member names are data, never extraction paths.
use std::{
    ffi::{c_char, c_int, c_void, CStr, CString},
    io,
    os::unix::ffi::OsStrExt,
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};

#[link(name = "archive")]
unsafe extern "C" {
    fn archive_version_number() -> c_int;
    fn archive_read_new() -> *mut c_void;
    fn archive_read_support_filter_all(a: *mut c_void) -> c_int;
    fn archive_read_support_format_all(a: *mut c_void) -> c_int;
    fn archive_read_support_format_raw(a: *mut c_void) -> c_int;
    fn archive_read_open_filename(a: *mut c_void, path: *const c_char, block: usize) -> c_int;
    fn archive_read_next_header(a: *mut c_void, entry: *mut *mut c_void) -> c_int;
    fn archive_read_data(a: *mut c_void, buffer: *mut c_void, length: usize) -> isize;
    fn archive_read_data_skip(a: *mut c_void) -> c_int;
    fn archive_read_free(a: *mut c_void) -> c_int;
    fn archive_error_string(a: *mut c_void) -> *const c_char;
    fn archive_entry_pathname_utf8(entry: *mut c_void) -> *const c_char;
    fn archive_entry_pathname(entry: *mut c_void) -> *const c_char;
    fn archive_entry_filetype(entry: *mut c_void) -> libc::mode_t;
    fn archive_entry_size(entry: *mut c_void) -> i64;
    fn archive_format(a: *mut c_void) -> c_int;
}
pub fn version() -> c_int {
    unsafe { archive_version_number() }
}

pub struct Reader(*mut c_void);
impl Drop for Reader {
    fn drop(&mut self) {
        unsafe {
            archive_read_free(self.0);
        }
    }
}
impl Reader {
    fn error(&self) -> io::Error {
        let raw = unsafe { archive_error_string(self.0) };
        io::Error::other(if raw.is_null() {
            "Archive reader failed".into()
        } else {
            unsafe { CStr::from_ptr(raw) }
                .to_string_lossy()
                .into_owned()
        })
    }
    pub fn open(path: &Path) -> io::Result<Self> {
        let path = CString::new(path.as_os_str().as_bytes())?;
        let this = Self(unsafe { archive_read_new() });
        if this.0.is_null() {
            return Err(io::Error::other("Cannot create archive reader"));
        }
        unsafe {
            archive_read_support_filter_all(this.0);
            archive_read_support_format_all(this.0);
            archive_read_support_format_raw(this.0);
            if archive_read_open_filename(this.0, path.as_ptr(), 64 * 1024) != 0 {
                return Err(this.error());
            }
        }
        Ok(this)
    }

    /// Read only the central directory. rawzip has no decompressor attached;
    /// even encrypted data and symlink targets remain unread and unexpanded.
    pub fn zip_names(
        path: &Path,
        stopped: &AtomicBool,
        deadline: Instant,
    ) -> io::Result<Vec<(u64, String, bool)>> {
        let mut buffer = vec![0; rawzip::RECOMMENDED_BUFFER_SIZE];
        let archive = rawzip::ZipArchive::from_file(std::fs::File::open(path)?, &mut buffer)
            .map_err(io::Error::other)?;
        if archive.entries_hint() > 100_000 {
            return Err(io::Error::other("ZIP exceeds 100,000 members"));
        }
        let mut entries = Vec::new();
        let mut names_bytes = 0;
        let mut iterator = archive.entries(&mut buffer);
        while let Some(entry) = iterator.next_entry().map_err(io::Error::other)? {
            if stopped.load(Ordering::Relaxed) || Instant::now() > deadline {
                return Err(io::Error::other(
                    "Archive name search cancelled or timed out",
                ));
            }
            let name = zip_name(
                entry.file_path().as_ref(),
                entry.flags().is_utf8(),
                entry.extra_fields(),
            )?;
            names_bytes += name.len();
            if entries.len() >= 100_000 || names_bytes > 64 * 1024 * 1024 {
                return Err(io::Error::other("ZIP directory exceeds the metadata limit"));
            }
            entries.push((entries.len() as u64, name, entry.is_dir()));
        }
        if entries.len() as u64 != archive.entries_hint() {
            return Err(io::Error::other("Incomplete ZIP central directory"));
        }
        Ok(entries)
    }
    pub fn visit_selected(
        &mut self,
        limit: u64,
        stopped: &AtomicBool,
        deadline: Instant,
        select: impl FnMut(u64, &str) -> bool,
        receive: impl FnMut(u64, String, Vec<u8>, bool) -> io::Result<bool>,
    ) -> io::Result<()> {
        self.visit_internal(limit, stopped, deadline, false, select, receive)
    }
    pub fn visit_search(
        &mut self,
        limit: u64,
        stopped: &AtomicBool,
        deadline: Instant,
        select: impl FnMut(u64, &str) -> bool,
        receive: impl FnMut(u64, String, Vec<u8>, bool) -> io::Result<bool>,
    ) -> io::Result<()> {
        self.visit_internal(limit, stopped, deadline, true, select, receive)
    }
    fn visit_internal(
        &mut self,
        limit: u64,
        stopped: &AtomicBool,
        deadline: Instant,
        keep_containers: bool,
        mut select: impl FnMut(u64, &str) -> bool,
        mut receive: impl FnMut(u64, String, Vec<u8>, bool) -> io::Result<bool>,
    ) -> io::Result<()> {
        let mut index = 0;
        loop {
            if stopped.load(Ordering::Relaxed) || Instant::now() > deadline {
                return Err(io::Error::other("Archive search cancelled or timed out"));
            }
            let mut entry = std::ptr::null_mut();
            let status = unsafe { archive_read_next_header(self.0, &mut entry) };
            if status == 1 {
                return Ok(());
            }
            if status != 0 || entry.is_null() {
                return Err(self.error());
            }
            let member_index = index;
            index += 1;
            if index > 100_000 {
                return Err(io::Error::other("Archive exceeds 100,000 members"));
            }
            let kind = unsafe { archive_entry_filetype(entry) };
            if kind != 0 && kind != libc::S_IFREG {
                unsafe {
                    archive_read_data_skip(self.0);
                }
                continue;
            }
            let raw = unsafe {
                let utf8 = archive_entry_pathname_utf8(entry);
                if utf8.is_null() {
                    archive_entry_pathname(entry)
                } else {
                    utf8
                }
            };
            let name = if raw.is_null() {
                "data".into()
            } else {
                unsafe { CStr::from_ptr(raw) }
                    .to_string_lossy()
                    .into_owned()
            };
            let mut bytes = Vec::new();
            if !select(member_index, &name) {
                if keep_containers {
                    // A mislabeled nested archive must not be lost by name
                    // pushdown. Probe at most one small prefix, not its payload.
                    let mut prefix = [0u8; 512];
                    let count = unsafe {
                        archive_read_data(self.0, prefix.as_mut_ptr().cast(), prefix.len())
                    };
                    if count < 0 {
                        return Err(self.error());
                    }
                    if nested_extension(&prefix[..count as usize]).is_some() {
                        bytes.extend_from_slice(&prefix[..count as usize]);
                    }
                }
                if bytes.is_empty() {
                    unsafe {
                        archive_read_data_skip(self.0);
                    }
                    continue;
                }
            }
            if unsafe { archive_entry_size(entry) } > limit as i64 {
                return Err(io::Error::other(format!(
                    "Archive member {name:?} exceeds the size limit"
                )));
            }
            let mut chunk = [0u8; 65_536];
            loop {
                if stopped.load(Ordering::Relaxed) || Instant::now() > deadline {
                    return Err(io::Error::other("Archive search cancelled or timed out"));
                }
                let count =
                    unsafe { archive_read_data(self.0, chunk.as_mut_ptr().cast(), chunk.len()) };
                if count < 0 {
                    return Err(self.error());
                }
                if count == 0 {
                    break;
                }
                if bytes.len() as u64 + count as u64 > limit {
                    return Err(io::Error::other(format!(
                        "Archive member {name:?} exceeds the size limit"
                    )));
                }
                bytes.extend_from_slice(&chunk[..count as usize]);
            }
            let raw_stream = unsafe { archive_format(self.0) } & 0xff0000 == 0x090000;
            if !receive(member_index, name, bytes, raw_stream)? {
                return Ok(());
            }
        }
    }
}

/// ZIP's legacy encoding is CP437, not the current locale. The Unicode Path
/// field is authoritative only when its version and original-name CRC agree.
fn zip_name(
    raw: &[u8],
    utf8: bool,
    extra: rawzip::extra_fields::ExtraFields<'_>,
) -> io::Result<String> {
    if utf8 {
        return String::from_utf8(raw.to_vec()).map_err(io::Error::other);
    }
    for (id, data) in extra {
        if id == rawzip::extra_fields::ExtraFieldId::INFO_ZIP_UNICODE_PATH
            && data.len() >= 5
            && data[0] == 1
            && u32::from_le_bytes(data[1..5].try_into().unwrap()) == rawzip::crc32(raw)
        {
            if let Ok(name) = std::str::from_utf8(&data[5..]) {
                return Ok(name.into());
            }
        }
    }
    const HIGH: &str = "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{a0}";
    let high: Vec<char> = HIGH.chars().collect();
    Ok(raw
        .iter()
        .map(|&b| {
            if b < 128 {
                b as char
            } else {
                high[(b - 128) as usize]
            }
        })
        .collect())
}

#[cfg(test)]
mod name_tests {
    use super::*;
    #[test]
    fn zip_encodings_and_untrusted_extra_fields() {
        let legacy = b"caf\x82.txt";
        assert_eq!(
            zip_name(legacy, false, rawzip::extra_fields::ExtraFields::new(&[])).unwrap(),
            "café.txt"
        );
        assert_eq!(
            zip_name(
                "café.txt".as_bytes(),
                true,
                rawzip::extra_fields::ExtraFields::new(&[])
            )
            .unwrap(),
            "café.txt"
        );
        assert!(zip_name(legacy, true, rawzip::extra_fields::ExtraFields::new(&[])).is_err());
        let mut field = vec![0x75, 0x70, 14, 0, 1];
        field.extend(rawzip::crc32(legacy).to_le_bytes());
        field.extend("other.txt".as_bytes());
        assert_eq!(
            zip_name(
                legacy,
                false,
                rawzip::extra_fields::ExtraFields::new(&field)
            )
            .unwrap(),
            "other.txt"
        );
        field[5] ^= 1;
        assert_eq!(
            zip_name(
                legacy,
                false,
                rawzip::extra_fields::ExtraFields::new(&field)
            )
            .unwrap(),
            "café.txt"
        );
    }
}

pub fn has_cheap_names(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str(),
        "zip" | "jar" | "whl"
    )
}

pub fn is_archive(path: &Path) -> bool {
    is_format(&crate::formats::extension(path))
}
pub fn is_format(format: &str) -> bool {
    crate::readers::Reader::Archive.formats().contains(&format)
}

/// Nested package payloads often have no extension. Their bytes are already in
/// memory, so recognition adds no extra file read.
pub fn nested_extension(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"PK\x03\x04") {
        Some("zip")
    } else if bytes.starts_with(b"\x1f\x8b") {
        Some("gz")
    } else if bytes.starts_with(b"BZh") {
        Some("bz2")
    } else if bytes.starts_with(b"\xfd7zXZ\0") {
        Some("xz")
    } else if bytes.starts_with(b"\x28\xb5\x2f\xfd") {
        Some("zst")
    } else if bytes.starts_with(b"070701")
        || bytes.starts_with(b"070702")
        || bytes.starts_with(b"070707")
    {
        Some("cpio")
    } else if bytes.starts_with(b"!<arch>\n") {
        Some("deb")
    } else if bytes.get(257..262) == Some(b"ustar") {
        Some("tar")
    } else {
        None
    }
}
