# Profiling: finding the 5 % that owns 80 % of the time

## 1. Before you profile

```bash
rustc -Vv
cat /proc/sys/kernel/perf_event_paranoid   # 2 = user-space only; 1/0 adds kernel symbols
perf --version
uptime                                      # is anything else running?
```

Build with symbols (a profiling build, see the caveat below):

```bash
RUSTFLAGS='-C debuginfo=1 -C force-frame-pointers=yes' cargo build --release
```

`debuginfo=1` keeps release codegen; `force-frame-pointers` makes stacks
walkable in `perf` but does change codegen (one register reserved, prologue
and epilogue), so absolute numbers from this build do not transfer to the
shipping binary. If `perf` says `not permitted`, do **not** casually lower
`perf_event_paranoid` on a shared machine — use `samply` or fall back (§7).

## 2. `perf stat` — the shape of the problem

```bash
perf stat -r 7 -e cycles,instructions,branches,branch-misses,cache-references,cache-misses \
  -- ./target/release/app input.bin
perf stat -d -- ./target/release/app input.bin      # more counters, may multiplex
```

`perf stat` writes to **stderr**.

| Observation | Likely cause | Look at |
|---|---|---|
| many cycles, few instructions (low IPC) | waiting on memory or a dependency chain | LLC misses, dTLB, `perf annotate` stall columns |
| high branch-miss rate | unpredictable `match`, data-dependent branches | event distribution, branch layout |
| many instructions, low branch misses | redundant work, formatting, copies | allocations, passes over data |
| many cache misses | poor locality, pointer chasing, big stride | SoA/AoS, packing, blocking |
| high sys time | syscalls, page faults, lock contention | batching, `strace -c`, `perf c2c` |
| low CPU%, high wall time | waiting on I/O, network, queue | latency traces, `pidstat`, async wakeups |
| p99 up, mean flat | lock, GC-like pause, scheduler, I/O | tail sampling, per-request traces |

Rules: `cache-misses` is not necessarily L1D misses — check the event
definition on your CPU. Multiplexed counters are scaled and less precise; start
with few events. Low IPC is not automatically bad (a bandwidth-bound kernel is
*supposed* to be stalled).

## 3. `perf record` / `report` / `annotate` — where the time goes

```bash
perf record -F 999 -g -- ./target/release/app input.bin
perf report --stdio --sort=dso,sym
perf report --stdio -g graph,0.5,caller     # inverted call graph
perf annotate --stdio -s <symbol>           # per-instruction samples
```

Workflow:

1. `perf report`: name the top symbols. Ignore < 1 % unless they are the thing
   you were asked to fix.
2. Check whether the hot symbol is your code or `memcpy`/allocator/`malloc`.
   Allocator at the top means the fix is allocation removal, not arithmetic.
3. `perf annotate -s sym`: find the address range holding most samples. The
   instruction with the highest percentage is the suspect.
4. Map it to source with `cargo asm --rust` or `perf annotate --source`.
5. Classify: `idiv`, `lock`, allocator `call`, spill (`[rsp+N]`), cache-load
   stall, branch mispredict.

`perf report` percentages are samples, not time guarantees; a 60 % sample
share on `idiv` means "look here first", not "idiv costs 60 %".

## 3b. Top-Down (TMA): which pipeline stage is starved

When counters show a problem but not its cause, split slots into four buckets:

```bash
perf stat --topdown -- ./target/release/app input.bin
perf stat -M TopdownL1 -- ./target/release/app input.bin   # older kernels
toplev -l2 -- ./target/release/app input.bin               # pmu-tools, level 2-3
```

| Bucket | Means | Act on |
|---|---|---|
| Retiring | slots do useful work | algorithm, fewer operations |
| Bad speculation | mispredicted branches | distribution, sort/partition, branchless only if both sides cheap |
| Frontend bound | instruction supply stalls | code size, I-cache, inlining, monomorphization |
| Backend bound | execution stalls; **memory** vs **core** | memory: layout/stride/TLB; core: dependency chains, `div`, ports |

Percentages are slots, not time, and sum to ~100 %. High Retiring can still
be wasted work. TMA needs PMU support; under virtualization it is often
unavailable — write `not available` instead of guessing.

## 3c. `perf diff`: before/after profiles

`perf diff` lines up two `perf.data` files by shared object and symbol and
prints each symbol's sample share in the baseline and the change.

```bash
perf record -e cycles:u -o before.data -- ./before/app input.bin
perf record -e cycles:u -o after.data  -- ./after/app  input.bin
perf diff before.data after.data              # Baseline %, Delta Abs
perf diff -c ratio before.data after.data     # share ratio instead of delta

# fork script: records both and runs perf diff
scripts/perf-diff.sh -- './before/app input.bin' './after/app input.bin'
```

Observed here (perf 7.3.1, `paranoid=2`; flat `cycles:u` sampling worked in
this session, call-graph recording did not, see §7) on two builds of one
xorshift loop:

```text
# Baseline  Delta Abs  Shared Object         Symbol
     0.16%     +0.31%  ld-linux-x86-64.so.2  [.] 0x000000000000ba6e
    99.66%     -0.28%  app                   [.] app::main
```

Traps, each seen in that session:

- **Shares, not time.** Both columns are percent of *each* profile. If the
  whole program got 2× faster, a function that is 99 % of both profiles shows
  a delta near zero. Take time from `perf stat`/hyperfine, not from here.
- **Matching is by DSO name and symbol name.** Two binaries named `work` and
  `work2` produced two unrelated rows (`work::main` only in the baseline,
  `work2::main` only in the new one) and no delta at all. Give both builds the
  same file name (separate directories) and the same crate name. A function
  that was inlined away, renamed, or turned into a different monomorphization
  also shows up as "disappeared + appeared", not as a delta.
- Few samples on a short run make small deltas noise; record long enough
  (thousands of samples on the symbol you care about) and repeat.

## 4. `samply` — sampling without kernel perf

```bash
samply record ./target/release/app input.bin
# opens a Firefox profile UI: flame graph, call tree, per-function self time
```

Use when `perf_event_paranoid` blocks hardware counters, in containers, or when
you want a call tree that is easier to read than `perf report`. It still needs
symbols; build with `debuginfo=1`.

`rustperf profile` wraps this for the declared benchmarks:

```bash
rustperf profile --tag <tag>
```

It runs criterion with `--profile-time 10` and samply's
`--unstable-presymbolicate`, prints top self-time symbols, and exits 0 if
samply is missing (printing the install command).

## 5. Flame graphs

```bash
perf record -F 999 -g -- ./app input.bin
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg
# or: cargo flamegraph --bin app -- input.bin   (needs perf + the crate)
```

Read: width = time share, depth = call depth. Look for wide plateaus in *your*
code; a wide `memcpy` or `malloc` plateau is an allocation problem, a wide
`__memmove_avx` is a copy problem. Flame graphs hide frequency of small
repeated calls unless you zoom; use `perf annotate` for the loop level.

## 5b. Differential flame graphs

A differential flame graph draws one profile's stacks and colours each frame
by how its sample count changed versus the other profile (in Brendan Gregg's
FlameGraph tools: red = grew, blue = shrank).

```bash
perf script -i before.data | stackcollapse-perf.pl > before.folded
perf script -i after.data  | stackcollapse-perf.pl > after.folded
difffolded.pl -n before.folded after.folded | flamegraph.pl > diff.svg
# the reverse view: drawn on the *before* shape
difffolded.pl -n after.folded before.folded | flamegraph.pl --negate > diff-rev.svg
```

Classic trap: the graph is **drawn on the stack shape of the second
profile**. A function that disappeared in the new version has no frame there,
so it is invisible however much time it used to cost. Always render the
reverse view too. `-n` normalizes the two profiles to the same total sample
count; without it, a longer recording looks like "everything grew".

Same limits as `perf diff`: colours are sample shares, renamed or inlined
frames do not match, and a red frame is a place to look, not a proven cause.
The recordings need stacks (`-g` or `--call-graph dwarf`); without them every
"stack" is one frame and the graph is just `perf diff` in colour. Here
call-graph recording is refused (§7) and FlameGraph scripts (and `inferno`)
are not installed, so the commands above are **not verified on this
machine**.

## 6. Contention and memory

```bash
perf c2c record -- ./app                 # cache-line contention (needs PMU)
perf c2c report --stdio
perf mem record -- ./app                 # memory access latency profile
perf mem report --stdio
numactl --hardware                       # NUMA topology, if relevant
```

Signs of false sharing: high HITM in `perf c2c`, IPC collapse as threads grow,
throughput that gets *worse* from 4→8 threads. Fix: `#[repr(align(64))]`
padding, per-thread accumulators, sharding. Verify on the real CPU; line size
and effect vary.

Two traps:

- HITM means a line modified in another cache was requested. It is a **signal
  to investigate**, not proof of false sharing: true sharing (one shared
  counter) looks similar. Prove it with offsets: different fields at different
  offsets of the same line, each written by its own thread. Then show HITM
  falling *and* wall time falling under a plain run without `perf`.
- `perf mem` reports sampled accesses with use-latency (queueing included),
  biased by `ldlat` and the sampling period. It is not "ns to DRAM". On AMD
  use IBS, on arm64 SPE where available; if the event is unsupported, write
  `unsupported`, never substitute generic cache-misses.

`perf c2c` and `perf mem` need PMU access; if `perf stat --topdown` or these
fail, fall back to wall-clock A/B plus layout analysis and say so.

## 7. When `perf` is unavailable

Try the rungs in order; "unavailable" is often only `perf record` with
hardware events.

1. **Counting still works?** `perf stat -e instructions:u,cycles:u -- ./app`
   needs no sampling. If it works, use instruction counts to detect and
   attribute changes (`scripts/instr-count.sh`, `measurement.md` §9) while
   wall-clock still decides.
2. **Flat sampling, then software events.** Drop the call graph first: on
   this machine (`paranoid=2`, perf 7.3.1) `perf record -e cycles:u -- ./app`
   and `-e task-clock:u` recorded samples, while **every** variant with `-g`
   or `--call-graph dwarf` failed with `Failure to open any events for
   recording`, and so did plain `-e cpu-clock` (`cpu-clock:u` worked). A flat
   profile plus `perf annotate` still localizes a hot loop; it cannot show
   callers.
3. `samply record` if installed (not installed on this machine).
4. `/usr/bin/time -v` for wall/RSS/context switches; `time` builtin for coarse
   numbers.
5. In-process batching with `Instant` around a whole batch (never per
   iteration), plus `black_box`.
6. `hyperfine` for end-to-end.
7. Allocation profiling: `heaptrack`, `dhat`, or a counting global allocator in
   a **bench-only** binary (never in the code under measurement).
8. Read the asm (`cargo asm`), LLVM remarks (§7b) and `llvm-mca` for static
   evidence.
9. State explicitly that results are not from the target machine if you had to
   use another one.

## 7b. LLVM optimization remarks: "why is this loop not vectorized?"

Before reading asm to find out whether a loop was vectorized, ask LLVM. The
vectorizer reports success, misses and the reason for a miss.

```bash
# single file
rustc -O --crate-type=lib --emit=obj -C debuginfo=1 -C remark=loop-vectorize vec.rs -o vec.o

# Cargo project (fork script; --filter keeps lines containing a substring)
scripts/vec-remarks.sh --bench select_active        # the bench in docs/rust_perf_case
scripts/vec-remarks.sh --lib --filter src/lib.rs
```

`--filter` matches the whole remark line (a file path), not a Rust function
name: LLVM's message carries no function name. A tiny non-generic `pub fn`
in a library may produce no remark in that library at all (it is inlined into
callers across crates); analyse the bin/bench that calls it or mark it
`#[inline(never)]` for the experiment.

Remarks appear only with `-C codegen-units=1` (checked: 2 and 16 print none,
and 16 is the release default). The script passes `1` itself, so the analysed
build can differ from your real profile: confirm the vectorization decision on
the real build with `cargo asm`. `cargo rustc` swallows the notes (the script
captures them through `RUSTC_WRAPPER`), and a cached build prints nothing.

Observed here (rustc 1.99.1) for `xs.iter().fold(0u32, wrapping_add)` and
`xs.iter().sum::<f64>()`:

```text
note: .../core/src/ops/arith.rs:104:45 loop-vectorize (analysis): loop not vectorized: cannot prove it is safe to reorder floating-point operations
note: .../core/src/slice/iter/macros.rs:279:24 loop-vectorize (missed): loop not vectorized
note: .../core/src/slice/iter/macros.rs:279:24 loop-vectorize (success): vectorized loop (vectorization width: 4, interleaved count: 2)
```

How to read it:

- `success` with width/interleave = vectorized; `missed` + `analysis` = not,
  and the analysis line says why (here: float reassociation, which is a
  semantic constraint, see `semantics-traps.md` §3 — not something to "fix"
  with a flag).
- **The location is often library code**, because iterator adaptors are
  inlined: both remarks above point into `core`, not into `vec.rs`. Isolate
  one function per file or example so you know which loop is meant.
- `debuginfo` is needed for locations; without it remarks lose file:line.
- A vectorized loop can still be slow (gathers, a scalar remainder for short
  slices, a runtime alias check that fails) and a scalar loop can be fast.
  Remarks say what the compiler did, not what it costs; confirm with
  `cargo asm` and a benchmark.
- `-C remark=all` is very noisy; ask for the pass you need.

## 8. Allocation profiling

Rust gives no allocation counts by default, and criterion measures time only.

```bash
heaptrack ./target/release/app input.bin      # totals, peaks, call sites
# or a counting allocator in a test/bench binary:
#   #[global_allocator] static A: Counting = Counting;
```

Report three numbers separately: **count**, **total bytes**, **peak bytes**.
"Zero allocations in the hot loop" can still mean an expensive allocation per
request just outside it. `format!`, `to_string`, `collect`, `clone` on `String`
and `Arc::clone` (refcount only) behave very differently — measure, do not
assume.

## 9. Binary size and compile time

```bash
cargo bloat --release -n 30          # biggest symbols (needs cargo-bloat)
cargo llvm-lines -p crate            # monomorphization hot spots
cargo build --timings               # per-crate build units → target/cargo-timings
size target/release/app
```

Size wins usually come from: less monomorphization, `dyn` at the right
boundary, `opt-level="s"`/`z` for non-hot crates, stripping, `panic=abort`
(behavior change: no unwinding), and not `#[inline(always)]` everywhere.

## 10. Async servers: latency is not CPU time

`perf` shows on-CPU work. A slow async service is often *off-CPU*: queued,
waiting on a lock, blocked in a syscall, or starved by a long task.

```bash
tokio-console                       # task states, busy/wait, long poll times
# Cargo.toml: tokio = { features = ["tracing", "rt"] }, console-subscriber
# main: console_subscriber::init();
```

Symptoms and fixes:

| Symptom | Cause | Fix |
|---|---|---|
| one task polls for milliseconds | CPU-bound work on a worker | `spawn_blocking`, move to a pool |
| many tasks "idle" but requests slow | queue wait, not execution | bounded queue, more workers, backpressure |
| p99 spikes with flat CPU | coordinated omission in the load generator, GC-like pauses, lock handoff | open-loop load test, `tokio-console`, lock tracing |
| latency grows with load | unbounded queue absorbing requests | bounded channels + 503/timeout policy |
| tail worse after batching | each request waits for the batch | tune batch size against p99, not throughput |

**Coordinated omission**: a closed-loop load generator (send, wait, send) hides
the queueing delay it creates. Use open-loop/constant-rate load (e.g.
`oha -q`, `wrk2`, or a custom rate limiter) before believing a p99 number.

Memory in async: each spawned task holds a future; millions of unbounded tasks
cost memory even when they do nothing. Count tasks and bytes, not just CPU.

---


## 11. Profile hygiene checklist

- [ ] Release build, same flags on both sides.
- [ ] Realistic input; not one tiny fixture.
- [ ] Idle machine, AC power, `uptime` checked.
- [ ] Warmup run discarded.
- [ ] Symbols resolved (`debuginfo=1`, frame pointers).
- [ ] Top symbol identified and classified (CPU/mem/branch/lock/IO).
- [ ] At least one hypothesis tied to a specific instruction or line.
- [ ] Numbers recorded with the command that produced them.
