//! Persisted freshness proofs. Replay the filesystem journal before reusing a
//! metadata scan. Missing history, uncertain filesystems and hard links fall
//! back to the complete metadata check; source bodies are never read here.
use crate::{content_index, Plan};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs,
    io::Write,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

#[derive(Serialize, Deserialize)]
struct Saved {
    event: u64,
    generation: i64,
    volumes: Vec<(u64, u64)>,
    report: Value,
}
pub struct Checkpoint {
    file: PathBuf,
    roots: Vec<PathBuf>,
    volumes: Vec<(u64, u64)>,
    event: u64,
    generation: i64,
    saved: Option<Saved>,
}
impl Checkpoint {
    pub fn new(plan: &Plan, configuration: &str, generation: i64) -> Option<Self> {
        let roots = crate::word_state::canonical_roots(&plan.word_roots);
        if roots.is_empty() || plan.word_scope.as_ref()?["traversal"]["follow"] == true {
            return None;
        }
        let key = content_index::hash(
            serde_json::to_vec(&(&roots, &plan.word_scope, configuration))
                .ok()?
                .as_slice(),
        );
        let file = plan
            .index_directory
            .as_ref()?
            .join("freshness-v1")
            .join(format!("{key}.json"));
        let saved: Option<Saved> = fs::read(&file)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok());
        // Even fetching the current cursor contacts the event service. Decide
        // from the previous measured scan before doing any journal setup.
        let mode = std::env::var("FINDUI_WORD_FRESHNESS").unwrap_or_default();
        let use_events = mode != "metadata"
            && (mode == "events" || saved.as_ref().is_none_or(|s| !cheap(&s.report)));
        let mut volumes = Vec::new();
        for root in &roots {
            if use_events && !platform::supported(root) {
                return None;
            }
            let m = fs::metadata(root).ok()?;
            volumes.push((m.dev(), m.ino()));
        }
        Some(Self {
            file,
            roots,
            volumes,
            event: if use_events { platform::current() } else { 0 },
            generation,
            saved,
        })
    }
    pub fn reuse(&self, plan: &Plan) -> Option<Value> {
        let saved = self.saved.as_ref()?;
        if saved.event == 0
            || saved.event > self.event
            || saved.volumes != self.volumes
            || saved.generation != self.generation
        {
            return None;
        }
        let mut excluded = Vec::new();
        if let Some(root) = &plan.index_directory {
            excluded.push(fs::canonicalize(root).ok()?);
        }
        if let Some(root) = plan
            .extraction
            .as_ref()
            .and_then(|e| e.cache_directory.as_ref())
        {
            excluded.push(fs::canonicalize(root).ok()?);
        }
        if !platform::unchanged(&self.roots, &excluded, saved.event) {
            return None;
        }
        if saved.event != self.event {
            self.save(&saved.report);
        }
        let mut report = saved.report.clone();
        report["verification"] = Value::String("filesystemEvents".into());
        Some(report)
    }
    pub fn save(&self, report: &Value) {
        if report["state"] != "updated" {
            return;
        }
        let previous = self
            .saved
            .as_ref()
            .filter(|s| s.generation == self.generation && s.volumes == self.volumes);
        if self.event == 0 && cheap(report) && previous.is_some_and(|s| cheap(&s.report)) {
            return; // An unchanged small scope needs no new journal/cache write.
        }
        // A full metadata check can retain an older valid cursor: replaying more
        // history is conservative. A new generation must start with a new proof.
        let event = if self.event == 0 {
            previous.map_or(0, |s| s.event)
        } else {
            self.event
        };
        let _ = (|| -> std::io::Result<()> {
            let parent = self.file.parent().unwrap();
            fs::create_dir_all(parent)?;
            let mut out = tempfile::NamedTempFile::new_in(parent)?;
            serde_json::to_writer(
                &mut out,
                &Saved {
                    event,
                    generation: self.generation,
                    volumes: self.volumes.clone(),
                    report: report.clone(),
                },
            )?;
            out.flush()?;
            out.persist(&self.file).map_err(|e| e.error)?;
            Ok(())
        })();
    }
}

fn cheap(report: &Value) -> bool {
    report["verificationMilliseconds"].as_f64().unwrap_or(0.0) < 250.0
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;
    pub fn supported(_: &Path) -> bool {
        false
    }
    pub fn current() -> u64 {
        0
    }
    pub fn unchanged(_: &[PathBuf], _: &[PathBuf], _: u64) -> bool {
        false
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use std::{
        ffi::{c_char, c_void, CStr, CString},
        ptr,
        sync::{Condvar, Mutex},
        time::Duration,
    };
    type CF = *const c_void;
    #[repr(C)]
    struct Context {
        version: isize,
        info: *mut c_void,
        retain: Option<unsafe extern "C" fn(CF) -> CF>,
        release: Option<unsafe extern "C" fn(CF)>,
        description: Option<unsafe extern "C" fn(CF) -> CF>,
    }
    type Callback =
        unsafe extern "C" fn(CF, *mut c_void, usize, *mut c_void, *const u32, *const u64);
    #[link(name = "CoreServices", kind = "framework")]
    extern "C" {
        fn FSEventsGetCurrentEventId() -> u64;
        fn FSEventStreamCreate(
            allocator: CF,
            callback: Callback,
            context: *mut Context,
            paths: CF,
            since: u64,
            latency: f64,
            flags: u32,
        ) -> CF;
        fn FSEventStreamSetDispatchQueue(stream: CF, queue: *mut c_void);
        fn FSEventStreamStart(stream: CF) -> u8;
        fn FSEventStreamFlushSync(stream: CF);
        fn FSEventStreamStop(stream: CF);
        fn FSEventStreamInvalidate(stream: CF);
        fn FSEventStreamRelease(stream: CF);
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        static kCFTypeArrayCallBacks: u8;
        fn CFStringCreateWithCString(allocator: CF, value: *const c_char, encoding: u32) -> CF;
        fn CFStringGetCString(value: CF, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
        fn CFArrayCreate(allocator: CF, values: *const CF, count: isize, callbacks: CF) -> CF;
        fn CFArrayGetValueAtIndex(array: CF, index: isize) -> CF;
        fn CFRelease(value: CF);
    }
    extern "C" {
        fn dispatch_queue_create(label: *const c_char, attr: CF) -> *mut c_void;
        fn dispatch_sync_f(
            queue: *mut c_void,
            context: *mut c_void,
            work: unsafe extern "C" fn(*mut c_void),
        );
        fn dispatch_release(queue: *mut c_void);
    }
    pub fn current() -> u64 {
        unsafe { FSEventsGetCurrentEventId() }
    }
    pub fn supported(root: &Path) -> bool {
        use std::os::unix::ffi::OsStrExt;
        let Ok(path) = CString::new(root.as_os_str().as_bytes()) else {
            return false;
        };
        unsafe {
            let mut stat: libc::statfs = std::mem::zeroed();
            if libc::statfs(path.as_ptr(), &mut stat) != 0 {
                return false;
            }
            matches!(
                CStr::from_ptr(stat.f_fstypename.as_ptr()).to_bytes(),
                b"apfs" | b"hfs"
            ) && stat.f_flags & libc::MNT_LOCAL as u32 != 0
        }
    }
    struct Events {
        history: bool,
        uncertain: bool,
        changed: bool,
    }
    struct State {
        events: Mutex<Events>,
        ready: Condvar,
        roots: Vec<PathBuf>,
        excluded: Vec<PathBuf>,
    }
    unsafe extern "C" fn callback(
        _: CF,
        info: *mut c_void,
        count: usize,
        paths: *mut c_void,
        flags: *const u32,
        _: *const u64,
    ) {
        let state = &*info.cast::<State>();
        // C callbacks must not unwind. Poisoning or an invalid path invalidates
        // the proof, never produces a false "up to date" result.
        let Ok(mut events) = state.events.lock() else {
            return;
        };
        for i in 0..count {
            let flag = *flags.add(i);
            if flag & (1 | 2 | 4 | 8 | 0x20 | 0x40 | 0x80) != 0 {
                events.uncertain = true;
            }
            if flag & 0x10 != 0 {
                events.history = true;
                continue;
            }
            let value = CFArrayGetValueAtIndex(paths.cast_const(), i as isize);
            let mut buffer = [0 as c_char; 4096];
            if CFStringGetCString(
                value,
                buffer.as_mut_ptr(),
                buffer.len() as isize,
                0x08000100,
            ) == 0
            {
                events.uncertain = true;
                continue;
            }
            let Ok(text) = CStr::from_ptr(buffer.as_ptr()).to_str() else {
                events.uncertain = true;
                continue;
            };
            let path = Path::new(text);
            if state
                .roots
                .iter()
                .any(|r| path.starts_with(r) || r.starts_with(path))
                && !state.excluded.iter().any(|r| path.starts_with(r))
            {
                events.changed = true;
            }
        }
        state.ready.notify_all();
    }
    unsafe extern "C" fn barrier(_: *mut c_void) {}
    pub fn unchanged(roots: &[PathBuf], excluded: &[PathBuf], since: u64) -> bool {
        unsafe {
            let mut strings = Vec::new();
            for root in roots {
                let Ok(path) = CString::new(root.to_string_lossy().as_bytes()) else {
                    return false;
                };
                let value = CFStringCreateWithCString(ptr::null(), path.as_ptr(), 0x08000100);
                if value.is_null() {
                    for s in strings {
                        CFRelease(s);
                    }
                    return false;
                }
                strings.push(value);
            }
            let paths = CFArrayCreate(
                ptr::null(),
                strings.as_ptr(),
                strings.len() as isize,
                (&kCFTypeArrayCallBacks as *const u8).cast(),
            );
            for value in strings {
                CFRelease(value);
            }
            if paths.is_null() {
                return false;
            }
            let mut state = Box::new(State {
                events: Mutex::new(Events {
                    history: false,
                    uncertain: false,
                    changed: false,
                }),
                ready: Condvar::new(),
                roots: roots.to_vec(),
                excluded: excluded.to_vec(),
            });
            let mut context = Context {
                version: 0,
                info: (&mut *state as *mut State).cast(),
                retain: None,
                release: None,
                description: None,
            };
            let stream = FSEventStreamCreate(
                ptr::null(),
                callback,
                &mut context,
                paths,
                since,
                0.001,
                1 | 2 | 4 | 0x10,
            );
            CFRelease(paths);
            if stream.is_null() {
                return false;
            }
            let queue = dispatch_queue_create(c"findui.word-freshness".as_ptr(), ptr::null());
            if queue.is_null() {
                FSEventStreamRelease(stream);
                return false;
            }
            FSEventStreamSetDispatchQueue(stream, queue);
            let started = FSEventStreamStart(stream) != 0;
            if started {
                // Apple guarantees delivery of events preceding this call.
                FSEventStreamFlushSync(stream);
                if let Ok(events) = state.events.lock() {
                    let _ =
                        state
                            .ready
                            .wait_timeout_while(events, Duration::from_millis(750), |e| !e.history);
                }
                FSEventStreamStop(stream);
            }
            FSEventStreamInvalidate(stream);
            dispatch_sync_f(queue, ptr::null_mut(), barrier);
            FSEventStreamRelease(stream);
            dispatch_release(queue);
            let result = started
                && state
                    .events
                    .lock()
                    .is_ok_and(|e| e.history && !e.uncertain && !e.changed);
            result
        }
    }
}
