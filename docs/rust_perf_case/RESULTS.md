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

`perf record` was denied when this case was run (`perf_event_paranoid=2` and
the kernel refused `cpu/cycles/Pu`), so no sampling profile is included.
Re-checked on 2026-11-12, same machine: flat `perf record` (`cycles:u`,
`task-clock:u`) works, every call-graph mode (`-g`, `--call-graph dwarf`) is
still refused. The measurements below were not redone with a profile. Absolute
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
cargo fmt --all -- --check          # passes after rustfmt was applied to two files
cargo test --locked --all-targets     # 2 integration tests + all bench scenarios in test mode: ok
cargo clippy --locked --all-targets -- -D warnings
bash scripts/smoke.sh                 # fmt + test + clippy + the full bench: passes
python3 scripts/analyze_abba.py scripts/sample_synthetic.csv   # synthetic only
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

## False-sharing example (wall-clock only)

`examples/false_sharing.rs` was added with the 2026-11-09 edition. On this
machine, 4 workers, 5,000,000 `fetch_add` per worker, `taskset -c 4-7`,
interleaved `dense/padded/padded/dense` × 3:

| variant | wall time |
|---|---|
| `dense` (four adjacent `AtomicU64`) | 337, 380, 382, 389, 340, 387 ms |
| `padded` (`#[repr(align(64))]` each 64 B) | 34.5, 35.5, 38.8, 54.4, 33.9, 33.9 ms |

That is roughly a **7–11×** difference, which is the expected order for
cache-line ping-pong on a 4-thread contended counter experiment. It is a
wall-clock result only: `perf c2c`/`perf mem` are denied here
(`perf_event_paranoid=2`), so no HITM counts, no offsets and no causal proof
from hardware counters. The 64-byte alignment is an x86-64 assumption, not a
portable one, and the host was under load 7–11.

The statistical helper `scripts/analyze_abba.py` was run on
`scripts/sample_synthetic.csv`: it reports `scenarios=1`,
`individual_CI_level=95.000%`, a paired bootstrap interval and an explicit
"fewer than 10 paired blocks: exploratory" warning, and states that no
Mann–Whitney U is computed. That validates the code path on labelled synthetic
data, not any Rust result.

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

- `perf` sampling (denied here), so no instruction-level explanation. The same
  denial blocks `perf stat --topdown`, `perf mem` and `perf c2c`, so §31.6–31.8
  remain unexercised on hardware counters in this fork.
- False sharing is shown by wall time (~7–11×) but not proven by HITM counts;
  `dense` vs `padded` is also not a general serving workload.
- 1.88.0 builds and tests the case (MSRV verified for tests); clippy was not
  run on 1.88 because its component is not installed.
- Rust 1.99.1 stable and 1.100.0-beta.13 both build, test and lint.
- Other CPUs, other allocators (`jemalloc`, `mimalloc`), other selectivities.
- The guide's own claim that the case "may retain excess capacity for sparse
  outputs": true by construction, but its cost is not measured here beyond the
  n=262144, 1 % row, where it did not matter.

Reproduce with the commands above; treat a single run as a hypothesis, not a
result.

## Fork scripts, run on 2026-11-12

The five new fork scripts and the patched `bench-ab.sh` were executed on this
machine (idle, 1-min load 1.5–3 of 24). A/B pair for the timing scripts:
`target/release/examples/false_sharing dense 4 N` vs `padded 4 N` from this
crate. The runs found two real bugs (both hyperfine 2.0 / locale traps that
only execution reveals) and disproved no header claim. Every non-zero exit
below was fired on purpose.

| script | command (from `docs/rust_perf_case`) | exit | observation |
|---|---|---:|---|
| `bench-ab.sh` | `--runs 10 --warmup 1 --blocks 5 --prepare 'true' -- dense-1M padded-1M` | 0 | blocks alternate AB/BA/AB/BA/AB, every block −84…−89 % — same sign in AB and BA blocks, so the side mapping is right; overall −87.18 % (81.76 vs 10.49 ms); `--json` carries the per-run times |
| `bench-ab.sh` (guards) | `--runs 3 --warmup 1 -- …`; `--max-load 0.0001 -- …` | 2; 1 | refuses fewer than 2 runs per block; busy-machine refusal fires on a tiny `--max-load` |
| `instr-count.sh` | `--runs 3 --json /tmp/instr.json -- dense-2M padded-2M` | 0 | instructions 12,944,634 vs 12,944,541 (−0.00 %, ranges overlap) while cycles −90.66 %: same work, ten times the stalls |
| `instr-count.sh` (failure) | `--runs 1 -- 'exit 7' 'true'` | 1 | a failing command is reported, nothing is measured |
| `layout-check.sh` | `--runs 10 --pads "0 1024" -- dense-2M padded-2M` | 0 | −89.86 % at pad 0 and −89.96 % at pad 1024 → `stable`; `LAYOUT_PAD` provably reaches the measured command (`printenv` inside a hyperfine run prints 1025 bytes) |
| `vec-remarks.sh` | `--bench select_active` (+ `--filter select_active.rs`) on this crate; `--example loops` / `--lib` on a scratch crate with one vectorizable and one non-vectorizable `#[inline(never)]` fn | 0 | remarks are captured through the RUSTC_WRAPPER: 5 applied / 51 missed (loop-vectorize) and 19 / 147 (slp) for the bench; the bench's own loops (`select_active.rs:9,13,16`) are missed with reasons; the scratch example yields one success plus one missed with 3 analysis lines |
| `perf-diff.sh` | `-- dense-20M padded-20M` | 0 | two flat `cycles:u` records; the dense closure holds 99.97 % of A (16.17 G cycles), the padded closure +99.86 % of B (1.52 G) |
| `perf-diff.sh` (failures) | `-- dense-2M 'exit 3'`; `-- 'true' 'true'` | 1; 0 | a nonzero command aborts honestly; near-empty records degrade to shell symbols and fire the stripped-binary hint |
| `diff-fuzz.sh` | `--out <scratch>/tests --old o --new n --sig {slice-u64, slice-u8, str} --iters 300…500`, then `cargo test --release --test diff_fuzz` | 0/1 | all three signatures ran: an equal pair passes; `saturating_add` vs `wrapping_add` fails and the printed `DIFF_FUZZ_REPLAY=…` reruns the exact case; a `str` pair differing on blank lines fails (old=163, new=158); writing into a `tests/` under an autor3search run is refused (exit 1); usage errors exit 2 |

Bugs found by executing, fixed in the scripts:

1. **hyperfine 2.0 defaults to `--shell=none`.** The command string is
   word-split and exec'd, so `a && b`, pipes or `VAR=x cmd` silently measure
   the wrong thing (`hyperfine -- 'echo abc | wc -c'` prints `abc | wc -c`,
   exit 0). `bench-ab.sh` and `layout-check.sh` now pass `--shell=default`
   before any user extras, so an explicit `-N`/`--shell` from the caller
   still wins.
2. **perf's CSV output is locale-dependent.** Under `ru_RU.UTF-8` the
   percent-enabled field is `100,00`, which the `-x,` separator splits in
   two, so the multiplexing check in `instr-count.sh` read a truncated
   number. The script now forces `LC_ALL=C` for its perf runs.

The `vec-remarks.sh` header claims were re-verified on purpose: a lib
`pub fn` without `#[inline(never)]` emits no remarks (checked both ways on
the scratch crate), `-C codegen-units=16` silences all remarks, omitting
`-C debuginfo` yields `<unknown file>:0:0` plus the warning, and the
RUSTC_WRAPPER tee works through cargo.

Still not verified after this run:

- No "tool missing" refusal fired: hyperfine, perf, python3 and cargo are
  all installed here, and the perf-denied refusal ladders in
  `instr-count.sh` and `perf-diff.sh` cannot fire while flat counters and
  flat records work.
- `instr-count.sh` never hit counter multiplexing (4 events fit the PMU);
  `bench-ab.sh`'s post-run load warning never fired (only the pre-run
  refusal did).
- `layout-check.sh` perturbs only the environment axis; link order and
  alignment are manual follow-ups by design.
- Absolute instruction counts drifted ~5 % between script invocations
  minutes apart (12.94 M vs 13.65 M for the same command) while staying
  within ±0.003 % inside each interleaved run — compare A and B within one
  session, never across sessions.
