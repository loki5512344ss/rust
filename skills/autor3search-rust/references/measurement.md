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
(`docs/rust_perf_case/RESULTS.md` in the autor3search-rust repo) showed
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
