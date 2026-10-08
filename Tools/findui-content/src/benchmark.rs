//! Synthetic, bounded diagnostics available in the distributed worker. Uses the
//! production hash and cache paths, creates no persistent user state or input.
use crate::{
    content_index::{self, Cache, Signature},
    documents::{Bundle, Document},
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{fs, hint::black_box, io, time::Instant};

pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    if content_index::hash(b"abc")
        != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    {
        return Err(io::Error::other("SHA-256 known-vector check failed").into());
    }
    let mut hashes = Vec::new();
    for (size, iterations) in [(256, 100_000), (8 * 1024 * 1024, 32)] {
        let bytes = vec![0x5a; size];
        let expected = Sha256::digest(&bytes);
        let mut samples = Vec::new();
        for _ in 0..5 {
            let start = Instant::now();
            let mut digest = expected;
            for _ in 0..iterations {
                digest = black_box(Sha256::digest(black_box(&bytes)));
            }
            samples.push(start.elapsed().as_secs_f64() * 1000.0);
            if digest != expected {
                return Err(io::Error::other("SHA-256 digest changed").into());
            }
        }
        hashes.push(json!({"bytes":size,"iterations":iterations,"milliseconds":samples,"sha256":content_index::hex(&expected)}));
    }
    let temporary = tempfile::tempdir()?;
    let source = temporary.path().join("synthetic.txt");
    fs::write(&source, b"FindUI synthetic cache benchmark\n")?;
    // The metadata constructor also works on temporary filesystems with coarse
    // timestamps; the fixture remains unchanged throughout the benchmark.
    let cache = Cache::from_metadata(
        temporary.path(),
        &source,
        "plain-v2",
        &fs::metadata(&source)?,
    );
    let bundle = Bundle { documents: (0..30_000).map(|i| Document {
        text: format!("Record {i}: a synthetic searchable document with repeated text, metadata, and a needle.\n"),
        metadata: [("title".into(),format!("Document {i}"))].into(),
        ..Document::default()
    }).collect(), ..Bundle::default() };
    let serialized = serde_json::to_vec(&bundle)?;
    let signature = Signature::bundle(&bundle);
    let mut writes = Vec::new();
    let mut reads = Vec::new();
    for _ in 0..5 {
        let start = Instant::now();
        cache.save(signature.clone(), Some(&bundle))?;
        writes.push(start.elapsed().as_secs_f64() * 1000.0);
        let start = Instant::now();
        let restored = cache
            .bundle(serialized.len() as u64)
            .ok_or_else(|| io::Error::other("Cache round-trip failed"))?;
        reads.push(start.elapsed().as_secs_f64() * 1000.0);
        if serde_json::to_vec(&restored)? != serialized {
            return Err(io::Error::other("Cache round-trip changed document data").into());
        }
    }
    let mut compressed = 0;
    for entry in fs::read_dir(temporary.path())? {
        let path = entry?.path().join("documents.gz");
        if let Ok(metadata) = fs::metadata(path) {
            compressed += metadata.len();
        }
    }
    #[cfg(target_arch = "aarch64")]
    let hardware_sha256 = std::arch::is_aarch64_feature_detected!("sha2");
    #[cfg(target_arch = "x86_64")]
    let hardware_sha256 = std::arch::is_x86_feature_detected!("sha");
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    let hardware_sha256 = false;
    serde_json::to_writer_pretty(
        io::stdout().lock(),
        &json!({
            "schemaVersion":1,"workerVersion":env!("CARGO_PKG_VERSION"),
            "architecture":std::env::consts::ARCH,"hardwareSHA256Available":hardware_sha256,
            "sha256":hashes,"cache":{"documents":bundle.documents.len(),"jsonBytes":serialized.len(),
                "gzipBytes":compressed,"writeMilliseconds":writes,"readMilliseconds":reads,"roundTripVerified":true},
            "note":"Synthetic warm-process samples. Run with the computer idle; these are component costs, not search speed guarantees."
        }),
    )?;
    println!();
    Ok(())
}
