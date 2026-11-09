# Profiling: finding the 5 % that owns 80 % of the time

## 1. Before you profile

```bash
rustc -Vv
cat /proc/sys/kernel/perf_event_paranoid   # 2 = user-space only; 1/0 adds kernel symbols
perf --version
uptime                                      # is anything else running?
```

Build with symbols but unchanged optimization:

```bash
RUSTFLAGS='-C debuginfo=1 -C force-frame-pointers=yes' cargo build --release
```

`debuginfo=1` keeps release codegen; `force-frame-pointers` makes stacks
walkable in `perf`. If `perf` says `not permitted`, do **not** casually lower
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

## 4. `samply` — sampling without kernel perf

```bash
samply record ./target/release/app input.bin
# opens a Firefox profile UI: flame graph, call tree, per-function self time
```

Use when `perf_event_paranoid` blocks hardware counters, in containers, or when
you want a call tree that is easier to read than `perf report`. It still needs
symbols; build with `debuginfo=1`.

`autor3search-rust profile` wraps this for the declared benchmarks:

```bash
autor3search-rust profile --tag <tag>
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

## 7. When `perf` is unavailable

1. `/usr/bin/time -v` for wall/RSS/context switches; `time` builtin for coarse
   numbers.
2. In-process batching with `Instant` around a whole batch (never per
   iteration), plus `black_box`.
3. `hyperfine` for end-to-end.
4. Allocation profiling: `heaptrack`, `dhat`, or a counting global allocator in
   a **bench-only** binary (never in the code under measurement).
5. Read the asm (`cargo asm`) and `llvm-mca` for static evidence.
6. State explicitly that results are not from the target machine if you had to
   use another one.

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
