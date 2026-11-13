# Measurement: making a number you can defend

A benchmark is an experiment. If it lacks a control, a warmup, and a repeat
count, it produces opinions with decimal points.

## 1. Pick the instrument by scope

| Scope | Tool | What it actually measures |
|---|---|---|
| one function / hot loop | `criterion` | in-process time of the closure, per iteration |
| whole CLI invocation | `hyperfine` | wall clock of process launch → exit |
| server request path | `hyperfine` + load generator, or `hdrhistogram` | latency distribution, p50/p99 |
| CPU behavior | `perf stat` | cycles, instructions, misses, for a whole run |
| where time goes | `perf record` / `samply` | sampled stacks |
| allocations | `heaptrack`, `dhat`, counting allocator | count/bytes/peak |
| binary size | `cargo bloat --release` | symbol sizes |
| compile time | `cargo build --timings` | per-crate units |

Using `hyperfine` to prove a hot-loop win is a common error: process startup,
dynamic linking, and file cache can dominate the delta. Using `criterion` to
prove an end-to-end win is the opposite error: the app's I/O and startup are
invisible.

## 2. hyperfine (installed: v2.0)

```bash
# A/B two binaries, 20 runs after 3 warmups, JSON for later analysis
hyperfine --warmup 3 --runs 20 \
  './target/release/app.before input.bin' \
  './target/release/app.after  input.bin' \
  --export-json bench.json

# Parameter sweep (matrix of args)
hyperfine --warmup 2 --runs 15 -L n 1e3,1e5,1e7 './app {n}' --export-markdown sweep.md

# Reset page cache between runs (needs root; drop only if the workload is I/O-bound)
hyperfine --prepare 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches' \
  --runs 10 './app big.bin'

# Compare shell-invocation variants honestly
hyperfine --shell=none './app --fast' './app --safe'
```

Rules that change the conclusion:

- `--warmup`: the first run pays dynamic linking and cold caches. Always ≥ 2.
- `--runs`: hyperfine prints mean ± σ and a range; below ~10 runs the interval
  is theater. It also warns when the spread is large — read the warning.
- **Outliers are information.** A 3× max with a tight median means scheduling
  or I/O jitter, not a slow algorithm.
- `--shell=none` removes the shell from the measurement; use it unless you are
  deliberately measuring a pipeline.
- Pin the CPU when comparing: `taskset -c 2 hyperfine ...`, and keep the
  machine otherwise idle (`uptime`, `top`).
- Both variants must read **the same input file** and run with the same
  environment, `RUSTFLAGS`, and build profile.
- Do not compare numbers across machines, sessions, or thermal states.

## 3. criterion

```toml
[[bench]]
name = "parse"
harness = false
```

```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion, Throughput};

fn bench_parse(c: &mut Criterion) {
    let input = std::fs::read("benchdata/input.txt").unwrap();
    let mut g = c.benchmark_group("parse");
    g.throughput(Throughput::Bytes(input.len() as u64));
    g.bench_function("parse_line", |b| b.iter(|| {
        black_box(parse(black_box(&input)))
    }));
    g.finish();
}
```

- `black_box` on the input prevents constant folding; on the output prevents
  dead-code elimination. A benchmark without it may measure nothing.
- Feed runtime data (file, env, generated buffer), not literals the optimizer
  can precompute.
- `Throughput` turns ns into MB/s and makes scaling across sizes readable.
- Sample size defaults are usually fine; raise only when noise demands it.
- Run `cargo bench` — never a debug `cargo run` with a timer.
- Criterion compares against the previous run in `target/criterion/`; use
  `--save-baseline` / `--baseline` for deliberate A/B. The raw medians live in
  `target/criterion/<bench>/<tag>/estimates.json` — read them, and never quote
  criterion's own `change` percentage across sessions: a saved baseline taken
  under different load inflates the delta (a real run reported −41 % where
  interleaved rounds showed −31 %, and a −11 % "regression" in an untouched
  function that was pure drift).

## 4. ABBA / interleaved protocol

Thermal drift and CPU frequency make "measure A, then B" unreliable. Alternate:

```text
warmup: A B
round 1: A B
round 2: B A
round 3: A B
... 5–10 rounds, alternate order each round
```

Then compare distributions (median + spread, or a rank test), not means of
means. This is exactly what the harness does; when you benchmark by hand,
copy it. Record raw per-round numbers, not just the summary.

## 5. Timer placement

Bad: one `Instant::now()` per iteration — the clock dominates short
operations and perturbs the pipeline.

```rust
// bad for sub-microsecond work
for _ in 0..n { let t = Instant::now(); work(); sum += t.elapsed().as_nanos(); }

// good: time a batch, subtract an empty-batch control
let t = Instant::now();
for _ in 0..n { black_box(work()); }
let total = t.elapsed();
```

Subtract the loop overhead with a no-op batch when the per-item cost is tiny.
Warm up the allocator and caches before the measured region.

## 6. Statistics you are allowed to claim

- Report **median and dispersion**, and the raw runs.
- A difference is worth acting on when it exceeds both the noise band and a
  practical floor (the harness default: ≥ 1 % and `p < 0.05/k`).
- With fewer than 4 samples per side, a rank test cannot reach significance at
  all (best two-sided p = 0.1 at n=3). Small-n experiments prove nothing.
- "2× faster" from one run is a story, not a result.
- If the effect is real but < 1 %, write `real but below threshold` — not
  "no change".

### 6.1. Which test, and why the pairing matters

ABBA blocks are **paired, dependent** observations: A and B in the same block
share the machine state. Resample *whole blocks*, never individual iterations.

| Data / question | Valid procedure | What it cannot tell you |
|---|---|---|
| paired ABBA blocks, effect + CI | **paired bootstrap of `log(A/B)`** (percentile CI) | causality; small-n CIs are optimistic |
| paired blocks, test of zero shift | Wilcoxon signed-rank or paired permutation | assumes something about the pair-difference distribution (signed-rank), design-dependent (permutation) |
| two independent samples, no pairing | Mann–Whitney U | **not** a valid main test for paired ABBA data; not a test of equal medians without extra assumptions |
| m pre-declared scenarios | **Bonferroni** (`alpha/m` per test; simultaneous CI) or **Holm** (step-down p-values) | it is a correction, not a test; Bonferroni is conservative |

Rules: fix the minimum useful effect *before* the run (e.g. 2 %), report the
family alpha and how many hypotheses were tested, and do not promote the one
scenario that happened to pass. If the interval includes 1.0, or excludes it
but stays below the practical floor, the verdict is `unknown`, not `keep`.
`p < 0.05` alone is not an engineering result.

## 7. Things that silently invalidate a measurement

| Invalidator | Fix |
|---|---|
| debug build | `--release`, assert the profile in the report |
| different `RUSTFLAGS` between sides | same flags, clean `target/` or `CARGO_TARGET_DIR` per side |
| different inputs or seeds | same file, same seed, same env |
| first-run cold effects | warmup runs, or measure cold deliberately and say so |
| background load | idle machine, check `uptime` before and after |
| frequency scaling / thermal throttle | `doctor`-style check, AC power, short sessions |
| CPU migration between cores | `taskset -c N` for both sides |
| `black_box` missing | optimizer may delete the work |
| measuring startup instead of work | criterion, or `hyperfine` with an in-process loop |
| benchmark tuned to one size | sweep n = 0, 1, 2, 3, 16, 1k, 1M |
| comparing against a stale baseline | re-measure both sides in the same session |
| two variants benchmarked sequentially in one process | allocator state from A biases B; run each in its own process or alternate order and check the distribution |

**Allocator-state contamination is real and easy to miss.** A measured case
(`docs/rust_perf_case/RESULTS.md` in the rustperf repo) showed
`with_capacity` at +60 % in criterion, because variant A ran first and changed
the allocator state for variant B. A standalone interleaved test revealed a
bimodal distribution: the second variant was ~50 % slower whenever it ran
after the first, regardless of which code it was. If a result appears only for
the second benchmark in a file, suspect state, not code.

## 8. Report format

```text
machine:  <cpu>, <cores>, <os/kernel>, <power state>
rustc:    <rustc -Vv output>
build:    crate@commit, profile=release, RUSTFLAGS=...
input:    <file/size/seed>
method:   hyperfine --warmup 3 --runs 20 | criterion sample_size=N | harness eval
raw:      before: [ ... ], after: [ ... ]
summary:  median A → B, delta %, dispersion, n, p (if tested)
caveat:   what this does not measure
```

If any line is missing, the result is `unknown`, not "faster".

## 9. Instruction counts as a second metric

Wall-clock answers "is it faster". Retired-instruction counts answer a
narrower question, "does it execute less code", with far less run-to-run
noise, so they expose changes that wall-clock noise hides and they still work
where sampling profilers are refused.

Observed on this machine (Xeon E5-2680 v3, rustc 1.99.1, perf 7.3.1,
`perf_event_paranoid=2`), 10 runs of a deterministic 20M-iteration xorshift
loop built with `rustc -O`:

```bash
for i in $(seq 10); do
  LC_ALL=C perf stat -x, -e instructions:u,cycles:u,task-clock:u -- ./work >/dev/null 2>s.txt
  awk -F, '{printf "%s ", $1} END{print ""}' s.txt
done
```

| metric | min | max | (max − min) / mean |
|---|---|---|---|
| `instructions:u` | 340 369 684 | 340 370 780 | 0.00032 % |
| `cycles:u` | 140 154 733 | 171 218 401 | 21.5 % |
| `task-clock:u` (ms) | 50.35 | 62.66 | 23.5 % |

One run in ten was ~20 % slower in cycles and time; the instruction count did
not move. That is one small, register-bound binary on an idle box; a program
with allocation, I/O or hash-seeded paths will vary more. Measure your own
spread before trusting a threshold. (`LC_ALL=C` matters: in a locale with a
decimal comma, `perf stat -x,` emits `52,45` and the CSV splits wrongly.)

How:

```bash
# one-off, user-space only (works at perf_event_paranoid=2 here)
perf stat -r 10 -e instructions:u,cycles:u,branches:u,branch-misses:u -- ./app input.bin

# interleaved A/B with medians and spread (fork script)
scripts/instr-count.sh --runs 15 --json instr.json -- './before input.bin' './after input.bin'
```

Simulated alternative: Callgrind (valgrind) counts instructions in a
simulator, so it works without any PMU access and is close to deterministic;
`iai-callgrind` wraps it for Rust benchmarks. Cost: tens of times slower than
native, and the cache model is a simulation, not your CPU. **valgrind is not
installed on this machine — not verified here.**

Limits, stated bluntly:

- **Instructions are not time.** A change can cut instructions and be slower:
  more cache or TLB misses, more branch misses, a longer dependency chain,
  `div` or gather instead of cheap ops, AVX frequency effects. SIMD often
  cuts instructions *and* time; a lookup table can cut instructions and add
  cache misses.
- **Counts still vary**: ASLR and environment size shift stack alignment and
  `memcpy` paths, allocator state changes code paths, hash seeds change probe
  counts, and multi-threaded code retires spin and scheduling instructions.
- **`:u` excludes the kernel.** Syscalls, page faults and I/O are invisible.
  A change that moves work into the kernel (bigger reads, `mmap`) looks free.
- `perf stat` covers the whole process, including startup and input parsing.
  For a sub-millisecond function, wrap it in a loop of known count or use a
  bench binary that does only that work.

Rule: **instructions to detect and attribute, wall-clock to decide.** A KEEP
needs the wall-clock (or criterion) result; an instruction delta without a
time delta is reported as `fewer instructions, no measured speedup`.

## 10. Layout bias: the 1–3 % that is not your change

Moving code changes where functions, loops and the stack land relative to
cache lines, pages, branch-predictor and µop-cache indexing. Effects of a few
percent have been shown from link order and from the size of the UNIX
environment alone (Mytkowicz, Diwan, Hauswirth, Sweeney, "Producing wrong
data without doing anything obviously wrong!", ASPLOS 2009). Stabilizer
re-randomizes code, stack and heap layout during a run so that a comparison
averages over layouts instead of sampling one (Curtsinger & Berger,
"STABILIZER: Statistically Sound Performance Evaluation", ASPLOS 2013).
Stabilizer targets LLVM C/C++ toolchains of its era — not verified with Rust.

So a 1–3 % delta from a patch is not yet evidence. Perturb the layout and see
whether it survives:

```bash
# repeats the A/B under environment sizes; verdict stable | layout-sensitive
scripts/layout-check.sh --runs 10 --pads "0 64 1024 4000" -- './before in.bin' './after in.bin'
```

By-hand perturbations (each one is a separate build of *both* sides, or of
the baseline alone as a placebo):

- a neutral edit: reorder two unrelated functions in the file;
- change link order: the order of `mod` declarations, or of objects on the
  link line. Confirm that the hot symbol actually moved with
  `nm -n target/release/app | grep <symbol>` before and after. (Changing
  `-C codegen-units` also moves code but changes inlining, so it is not a
  neutral edit);
- add an unrelated `#[inline(never)]` padding function that is called once
  so it is not removed, which shifts every following symbol;
- force a different function alignment for both sides:
  `RUSTFLAGS='-C llvm-args=-align-all-functions=6'` (2^6 = 64 B) vs `=4`.
  Observed here: in the §9 binary `nm -n` put `app::main` at `0x14c60` with
  `=4` and at `0x14d40` with `=6`, so the flag does move code;
- a placebo A/A: the baseline against itself rebuilt with one of the edits
  above. If A/A shows a 2 % "effect", your floor is at least 2 %.

Decision rule: **an effect that changes sign under layout perturbation is
reported as `no effect`.** An effect whose sign holds but whose size swings
is reported with the range across layouts, not the best layout.

Observed here: the xorshift binary from §9 under `env PAD=<0|64|1024|4000
bytes>` gave instruction counts within 340 369 829 – 340 370 711 and
`cycles:u` within 140 494 741 – 140 821 144 (3 runs per pad). No layout effect
was visible for that binary; this says nothing about yours.

When it misleads: `layout-check.sh` only perturbs the environment (stack
start) and times with hyperfine. It does not move code; a link-order or
code-alignment artefact survives it, so combine it with the by-hand edits
above. Treat `stable` as "not refuted", not "proven".

## 11. Performance regressions in CI

Shared cloud runners are noisy neighbours with unknown CPUs, frequency
policies and co-tenants. What survives that:

| Reliable on shared runners | Not reliable on shared runners |
|---|---|
| benchmarks compile and smoke-run (`cargo test --benches` runs each criterion bench once as a test) | wall-clock thresholds of 1–5 % |
| instruction counts (`perf stat -e instructions:u`, if the runner permits PMU access — many VMs do not) | comparing to a baseline measured on another runner, day or CPU model |
| simulated counts (Callgrind / `iai-callgrind`), which need no PMU | a single run deciding pass/fail |
| large regressions (2× and up) as a coarse alarm | criterion's printed `change` across sessions (§3) |

Minimal policy:

1. Store a baseline from the target branch: the per-benchmark instruction
   counts (or simulated counts) as a CI artefact, together with `rustc -Vv`,
   the runner CPU model and the commit.
2. Compare the PR against a baseline measured **in the same job** when you
   can (build both commits, interleave), not against last week's artefact.
3. Threshold above the measured A/A spread of that runner, not a guess.
4. On a breach, re-run the A/B before failing; fail only if the breach
   repeats with the same sign.
5. Wall-clock benchmarks that decide KEEP/DISCARD belong on a dedicated,
   quiet machine (as the harness does locally), not on shared runners.

Fork addition: the harness's `eval --json` reports per-benchmark deltas (name,
medians, `pct_change`, `p`, and the Bonferroni threshold) on KEEP and DISCARD,
not only the overall verdict, so a CI job can store and diff them without
re-parsing criterion's files. Verified with
`cargo test --test cmd_eval -- --ignored` (4 passed).

Criterion 0.8.2 (the version pinned in `docs/rust_perf_case/Cargo.lock`)
supports named baselines; confirmed with `cargo bench --bench select_active
-- --help` there:

```bash
cargo bench -- --save-baseline main      # on the target branch
cargo bench -- --baseline main           # on the PR; fails if a bench lacks the baseline
cargo test --benches                     # smoke-run: each bench once, no timing
```

`--baseline` compares wall-clock, so it inherits every limit of the right
column above when run on a shared runner.
