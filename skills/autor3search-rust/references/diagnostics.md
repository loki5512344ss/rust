# Diagnostics: symptom → instrument → likely cause

Start from the symptom the user gave you, not from a favorite optimization.

## 1. Triage tree for "it got slower"

```text
Slower?
├─ Wrong result or changed contract?        -> revert, fix the test first
├─ Different flags/build/input?             -> fix the experiment, then re-measure
├─ Difference within noise?                 -> unknown, raise count, re-run
├─ Allocations / RSS up?                    -> clones, buffers, layout
├─ Cache misses up?                         -> memory layout, stride, pointer chasing
├─ Branch misses up?                        -> distribution, match order, dispatch
├─ Instructions / CPU time up?              -> redundant work, divisions, sorts
├─ Sys time up?                             -> syscalls, locks, I/O, page faults
└─ No explanation?                          -> deeper profile; do not guess
```

## 2. Symptom table

| Symptom | Read first | First testable hypothesis | Confirm with |
|---|---|---|---|
| Large event log slow | asm-reading §5, profiling | `Event` enum stride; branch distribution | `size_of`, cache/branch counters |
| Moving `Tick` to the top made it worse | semantics-traps §2 | enum/block layout changed | `perf annotate`, asm diff, replay |
| Regression after `#[inline(always)]` | asm-reading §5 | code bloat / I-cache pressure | `size`, `nm`, perf, binary diff |
| Index loop "too slow" | asm-reading §6 | bounds check or bad memory pattern | LLVM IR + `perf annotate` |
| `clone()` per request | measurement §8, profiling §8 | data copied that is never used | allocation profile + bench |
| Many `String`s in events | asm-reading §5 | payload size, allocator, cache | `size_of`, allocs, RSS |
| Simple program, high p99 | profiling §6, measurement | queue/lock/I/O/cold path | latency trace, `perf c2c` |
| 24 threads not faster than 12 | profiling §6 | SMT, bandwidth, contention | scaling 1/2/4/8/12/24 |
| SIMD does not help | asm-reading §8 | memory-bound, tail, dispatch | counters + asm + size sweep |
| Compiler "ignores" the loop | asm-reading §3 | dependency, aliasing, unknown bounds | MIR/LLVM IR + minimal repro |
| Weird AI-suggested hack | semantics-traps | contract broken or measurement invented | tests, safety review, ABBA |
| Binary too large | profiling §9 | inlining, monomorphization | `cargo bloat`, symbols |
| CPU nearly idle | profiling §2 | bottleneck outside CPU | syscall/I/O/network profiling |
| Startup time dominates | measurement §2 | dynamic linking, lazy init | `hyperfine`, `LD_DEBUG=statistics` |
| Memory grows over time | profiling §8 | leak, cache without eviction, unbounded queue | `heaptrack`, RSS over time |
| First request slow, rest fine | measurement §7 | cold caches, lazy init, JIT-like effects | warmup comparison |

## 3. Cheap hypotheses to try in order (when there is no time for depth)

1. **Remove work**: is a result computed and discarded? Is a loop scanning data
   twice? Is `collect()` used only to `.iter()` again?
2. **Allocation**: `format!`/`to_string`/`Vec::new` in the hot path; `clone()`
   of a `String` that could be `&str`.
3. **Container choice**: `HashMap` where a sorted `Vec` + binary search or a
   dense index would do; `Vec::contains` where a `HashSet` is warranted.
4. **Bounds checks**: indexing loop → iterator or `chunks_exact`.
5. **Hasher**: SipHash on integer keys in a hot map → faster hasher (only if
   input is not attacker-controlled).
6. **I/O**: unbuffered writes, one `write` per record, missing
   `BufReader`/`BufWriter`.

Each still needs a measurement. "Obvious" wins are frequently 0 %.

## 4. The five questions before every experiment

1. What is hot, and what is the evidence (symbol, %, counters)?
2. What exactly will disappear: an allocation, a copy, a load, a branch, a
   syscall, a hash computation?
3. What should change in MIR / LLVM IR / asm if the hypothesis is right?
4. On which inputs could this lose (small N, ties, UTF-8, overflow, skewed
   distribution)?
5. What measurement would make me revert?

If you cannot answer (2) and (5), you are not ready to patch.

## 5. Amdahl sanity check

```
S_total = 1 / ((1 - p) + p / s)
```

A part that is 50 % of runtime and becomes 10× faster yields ≈1.82× overall.
If your benchmark claims 5× on a function that is 10 % of the process, the
end-to-end win is ≈1.05× — and if the benchmark says 5× but the process does
not move, the benchmark is not measuring the process.

Roofline for array work:

```
arithmetic intensity I = useful ops / bytes moved
performance <= min(peak compute, bandwidth * I)
```

Once bandwidth-bound, faster arithmetic buys nothing. Once compute-bound on a
dependent chain, more bandwidth buys nothing.

## 6. When the answer is "no change"

Write it down. `no_significant_improvement` is a real result: it rules out a
hypothesis and narrows the next one. Repeated honest discards are progress.
Inventing a story to justify a patch is how regressions ship.
