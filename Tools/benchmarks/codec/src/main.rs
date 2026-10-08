use flate2::{read::GzDecoder, write::GzEncoder, Compression};
use sha2::{Digest, Sha256};
use std::{
    hint::black_box,
    io::{Read, Write},
    time::Instant,
};
fn main() {
    let input=(0..60000).map(|i|format!("{{\"name\":\"document-{i}.txt\",\"text\":\"This is searchable document text with repeated words. needle file {i}\",\"line\":{i}}}\n")).collect::<String>().into_bytes();
    let bundle: Vec<serde_json::Value> = input
        .split(|b| *b == b'\n')
        .filter(|l| !l.is_empty())
        .map(|l| serde_json::from_slice(l).unwrap())
        .collect();
    let input = serde_json::to_vec(&bundle).unwrap();
    let backend = if cfg!(feature = "zlib-rs") {
        "zlib-rs"
    } else {
        "miniz"
    };
    let mut encode = Vec::new();
    let mut decode = Vec::new();
    let mut compressed = Vec::new();
    for _ in 0..7 {
        let start = Instant::now();
        let mut enc = GzEncoder::new(Vec::new(), Compression::fast());
        let buffered = std::env::var_os("FINDUI_BUFFER_JSON").is_some();
        if buffered {
            let mut writer = std::io::BufWriter::with_capacity(65536, &mut enc);
            serde_json::to_writer(&mut writer, &bundle).unwrap();
            writer.flush().unwrap();
        } else {
            serde_json::to_writer(&mut enc, &bundle).unwrap();
        }
        compressed = enc.finish().unwrap();
        encode.push(start.elapsed().as_secs_f64() * 1000.0);
        let start = Instant::now();
        let mut output = Vec::new();
        GzDecoder::new(compressed.as_slice())
            .read_to_end(&mut output)
            .unwrap();
        decode.push(start.elapsed().as_secs_f64() * 1000.0);
        assert_eq!(output, input);
    }
    let target = std::env::args().nth(1).unwrap();
    std::fs::write(&target, &compressed).unwrap();
    if let Some(other) = std::env::args().nth(2) {
        let mut output = Vec::new();
        GzDecoder::new(std::fs::File::open(other).unwrap())
            .read_to_end(&mut output)
            .unwrap();
        assert_eq!(output, input);
    }
    println!("{{\"backend\":\"{backend}\",\"inputBytes\":{},\"compressedBytes\":{},\"encodeMs\":{encode:?},\"decodeMs\":{decode:?}}}",input.len(),compressed.len());
    for (size, repeats) in [(256, 100000), (8 * 1024 * 1024, 32)] {
        let input = vec![0x61; size];
        let mut samples = Vec::new();
        for _ in 0..5 {
            let start = Instant::now();
            for _ in 0..repeats {
                black_box(Sha256::digest(black_box(&input)));
            }
            samples.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        println!("{{\"shaVersion\":\"0.11.0\",\"bytes\":{size},\"repeats\":{repeats},\"milliseconds\":{samples:?},\"digest\":\"{}\"}}",Sha256::digest(&input).iter().map(|b|format!("{b:02x}")).collect::<String>());
    }
}
