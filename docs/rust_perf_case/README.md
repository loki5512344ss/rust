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

The reference Rust case and its performance have **not been compiled/measured
in the file creator's environment**, where `rustc` and `cargo` are unavailable.
