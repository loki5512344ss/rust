# Measured results: `Vec::with_capacity` for a filtered collection

This file exists because the guide (and the case README) honestly said the case
had never been compiled or measured. It has now been run on one machine.

## Environment

| | |
|---|---|
| rustc | 1.99.1 (58cf8f9c3 2026-10-13), LLVM 23.1.1 |
| cargo | 1.99.1 |
| criterion | 0.8.2 (pinned) |
| CPU | Intel Xeon E5-2680 v3, 2 sockets × 12 cores / 24 threads |
| OS | Linux, kernel 7.3.1 |
| pinning | `taskset -c 4` for every benchmark |
| load | ~7 on 24 threads during the run (desktop session active) |

`perf record` is denied in this environment (`perf_event_paranoid=2` and the
kernel refuses `cpu/cycles/Pu`), so no sampling profile is included. Absolute
numbers are specific to this machine; the *direction* of each comparison is the
result.

## Toolchain matrix

| toolchain | `cargo test --locked --all-targets` | `cargo clippy -- -D warnings` |
|---|---|---|
| 1.88.0 (declared MSRV) | pass | not run (clippy component not installed) |
| stable 1.99.1 | pass (2 tests + all bench scenarios) | pass (after the `black_box` fix) |
| beta 1.100.0-beta.13 (2026-11-07) | pass | pass |

The declared `rust-version = "1.88"` is exercised: 1.88.0 builds and passes the
tests, including the criterion 0.8.2 dependency graph.

## Correctness and hygiene

```bash
cargo generate-lockfile
cargo test --locked --all-targets     # 2 integration tests + all bench scenarios in test mode: ok
cargo clippy --locked --all-targets -- -D warnings
```

The first clippy run **failed**: `criterion::black_box` is deprecated in
criterion 0.8 (`use std::hint::black_box()` instead) and the bench imported
it. Fixed in `benches/select_active.rs`; clippy is clean afterwards. This is
the kind of defect that only compiling finds.

## Benchmark

```bash
taskset -c 4 cargo bench --locked --bench select_active -- \
  --sample-size 30 --measurement-time 3 --warm-up-time 1
```

Two independent runs; medians agree within ~2 % except where noted.

| scenario | before, µs | after, µs | delta |
|---|---:|---:|---:|
| n=64, 1 % active | 0.07 | 0.06 | −12.9 % |
| n=64, 50 % | 0.33 | 0.07 | −79.1 % |
| n=64, 99 % | 0.34 | 0.08 | −76.6 % |
| n=4096, 1 % | 3.51 | 3.26 | −7.1 % |
| **n=4096, 50 %** | **11.75** | **18.90** | **+60.9 %** |
| n=4096, 99 % | 6.92 | 6.31 | −8.9 % |
| n=262144, 1 % | 214.57 | 214.67 | ±0.0 % |
| n=262144, 50 % | 1340.01 | 1302.51 | −2.8 % |
| n=262144, 99 % | 477.11 | 433.77 | −9.1 % |

What the numbers support:

- At n=64 the allocation strategy dominates: the growth path reallocates
  several times for a few dozen elements, so `with_capacity` is 4–13× faster
  in *relative* terms (tens of nanoseconds in absolute terms — irrelevant to a
  real program).
- At n=262144 the difference is −3…−9 % for dense outputs and zero for a 1 %
  output: the copy cost of growth is amortised, and reserving 2 MB is not free
  either.
- The n=4096, 50 % row says `with_capacity` is 60 % **slower**. That is not a
  code property; see below.

## The +60 % is an allocator-state artifact, not a regression

`criterion` runs `before` and `after` **sequentially in one process**, always
in that order. When allocation dominates, the allocator state left by the
first variant changes what the second one pays.

A standalone interleaved batch test (2000 iterations per batch, 6 rounds,
order alternated) shows it directly:

| n=4096, 50 % | times per round, µs |
|---|---|
| before | 17.62, 17.68, 17.89, 17.92, 17.95, 18.14 |
| after | 12.57, 12.59, 12.71, **18.60, 18.61, 18.62** |

`after` is bimodal: ~12.6 µs when it runs first in a round, ~18.6 µs when it
runs after `before`. The median of a bimodal distribution is meaningless, and
criterion always samples the second mode because of its fixed order.

Control cases from the same test (stable, not bimodal):

| scenario | before | after | delta |
|---|---:|---:|---:|
| n=4096, 99 % | 6.33 | 6.23 | −1.6 % |
| n=4096, 1 % | 3.30 | 3.14 | −4.8 % |

(At 50 % the branch `if active != 0` is unpredictable too, which is why both
variants are slower there than at 99 % — a second effect, visible in both.)

## Harness validation: both verdict paths, real runs

The same case crate was copied to a separate git repository and driven through
`autor3search-rust` itself (`init` → `doctor` → `baseline` → one patch →
`eval --json`), with `count: 4`, `sample_size: 10`, `measurement_time: 1s`
to keep each experiment short.

| run | declared benchmark | verdict | score | reason |
|---|---|---|---:|---|
| nov9 | `before/n=262144/active=99%` | **DISCARD** | 0.9920 (−0.80 %) | `no_significant_improvement` |
| nov9b | `before/n=4096/active=50%` | **KEEP** | 0.9497 (−5.03 %) | `improved` |

Both paths work: a row is written for each, `KEEP` advances `measure_commit`
and re-points the pinned worktree, `DISCARD` means `git reset --hard HEAD~1`.
The harness also warned that a 95 % interval needs ≥ 6 observations and
`count: 4` cannot produce one — correct, and worth heeding before trusting
either verdict.

The measurement is cross-process (pinned worktree vs candidate), which is why
it disagrees with the in-process criterion run above: `n=262144/99 %` measured
−9 % in-process and −0.8 % here; `n=4096/50 %` measured +60 % in-process and
−5 % here. That is the allocator-state artifact from the previous section, seen
from the other side: **the separate-process measurement is the trustworthy
one.**

## Conclusions

1. `with_capacity` is **not** automatically faster. It wins when the output is
   dense and large, and when the output is tiny the relative win is real but
   irrelevant in nanoseconds.
2. Sequential in-process benchmarking of two allocation-heavy variants can
   attribute allocator state to the second variant. Benchmark each variant in
   a separate process, or interleave at the process level, or at minimum
   alternate the order and report the distribution.
3. Report absolute times as well as percentages: −79 % of 330 ns is 60 ns.

## What is still not verified

- `perf` sampling (denied here), so no instruction-level explanation.
- 1.88.0 builds and tests the case (MSRV verified for tests); clippy was not
  run on 1.88 because its component is not installed.
- Rust 1.99.1 stable and 1.100.0-beta.13 both build, test and lint.
- Other CPUs, other allocators (`jemalloc`, `mimalloc`), other selectivities.
- The guide's own claim that the case "may retain excess capacity for sparse
  outputs": true by construction, but its cost is not measured here beyond the
  n=262144, 1 % row, where it did not matter.

Reproduce with the commands above; treat a single run as a hypothesis, not a
result.
