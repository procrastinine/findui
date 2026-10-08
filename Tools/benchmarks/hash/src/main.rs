use sha2::{Digest, Sha256};
use std::{hint::black_box, time::Instant};
fn main() {
    let accelerated = cfg!(feature = "accelerated");
    let mut total = 0u8;
    for (size, repeats) in [(256, 100000), (8 * 1024 * 1024, 32)] {
        let input = vec![0x61; size];
        let mut samples = Vec::new();
        for _ in 0..5 {
            let start = Instant::now();
            for _ in 0..repeats {
                total ^= black_box(Sha256::digest(black_box(&input)))[0];
            }
            samples.push(start.elapsed().as_secs_f64() * 1000.0);
        }
        println!("{{\"accelerated\":{accelerated},\"bytes\":{size},\"repeats\":{repeats},\"milliseconds\":{samples:?},\"digest\":\"{:x}\"}}",Sha256::digest(&input));
    }
    black_box(total);
}
