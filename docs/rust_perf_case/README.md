# Case study: Rust filter + preallocation

The functions return exactly the same ordered IDs. The candidate (`with_capacity(rows.len())`) may be faster for dense outputs, but may retain excess capacity for sparse outputs. **Measurements have been run on one machine; see [`RESULTS.md`](RESULTS.md)** for the numbers, the allocator-state artifact that flipped one scenario by +60 %, and what remains unverified.

Requirements: Rust >=1.88, Cargo. Criterion is pinned to `0.8.2`. On your first run, create `Cargo.lock` with `cargo generate-lockfile`; retain that lock file in reports. Execute:

```bash
cargo generate-lockfile
cargo fmt --all -- --check
cargo test --locked --all-targets
cargo clippy --locked --all-targets -- -D warnings
cargo bench --locked --bench select_active
```

Measure on the CPU/OS and input distribution of interest. Record `rustc -Vv`, CPU, governor, flags, run order, raw samples, RSS/peak memory and size/selectivity. Treat tiny/unstable differences as unknown, not proven improvements. This benchmark measures creation of the result, including allocation; for end-to-end applications also measure downstream use, allocator pressure, tail latency and output capacity.

## ABBA data analysis (Python 3, no third-party packages)

When you have measured end-to-end wall-times, save CSV with columns
`scenario,block,variant,ns`. Each independent block must include A and B,
preferably two runs each in ABBA/BAAB order. Run:

```bash
python3 scripts/analyze_abba.py path/to/real_measurements.csv
```

`sample_synthetic.csv` is **invented demonstration input** and must not be
reported as a measured Rust speedup. The script gives an exploratory bootstrap
CI across paired blocks, not a guarantee of causality. At least 10 blocks are
needed even for its heuristic status to be more than exploratory; a trustworthy
engineering decision generally requires independent replication, workload
relevance, acceptable memory/tail-latency, and multiple-comparison discipline.
The script applies a Bonferroni adjustment across scenarios by default
(`--multiplicity bonferroni`; `none` for exploratory analysis) and prints the
family alpha and individual CI level it actually used. It was tested on
`sample_synthetic.csv` (synthetic, so it validates the code path, not Rust).

The reference Rust case **has been compiled and measured** in this fork on
stable 1.99.1, beta 1.100.0-beta.13 and the declared MSRV 1.88.0; see
[`RESULTS.md`](RESULTS.md). `perf` sampling is denied in this environment, so
apparatus-level claims are marked as unverified rather than guessed.

## Top-Down / false-sharing reproducible exercise

This package also includes `examples/false_sharing.rs`: four independent
atomic counters in adjacent slots (`dense`) versus 64-byte-aligned padded
slots (`padded`). The 64-byte alignment is specific to many x86-64 CPUs and
must not be assumed on all platforms. On your own **idle, PMU-capable** host:

```bash
cargo build --release --example false_sharing
./target/release/examples/false_sharing dense 4 10000000
./target/release/examples/false_sharing padded 4 10000000
perf c2c record -- ./target/release/examples/false_sharing dense 4 10000000
perf c2c report --stdio
perf c2c record -- ./target/release/examples/false_sharing padded 4 10000000
perf c2c report --stdio
```

You must verify separate cache-line offsets and declining HITM *and* repeat
ABBA wall-clock comparisons before claiming a false-sharing fix. On this
fork's machine (Xeon E5-2680 v3, `taskset -c 4-7`, 4 workers, 5M increments
per worker, interleaved ABBA) `dense` took 337–389 ms and `padded` 34–54 ms,
i.e. roughly a 7–11× wall-time difference; `perf c2c` itself could not run
here. Numbers are machine-specific; see [`RESULTS.md`](RESULTS.md).
