//! Bounded shared output and ordered-result spooling.
use crate::*;
use std::sync::Weak;

const BATCH_BYTES: usize = 64 * 1024;
type Pending = Mutex<Vec<u8>>;
type Buffers = Arc<Mutex<Vec<Weak<Pending>>>>;

fn flush_pending(buffers: &Buffers, writer: &Mutex<Writer>) -> io::Result<()> {
    let mut registered = buffers.lock().unwrap();
    registered.retain(|buffer| buffer.strong_count() > 0);
    for buffer in registered.iter().filter_map(Weak::upgrade) {
        let mut bytes = buffer.lock().unwrap();
        if !bytes.is_empty() {
            writer.lock().unwrap().write_all(&bytes)?;
            bytes.clear();
        }
    }
    writer.lock().unwrap().flush()
}

pub(crate) enum Writer {
    Stdout(io::BufWriter<io::Stdout>),
    Spool(io::BufWriter<tempfile::SpooledTempFile>),
}
impl Write for Writer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self {
            Self::Stdout(w) => w.write(bytes),
            Self::Spool(w) => w.write(bytes),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Stdout(w) => w.flush(),
            Self::Spool(w) => w.flush(),
        }
    }
}
pub(crate) struct Output {
    pub(crate) writer: Arc<Mutex<Writer>>,
    pub(crate) stopped: Arc<AtomicBool>,
    first: AtomicBool,
    buffers: Buffers,
    _flusher: Option<Flusher>,
}
struct Flusher {
    stop: std::sync::mpsc::Sender<()>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Drop for Flusher {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() { let _ = thread.join(); }
    }
}
impl Output {
    pub(crate) fn stdout(stopped: Arc<AtomicBool>) -> Self {
        let writer = Arc::new(Mutex::new(Writer::Stdout(io::BufWriter::with_capacity(64 * 1024, io::stdout()))));
        let (stop, receive) = std::sync::mpsc::channel();
        let sink = writer.clone();
        let buffers: Buffers = Arc::new(Mutex::new(Vec::new()));
        let pending = buffers.clone();
        let cancelled = stopped.clone();
        let thread = std::thread::spawn(move || loop {
            let finished = receive.recv_timeout(Duration::from_millis(20)).is_ok();
            if flush_pending(&pending, &sink).is_err() { cancelled.store(true, Relaxed); break; }
            if finished { break; }
        });
        Self { writer, stopped, first: AtomicBool::new(true), buffers, _flusher: Some(Flusher { stop, thread: Some(thread) }) }
    }
    pub(crate) fn spool(stopped: Arc<AtomicBool>) -> Self {
        Self {
            writer: Arc::new(Mutex::new(Writer::Spool(io::BufWriter::new(
                tempfile::spooled_tempfile(1024 * 1024),
            )))),
            stopped,
            first: AtomicBool::new(false),
            buffers: Arc::new(Mutex::new(Vec::new())),
            _flusher: None,
        }
    }
    pub(crate) fn buffered(&self) -> BufferedOutput<'_> {
        let bytes = Arc::new(Mutex::new(Vec::with_capacity(BATCH_BYTES)));
        let mut registered = self.buffers.lock().unwrap();
        registered.retain(|buffer| buffer.strong_count() > 0);
        registered.push(Arc::downgrade(&bytes));
        BufferedOutput { output: self, bytes }
    }
    pub(crate) fn write(&self, bytes: &[u8]) -> io::Result<()> {
        if self.stopped.load(Relaxed) {
            return Err(io::ErrorKind::BrokenPipe.into());
        }
        let mut w = self.writer.lock().unwrap();
        // First result is immediate. Subsequent complete records are buffered;
        // the timer bounds sparse-result latency without a syscall per line.
        let immediate = self.first.swap(false, Relaxed);
        let result = w
            .write_all(bytes)
            .and_then(|_| if immediate { w.flush() } else { Ok(()) });
        if result.is_err() {
            self.stopped.store(true, Relaxed);
        }
        result
    }
    pub(crate) fn path(&self, path: &[u8]) -> io::Result<()> {
        let mut record = path.to_vec();
        record.push(0);
        self.write(&record)
    }
    pub(crate) fn replay(&self, output: &Self) -> io::Result<()> {
        let mut source = self.writer.lock().unwrap();
        source.flush()?;
        if let Writer::Spool(buffer) = &mut *source {
            let file = buffer.get_mut();
            file.rewind()?;
            let mut writer = output.writer.lock().unwrap();
            io::copy(file, &mut *writer)?;
            writer.flush()?;
        }
        Ok(())
    }
}

/// Dense producers share stdout in batches, not once per matching line. Their
/// private buffers participate in the same timer, so a sparse tail still
/// becomes visible even while the scanner is busy looking for its next match.
pub(crate) struct BufferedOutput<'a> {
    output: &'a Output,
    bytes: Arc<Pending>,
}
impl BufferedOutput<'_> {
    pub(crate) fn write(&self, record: &[u8]) -> io::Result<()> {
        if self.output.stopped.load(Relaxed) { return Err(io::ErrorKind::BrokenPipe.into()) }
        let mut bytes = self.bytes.lock().unwrap();
        if bytes.len() + record.len() > BATCH_BYTES && !bytes.is_empty() {
            self.output.write(&bytes)?; bytes.clear();
        }
        if record.len() >= BATCH_BYTES || self.output.first.load(Relaxed) {
            self.output.write(record)
        } else { bytes.extend_from_slice(record); Ok(()) }
    }
    pub(crate) fn flush(&self) -> io::Result<()> {
        let mut bytes = self.bytes.lock().unwrap();
        if !bytes.is_empty() { self.output.write(&bytes)?; bytes.clear(); }
        Ok(())
    }
}
impl Drop for BufferedOutput<'_> {
    fn drop(&mut self) { let _ = self.flush(); }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;

    #[test]
    fn concurrent_batches_keep_records_and_per_producer_order() {
        let output = Output::spool(Arc::new(AtomicBool::new(false)));
        std::thread::scope(|scope| {
            for producer in 0..4 {
                let output = &output;
                scope.spawn(move || {
                    let buffer = output.buffered();
                    for line in 0..12_000 { buffer.write(format!("{producer}:{line}\n").as_bytes()).unwrap(); }
                    // Models the timer: flush pending sparse tails before EOF.
                    flush_pending(&output.buffers, &output.writer).unwrap();
                    assert!(buffer.bytes.lock().unwrap().is_empty());
                });
            }
        });
        let mut writer = output.writer.lock().unwrap();
        let Writer::Spool(writer) = &mut *writer else { unreachable!() };
        writer.flush().unwrap(); writer.get_mut().rewind().unwrap();
        let mut text = String::new(); writer.get_mut().read_to_string(&mut text).unwrap();
        let mut next = [0; 4];
        for line in text.lines() {
            let (producer, sequence) = line.split_once(':').unwrap();
            let producer: usize = producer.parse().unwrap();
            assert_eq!(sequence.parse::<usize>().unwrap(), next[producer]); next[producer] += 1;
        }
        assert_eq!(next, [12_000; 4]);
    }
}
/// A fuzzy candidate list is already ranked. Parallel readers retain that
/// order with at most one buffered file per worker (1 MiB RAM, then a temporary
/// file). Waiting workers cannot build an unbounded queue behind a slow file.
pub(crate) struct OrderedOutput {
    pub(crate) next: Mutex<usize>,
    pub(crate) ready: Condvar,
}
impl OrderedOutput {
    pub(crate) fn is_next(&self, index: usize) -> bool {
        *self.next.lock().unwrap() == index
    }
    pub(crate) fn emit(&self, index: usize, file: Option<&Output>, output: &Output) -> io::Result<()> {
        let mut next = self.next.lock().unwrap();
        while *next != index && !output.stopped.load(Relaxed) {
            next = self
                .ready
                .wait_timeout(next, Duration::from_millis(50))
                .unwrap()
                .0;
        }
        if output.stopped.load(Relaxed) {
            return Ok(());
        }
        let result = file.map_or(Ok(()), |file| file.replay(output));
        if result.is_err() {
            output.stopped.store(true, Relaxed);
        }
        *next += 1;
        self.ready.notify_all();
        result
    }
}
