use rayon::prelude::*;
use serde_json::json;
use std::{
    ffi::OsString,
    fs,
    io::{self, BufRead, Write},
    os::unix::ffi::OsStringExt,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering::Relaxed},
        Mutex,
    },
    time::UNIX_EPOCH,
};

/// One stat per path for compound filename branches (including birth time).
/// Output is the same frozen metadata protocol used by saved filename indexes.
pub fn run(args: &[String]) -> io::Result<()> {
    let follow = args.iter().any(|a| a == "--follow");
    let tags = args.iter().any(|a| a == "--tags");
    let threads = args
        .windows(2)
        .find(|a| a[0] == "--threads")
        .map(|a| a[1].parse::<usize>())
        .transpose()
        .map_err(io::Error::other)?
        .unwrap_or(0);
    if threads > 64 {
        return Err(io::Error::other("Threads must be 0–64"));
    }
    let threads = if threads == 0 {
        std::thread::available_parallelism()
            .map_or(2, usize::from)
            .min(12)
    } else {
        threads
    };
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .build()
        .map_err(io::Error::other)?;
    let writer = Mutex::new(io::BufWriter::new(io::stdout()));
    let failed = AtomicBool::new(false);
    pool.install(|| io::BufReader::new(io::stdin()).split(0).par_bridge().for_each(|raw| {
        if failed.load(Relaxed) { return; }
        let result = (|| -> io::Result<()> {
            let raw = raw?; if raw.is_empty() { return Ok(()); }
            let path = PathBuf::from(OsString::from_vec(raw));
            let metadata = match if follow { fs::metadata(&path) } else { fs::symlink_metadata(&path) } {
                Ok(m) => m, Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()), Err(e) => return Err(e),
            };
            if !metadata.is_file() && !metadata.is_dir() { return Ok(()); }
            let seconds = |t: std::time::SystemTime| match t.duration_since(UNIX_EPOCH) {
                Ok(d) => d.as_secs_f64(), Err(e) => -e.duration().as_secs_f64(),
            };
            let modified = metadata.modified().ok().map(seconds);
            let created = metadata.created().ok().map(|t| seconds(t).floor());
            let value = json!({"path":path.to_string_lossy(),"directory":metadata.is_dir(),"size":metadata.len(),
                "modified":modified,"created":created,"tags":if tags { Some(finder_tags(&path, follow)?) } else { None }});
            let mut bytes = serde_json::to_vec(&value)?; bytes.push(0);
            let mut out = writer.lock().unwrap(); out.write_all(&bytes)?; out.flush()
        })();
        if let Err(e) = result {
            if e.kind() != io::ErrorKind::BrokenPipe { eprintln!("findui-metadata: {e}"); }
            failed.store(true, Relaxed);
        }
    }));
    if failed.load(Relaxed) {
        Err(io::Error::other("Metadata scan interrupted"))
    } else {
        Ok(())
    }
}

/// Read Finder's actual extended attribute; Spotlight indexing is not required.
pub fn finder_tags(path: &std::path::Path, follow: bool) -> io::Result<Vec<String>> {
    use std::os::unix::ffi::OsStrExt;
    let path = std::ffi::CString::new(path.as_os_str().as_bytes())?;
    let key = c"com.apple.metadata:_kMDItemUserTags";
    let options = if follow { 0 } else { libc::XATTR_NOFOLLOW };
    for _ in 0..3 {
        let size = unsafe {
            libc::getxattr(
                path.as_ptr(),
                key.as_ptr(),
                std::ptr::null_mut(),
                0,
                0,
                options,
            )
        };
        if size < 0 {
            let e = io::Error::last_os_error();
            if matches!(
                e.raw_os_error(),
                Some(libc::ENOATTR | libc::ENOTSUP | libc::ENOENT)
            ) {
                return Ok(Vec::new());
            }
            return Err(e);
        }
        if size > 1024 * 1024 {
            return Err(io::Error::other("Finder tags attribute exceeds 1 MiB"));
        }
        let mut bytes = vec![0; size as usize];
        let n = unsafe {
            libc::getxattr(
                path.as_ptr(),
                key.as_ptr(),
                bytes.as_mut_ptr().cast(),
                bytes.len(),
                0,
                options,
            )
        };
        if n < 0 {
            if io::Error::last_os_error().raw_os_error() == Some(libc::ERANGE) {
                continue;
            }
            return Err(io::Error::last_os_error());
        }
        bytes.truncate(n as usize);
        if bytes.is_empty() {
            return Ok(Vec::new());
        }
        let value =
            plist::Value::from_reader(std::io::Cursor::new(bytes)).map_err(io::Error::other)?;
        let array = value
            .as_array()
            .ok_or_else(|| io::Error::other("Invalid Finder tags attribute"))?;
        return Ok(array
            .iter()
            .filter_map(|v| v.as_string())
            .map(|s| {
                s.rsplit_once('\n')
                    .filter(|(_, color)| color.len() == 1 && color.as_bytes()[0].is_ascii_digit())
                    .map_or(s, |(name, _)| name)
                    .to_owned()
            })
            .collect());
    }
    Err(io::Error::other(
        "Finder tags changed during reading; retry the search",
    ))
}
