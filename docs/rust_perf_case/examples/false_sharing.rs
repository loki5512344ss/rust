//! Illustration of potential false sharing, NOT a validated speedup.
//! Run on a CPU with 64-byte cache lines, with >=2 physical cores:
//!   cargo run --release --example false_sharing -- dense 4 10000000
//!   cargo run --release --example false_sharing -- padded 4 10000000
//!
//! `Ordering::Relaxed` is safe here because counters are independent and
//! scoped thread join provides completion before the final reads.
use std::env;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Instant;

// 64 bytes is a typical cache line size on mainstream x86-64, NOT universal.
#[repr(align(64))]
struct PaddedAtomic(AtomicU64);

fn measure_dense(workers: usize, iterations: u64) -> (u64, std::time::Duration) {
    let cells: Vec<AtomicU64> = (0..workers).map(|_| AtomicU64::new(0)).collect();
    let start = Instant::now();
    thread::scope(|scope| {
        for cell in &cells {
            scope.spawn(move || {
                for _ in 0..iterations {
                    cell.fetch_add(1, Ordering::Relaxed);
                }
            });
        }
    });
    let elapsed = start.elapsed();
    let total = cells.iter().map(|c| c.load(Ordering::Relaxed)).sum();
    (total, elapsed)
}

fn measure_padded(workers: usize, iterations: u64) -> (u64, std::time::Duration) {
    let cells: Vec<PaddedAtomic> = (0..workers)
        .map(|_| PaddedAtomic(AtomicU64::new(0)))
        .collect();
    let start = Instant::now();
    thread::scope(|scope| {
        for cell in &cells {
            scope.spawn(move || {
                for _ in 0..iterations {
                    cell.0.fetch_add(1, Ordering::Relaxed);
                }
            });
        }
    });
    let elapsed = start.elapsed();
    let total = cells.iter().map(|c| c.0.load(Ordering::Relaxed)).sum();
    (total, elapsed)
}

fn main() {
    let mut args = env::args().skip(1);
    let variant = args.next().unwrap_or_else(|| "dense".to_string());
    let workers: usize = args
        .next()
        .unwrap_or_else(|| "4".to_string())
        .parse()
        .expect("workers must be a positive usize");
    let iterations: u64 = args
        .next()
        .unwrap_or_else(|| "10000000".to_string())
        .parse()
        .expect("iterations must be positive u64");
    assert!(
        workers > 0 && iterations > 0,
        "workers/iterations must be > 0"
    );
    assert!(
        iterations.checked_mul(workers as u64).is_some(),
        "sum overflow"
    );
    let (total, elapsed) = match variant.as_str() {
        "dense" => measure_dense(workers, iterations),
        "padded" => measure_padded(workers, iterations),
        _ => panic!("variant must be 'dense' or 'padded'"),
    };
    assert_eq!(total, iterations * workers as u64);
    println!("variant={variant}, workers={workers}, iterations={iterations}, total={total}, elapsed={elapsed:?}");
}
