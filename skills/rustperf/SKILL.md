---
name: rustperf
description: Use when asked to make a Rust crate faster, optimize or tune Rust performance, fix a slow function or hot loop, reduce allocations/latency/binary size, read x86-64 asm or LLVM IR to explain a regression, benchmark with criterion or hyperfine, profile with perf or samply, experiment with several rewrites of the same code and log the proven method, or run an rustperf KEEP/DISCARD optimization loop. Triggers include "ускорить", "оптимизировать Rust", "тормозит", "почему медленно", "поэкспериментируй с оптимизацией", "cargo asm", "perf annotate".
---

# rustperf: measure, diagnose, patch, prove

The harness measures; you propose. One hypothesis, one minimal patch, one
measurement, one verdict. A number without a command that produced it is a
guess, and a guess is not a result.

**Order of operations, always:** asm/IR explains *why*. Profiles and
benchmarks decide *whether*. Never lead with an optimization idea you have not
localized in a profile or a disassembly.

## Two modes

| The request | Mode | Read first |
|---|---|---|
| "make this faster", one known hot spot, a regression to fix | **Fix mode** (default): one hypothesis, one minimal patch | this file |
| "experiment with optimizing this", "try a few approaches", "rewrite it several ways" | **Experiment mode**: 4–8 structurally different implementations, each measured against a frozen baseline, winner kept, method written to `OPTIMIZATION_LOG.md` | `references/experimentation.md` |

Experiment mode does **not** relax the iron rules. Radical rewrites are allowed;
mixing two ideas in one candidate is not, and an unmeasured rewrite is not a
result. The log entry is part of the deliverable: a proven method with numbers,
costs and applicability conditions — or an honest "nothing beat the noise".

## Iron rules

1. **No unmeasured claim.** "Faster", "fixed", "no regression" require a
   command and its output in the same session. Otherwise write `not measured`.
2. **One idea per experiment.** A diff that changes two things cannot be
   attributed; if the number moves, you do not know why.
3. **Never fake the score.** Do not edit `tests/**`, `benches/**`, inline
   `#[cfg(test)]` blocks, doctests, `program.md`, `.rustperf/config.yaml`,
   or `results.tsv`. The harness restores or fails these; a "win" obtained by
   weakening the judge is fraud.
4. **Semantic contract first.** Before touching code, write down what must
   stay identical: output bytes, ordering, stable sort, event order, panic vs
   error, float tolerance, overflow behavior, API/layout.
5. **No `unsafe` as an optimization.** This fork's harness fails any
   experiment that adds or changes an `unsafe` region (`FAIL(unsafe_added)`);
   upstream's does not, and neither catches a safe edit that breaks an existing
   region's invariant. Outside the harness loop nothing checks at all: every
   `unsafe` you introduce is unreviewed UB surface. `get_unchecked` is the
   cheapest fake win in Rust and the most expensive bug.
6. **Order of attack:** asymptotics → remove work → allocations → data layout
   and cache → branches → instruction-level → compiler flags. Flags and
   intrinsics last, because they hide the real problem.
7. **Small N matters.** Every optimization must be checked on empty, tiny,
   median and huge inputs, and on the real distribution, not just the
   benchmark's favorite size.

## Phase 0 — establish the target

Do this before proposing anything:

```bash
git status                      # dirty tree -> stop, ask, do not "just" proceed
rustc -Vv                       # record the exact compiler
cargo metadata --no-deps -q >/dev/null   # project sanity
```

If the request names a symptom ("slow", "p99", "memory"), pin it to a
*measurable* quantity: a benchmark id, a CLI command with a fixed input, a
test that must stay under X ms. Write it down; it is the acceptance test.

## Phase 1 — choose the measurement instrument

| What you are optimizing | Instrument |
|---|---|
| a library function / hot loop | `criterion` bench (this is what the harness reads) |
| a CLI binary end to end | `hyperfine` (`--warmup`, `--runs`, `--export-json`) |
| shared library / server | `hyperfine` + `perf stat` on a fixed workload |
| binary size / compile time | `cargo bloat`, `cargo build --timings` |
| no benchmark exists | write one **first**, then come back |

`hyperfine` quick start (present on this machine):

```bash
hyperfine --warmup 3 --runs 20 \
  --prepare 'sync; echo 3 | sudo tee /proc/sys/vm/drop_caches' \
  './target/release/app input.bin' \
  './target/release/app.new input.bin' \
  --export-json bench.json
hyperfine --warmup 3 --runs 20 -L size 1k,10k,1M './app {size}'
```

Read `references/measurement.md` before trusting a number: warmup, ABBA
ordering, thermal drift, `black_box`, and the fact that a microbenchmark is
not your application.

**The harness only reads criterion.** `rustperf eval` shells out to
`cargo bench` with a criterion filter; it cannot consume a `hyperfine` result,
a `time` output, or a custom harness. So:

- a CLI/library with a criterion bench → the harness loop works;
- a CLI without one → `hyperfine` can still prove your change by hand, but the
  autonomous loop needs a criterion target first;
- adding a Cargo bench target is a `Cargo.toml` change, which is a **locked
  file** and a human decision — propose it, do not sneak it in mid-run.

## Phase 2 — localize the cost before touching code

```bash
# CPU: where the time goes (symbol + call graph)
perf record -F 999 -g -- ./target/release/app input.bin
perf report --stdio --sort=dso,sym
perf annotate --stdio -s <symbol>      # line/instruction-level samples
perf stat -r 7 -e cycles,instructions,branches,branch-misses,cache-references,cache-misses -- ./target/release/app input.bin

# sampling profiler with a UI, no kernel perf needed
samply record ./target/release/app input.bin

# if perf says "not permitted"
cat /proc/sys/kernel/perf_event_paranoid   # 2 = user-space only; 1 or 0 for kernel symbols
```

`paranoid=2` is documented as "user space only", but some kernels/containers
still refuse `perf record` outright (`Failure to open event 'cpu/cycles/Pu'`).
Fallback ladder, in order:

1. `perf stat` — often still works when `record` does not. Instruction
   counts A/B: `scripts/instr-count.sh`.
2. Flat sampling without `-g`: `perf record -e cycles:u` or `-e task-clock:u`.
   A kernel that refuses call graphs (`-g`, `--call-graph dwarf`) may still
   allow these; you get hot symbols and `perf annotate`, no stacks.
3. `samply record -- ...` (does not need kernel perf counters).
4. No profiler at all: `--emit=asm`, criterion/hyperfine, and a counting
   global allocator in a **bench-only** binary (`#[global_allocator]` in the
   bench harness, never in the measured crate). Allocation counts localize
   the cost when samples are unavailable; say in the report that sampling
   was unavailable.

Classify the bottleneck out loud before optimizing:

- **CPU-bound** — instructions/cycle high, cache misses low → remove work, vectorize.
- **Memory-bound** — LLC/cache misses high, IPC low → layout, prefetch, SoA, smaller types.
- **Contention** — `perf stat` shows low IPC on many cores, `perf c2c` shows cache-line bouncing → locks, atomics, false sharing.
- **Latency/I-O bound** — syscall time, blocking in async → buffering, batching, `spawn_blocking`.
- **Branch-bound** — `branch-misses` high → predictability, `cmov`, sorting, early exit.
- **Unknown** — say so. Do not invent a story.

## Phase 3 — read the machine code (this is where "why is it slow" is answered)

Full workflow in `references/asm-reading.md`. Minimum loop:

```bash
# 1. Rust source -> asm for one function, no linker noise
#    cargo-show-asm: pick the artifact (--lib / --bin NAME / --bench NAME)
cargo asm --lib 'crate::module::function'
cargo asm --lib --rust 'crate::module::function'       # interleaved Rust lines

# 2. Whole-binary disassembly with symbols
objdump -d -C --no-show-raw-insn target/release/app > app.asm
nm -C target/release/app | grep -E 'hot|process|score'

# 3. Compiler-internal views
cargo rustc --release -- --emit=mir,llvm-ir,asm   # target/release/deps/*.mir/.ll
rustc --emit=mir,llvm-ir,asm example.rs

# 4. Port/throughput pressure on a hot block
llvm-mca -mcpu=native -iterations=100 hot_loop.s
```

Read asm **with the profile**, in this order:

1. Find the hot symbol from `perf report`. A symbol that is 0.3% is not your problem.
2. In `perf annotate`, find the address range holding most samples.
3. Map that address to a Rust line (`cargo asm --rust`, debug info from
   `RUSTFLAGS='-C debuginfo=1 -C force-frame-pointers=yes'`).
4. Name the instructions that dominate: `call` into allocator, `idiv`,
   `lock` prefix, `mov` to/from memory with a bad stride, bounds-check
   panic path, `cmov` chains, spills (`mov [rsp+..]`), missing vector ops.
5. Check how *often* the block executes. One expensive instruction in a cold
   path is irrelevant; 200 cheap instructions in the inner loop are not.
6. Compare before/after asm with `diff -u before.s after.s` — an optimization
   that did not change the asm did not happen.

Instruction dictionary, latency/throughput reasoning, and the
"presence of an instruction is not proof of cost" rule:
`references/asm-reading.md`.

## Phase 4 — propose, ordered by expected value

Three ideas maximum, each with: operation removed, expected asm/IR change,
risk, and how you will measure it. Then pick the cheapest high-probability
one.

1. **Asymptotics and redundant work** — O(n²) → O(n log n), repeated scans,
   recomputation, needless `collect()`.
2. **Allocations and copies** — `String::with_capacity`, reuse buffers,
   `Cow`, avoid `clone()` in the hot path, `Box<[T]>`, `SmallVec`.
3. **Containers and hashing** — `HashMap` hasher, `IndexMap`, `BTreeMap` for
   range scans, `VecDeque`, `BinaryHeap`, dense index instead of map.
4. **Layout and cache** — SoA vs AoS, hot/cold split, ordering by size,
   `Vec` of structs vs indices, alignment/padding, false sharing.
5. **Loops and bounds checks** — iterators over indexing, `chunks_exact`,
   `zip`, hoisting length, proving bounds to LLVM, `get_unchecked` only with
   a written proof of every caller's invariant.
6. **Branches** — sort/partition by frequency, early exit, `match` ordering
   by real distribution, `cmov` only when both sides are cheap.
7. **SIMD** — autovectorization-friendly loops first, `std::simd`/portable
   SIMD or `target_feature` + runtime dispatch second, tail handling always.
8. **Compiler flags** — `lto`, `codegen-units=1`, `target-cpu`, PGO/BOLT.
   These are human decisions: propose, do not silently change `Cargo.toml`.

Catalog with "when it hurts": `references/optimization-catalog.md`.

## Phase 5 — the rustperf loop (only when asked / repo has benches)

```bash
cargo install --locked --git https://github.com/loki5512344ss/rustperf   # this fork: unsafe gate, per-benchmark JSON
# or from a checkout:  cargo install --locked --path <checkout>
git status                                  # must be clean
rustperf init                      # shows discovered benchmarks
git add -A && git commit -m "rustperf init"
rustperf doctor                    # machine fit to measure?
rustperf baseline --tag "$(date +%b%d)"
# then follow program.md exactly, verbatim, to the end
```

Non-negotiables from the harness contract:

- `git status` dirty → stop and ask. The baseline refuses it anyway.
- No benchmarks discovered → stop and say so. It can only optimize what it
  measures; do not invent a runner.
- `doctor` warnings about throttling/battery/load average → report them; a
  noisy machine produces confident wrong numbers.
- One commit per experiment, before `eval`. `KEEP` keeps the commit; anything
  else means `git reset --hard HEAD~1`.
- `eval --json` prints one JSON object and nothing else. Do not wrap it in
  other output.
- `stop_requested: true` → apply that verdict, run `rustperf report`,
  summarize, exit the loop. Never start another experiment.
- Never pass `--force` to any command. The human owns `stop --force`.
- Never edit files the harness owns (`program.md`, config, `results.tsv`, run
  state under the cache dir).

CLI details, config schema, verdict codes and scoring math:
`references/harness-cli.md`.

## Phase 6 — prove correctness, then prove speed

```bash
cargo test --workspace                 # debug: overflow checks and debug_assert! armed
cargo test --release --workspace
cargo clippy --workspace --all-targets # optional, only if the repo already is clean
hyperfine ... (or criterion) with before/after binaries
perf stat ... before/after            # cycles, instructions, cache-misses
```

Report both the win and the cost: binary size, compile time, readability,
new dependencies, memory. A 3% win that adds an `unsafe` block is a loss.

## Fork scripts (in the fork checkout's `scripts/`)

| Script | Use it when |
|---|---|
| `bench-ab.sh` | wall-clock A/B of two commands, interleaved blocks |
| `instr-count.sh` | the wall-clock delta is inside the noise: A/B by `perf stat` instruction counts (`measurement.md` §9) |
| `layout-check.sh` | a win is under ~3 %: does it survive a layout perturbation? (`measurement.md` §10) |
| `perf-report.sh` / `perf-diff.sh` | evidence bundle for one binary / before-vs-after profile (`profiling.md` §3c) |
| `asm-report.sh` | before/after asm of one function |
| `vec-remarks.sh` | "why is this loop not vectorized" from LLVM remarks, before reading asm (`profiling.md` §7b) |
| `diff-fuzz.sh` | scaffold an old-vs-new differential test with no dependencies (`semantics-traps.md` §8c) |

Instructions detect and attribute; wall-clock decides. A result that
`layout-check.sh` calls `layout-sensitive` is reported as "no effect".

## Output contract

Every optimization report uses exactly these sections. Missing section =
incomplete work, not "not applicable" unless you say `not measured` /
`not inspected`.

```text
DIAGNOSIS      what is hot, and the evidence (profile %, counters)
CONTRACT       what must stay byte-identical / ordered / panic-identical
HYPOTHESIS     which operation disappears; expected MIR/LLVM/asm change
PATCH          smallest diff that tests the hypothesis
CORRECTNESS    tests run, edge cases covered, contract changes declared
BENCHMARK      exact commands, raw times, dispersion, p-value if any
ASSEMBLY       before/after hot block diff, or "not inspected"
DECISION       keep / revert / unknown, and why
```

## References

| File | Read when |
|---|---|
| `references/experimentation.md` | running a multi-variant experiment and logging proven methods |
| `references/asm-reading.md` | you must explain *why* code is slow from machine code |
| `references/measurement.md` | designing or trusting a benchmark; hyperfine/criterion/perf stat |
| `references/profiling.md` | perf record/report/annotate, samply, flamegraphs, cache/contention counters |
| `references/harness-cli.md` | driving rustperf: commands, config, verdicts, scoring |
| `references/optimization-catalog.md` | choosing what to try, with "when it hurts" |
| `references/semantics-traps.md` | before any change that touches behavior, floats, ordering, threads |
| `references/diagnostics.md` | symptom → instrument → likely cause lookup |
| `references/examples.md` | worked before/after with measurements and asm |

## Red flags — stop and reconsider

- You are about to say "faster" without a command output in this session.
- You are editing a test, bench, or boundary to make the number go up.
- Your diff changes two unrelated things.
- You reached for `unsafe`, `#[inline(always)]`, `-C target-cpu=native`, or
  `wrapping_*` before profiling.
- You have a profile but have not looked at a single instruction the samples
  point to.
- The optimization is invisible in the asm — you changed style, not code.
- The win only appears at one input size, or only in debug, or only once.
- You cannot state what would make you revert.
