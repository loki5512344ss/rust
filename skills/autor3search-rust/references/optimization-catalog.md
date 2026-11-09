# Optimization catalog (363 techniques, with kill conditions)

Use this as a lookup, not a checklist. Every row is a **candidate**: it pays
only when the profile points at the operation it removes.

**Priority:** `P` = check early, usually high leverage; `M` = depends on
profile/data/size; `E` = expert, risky (unsafe, precision, ISA, contract).

**Order of attack** — do not jump down this list:

1. Algorithmic: less work, better complexity (`a*`).
2. Allocations and copies (`h*`, `s*`).
3. Containers and hashing (`c*`).
4. Data layout, cache, locality (`d*`).
5. Loops, bounds checks, branches (`l*`).
6. SIMD (`v*`), dispatch/inlining (`g*`), arithmetic (`n*`).
7. Build flags, PGO, allocator (`b*`, `t*`) — human decisions.

**Before applying any row:** read `semantics-traps.md`. A row whose "Check /
when it hurts" says `contract` changes observable behavior and needs explicit
permission plus a differential test.

**Before believing any row:** read `measurement.md`. Most "obvious" wins on a
tiny input measure 0 %.

**MSRV watch** (guide is stable-Rust oriented; these are newer than many
crates' MSRV — check the project's `rust-version` first):

| API | Stabilized |
|---|---|
| `slice::first_chunk` / `last_chunk` / `split_first_chunk` | 1.77 |
| `slice::as_chunks` / `as_chunks_mut` / `as_chunks_unchecked` | 1.88 |
| `slice::as_array` / `as_mut_array` | 1.93 |

`chunks_exact` (1.31) and `array_chunks` are the portable fallbacks.

---

## Quick router

| The profile says | Start with |
|---|---|
| allocator/memcpy at the top | `h01`, `h03`, `h06`, `h08`, `h23`, `s09` |
| `idiv`, high instruction count | `n03`, `n08`, `a01` |
| high cache misses, IPC < 1 | `d01`, `d02`, `d06`, `d11`, `c05`, `h21` |
| high branch misses | `a18`, `l11`, `l12`, `g07`, `g03` |
| bounds-check panic path in asm | `l01`, `l03`, `l16` |
| `lock` prefix / contention | `p05`, `p06`, `p07`, `p09`, `p18` |
| syscalls dominate | `i01`, `i02`, `i07`, `i10` |
| no vector instructions in a numeric loop | `l15`, `v01`, `v02`, `v03`, `v10` |
| many small tasks, wakeups | `x02`, `x05`, `x13` |
| big binary / slow build | `t01`–`t15`, `g02`, `g06` |

**Two entries can both be right.** `entry` hashes once and always allocates;
`get_mut` + `insert` hashes twice on a miss but allocates only when the key is
new. The first wins on tiny inputs, the second on allocation-bound ones — the
small-N sweep decides (measured example: `examples.md` §8).

---

## Build, Cargo, profiles, PGO

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `b01-release-build` | Release build for every measurement | P | any runtime measurement; the single highest-leverage first step. | cargo test without a profile runs much less optimized code, so numbers from it are meaningless for perf claims. Clippy -D warnings is strictness, not speed. |
| `b02-opt-level-2-vs-3` | opt-level 2 vs 3 | M | CPU-bound code, latency-sensitive or large binaries where code size/I-cache matters. | 3 can lose to 2 through code size and instruction-cache pressure; never assume higher is faster. |
| `b03-lto-thin` | Thin LTO | M | small/medium services and libraries with hot cross-crate call sites. | link time grows; runtime win is not guaranteed, and can regress. |
| `b04-lto-fat` | Fat LTO | M | final production artifact where link time is acceptable. | very expensive linking; still no guaranteed win; do not use during iteration. |
| `b05-codegen-units-1` | codegen-units = 1 | M | deeper optimization of hot code paths. | kills LLVM parallelism; compile time can grow substantially. |
| `b06-panic-abort` | panic = abort | M | binary size and unwind cost, when the process may legally die on panic. | contract — panics terminate the process immediately, no normal stack unwinding, no catch/catch_unwind, no destructor-based cleanup guarantees; do not enable if panics… |
| `b07-target-cpu-native` | target-cpu=native | M | the binary runs on exactly the CPU it was built on. | binary may fault/not run on older CPUs; choose native for the *runtime* machine, not the CI builder. Restore portability with cargo clean + plain rebuild. |
| `b08-target-feature-avx2` | Explicit target-feature flags | E | fixed-fleet deployment with verified ISA. | E, contract — violating CPU requirements can make the program non-functional; wrong configuration can also produce incorrect code. |
| `b09-pgo-profile-generate-use` | PGO | M | stable, typical workloads where branch frequency and block layout matter. | a bad/unrepresentative profile makes other inputs slower; never reuse a profile from another program or binary version. |
| `b10-bolt-cargo-pgo` | BOLT / cargo-pgo | M | large production binaries with hot/cold code spread across the address space. | platform/toolchain-specific, needs separate measurement; can regress if profiles are stale. |
| `b11-alternative-allocator` | Alternative allocator | M | allocation-heavy multithreaded services. | external dependency; memory footprint and tail latency can change in either direction. Only after DHAT/heaptrack proves allocator time. |
| `b12-fast-linker` | Fast linker | M | long link steps in CI. | mostly build-time, not runtime; OS/toolchain support varies. |
| `b13-strip` | strip symbols/debuginfo | M | distribution size. | less diagnostic info; runtime effect is optional/incidental. |
| `b14-debug-line-tables-only` | line-tables-only debug info while profiling | P | any sampling profile of a release build. | adds debug-section size only; not a runtime optimization. |
| `b15-opt-level-s-z` | opt-level "s"/"z" | M | binary size focus. | often slower; z can disable vectorization; does not guarantee the smallest file. |
| `b16-dev-vs-release-profiles` | Separate dev and release profiles | M | developer throughput without polluting production settings. | never carry dev-profile timings over to release. |
| `b17-trim-features` | Disable unneeded dependency features | M | binary size, startup, compile time, supply chain. | may remove functionality; requires regression tests. |
| `b18-cargo-check` | cargo check during iteration | M | faster compiler feedback on large projects. | produces no executable; does not replace runtime tests. |
| `b19-incremental-dev` | incremental = true for development | M | repeated rebuilds. | extra artifacts; can degrade optimization quality and even build speed on some workloads. Keep it off for release. |
| `b20-profile-the-build` | Profile build time and memory itself | E | very large crates where build cost dominates engineering time. | runtime/size/compile-time trade-off; less monomorphization can cost runtime. |
| `b37-01-cargo-tuning` | Cargo tuning without magic flags | M | late-stage build tuning after algorithmic work. | codegen-units = 1 can substantially increase compile time; panic = "abort" is a behavior change, not just size; do not enable everything for a single benchmark. |
| `b37-02-target-cpu` | target-cpu and portability | M | known deployment CPU. | CI/server CPU may differ from the user's Xeon; pick native by the machine that *runs* the binary. |
| `b37-03-pgo-workflow` | PGO workflow | M | branch-frequency-driven layout and inlining. | profile must reflect the real event mix and input sizes or the optimizer improves the wrong branch; clean old .profraw between experiments; verify LLVM/toolchain paths… |
| `b37-04-inline-code-growth` | Code growth from profile-guided inlining | M | after #[inline(always)] or PGO shows a regression. | #[inline(never)] on a large cold handler can shrink the hot footprint; attributes are not an on/off speed switch. |
| `b37-05-library-boundaries` | Function-level optimization and library boundaries | M | small helpers on hot paths. | #[inline(always)] on a public generic can bloat badly; if the API needs dynamic types, measure vcalls and hoist dispatch out of the loop. |
| `b37-06-branch-layout` | Branch frequency math and layout | M | skewed event distributions. | manually reordering match arms blind is less reliable than feeding a representative PGO profile; PGO reorders blocks and inlines by observed frequency. |
| `b37-07-repr-rust-stability` | Rust type layout stability | M | serialization, FFI, on-disk formats, size-driven layout work. | #[repr(align(...))] raises alignment and can grow size_of, especially in arrays; public C ABI needs repr(C) plus a compatibility check. |
| `b37-08-const-fn-static-tables` | const fn and static tables — where they actually help | M | small fixed domains with hot lookups. | cost moves into memory footprint, data loading, D-cache; for small formulas computing on the fly beats a random memory load; const arrays affect ELF section placement… |
| `b37-09-hasher-security` | Alternative hasher without silently dropping safety | M | trusted, controlled key domains. | contract — if an attacker chooses keys, a fast hasher enables hash-flooding DoS; iteration order may change. |
| `b37-10-unsafe-last-resort` | unsafe and manual intrinsics as the last floor | E | proven hotspots only. | every unsafe needs a SAFETY: comment with exact invariants and reproducible tests; if invariants are hard to prove, do not ship the patch. |

## Binary size & compile time

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `t01-opt-level-size` | opt-level s/z for size | M | shrink distributions. | runtime often worse; not guaranteed minimal. |
| `t02-strip-post-build` | strip after build | M | smaller distributable. | loses symbols/traceability. |
| `t03-panic-abort-size` | panic=abort for size | M | removes unwind machinery. | different panic strategy — semantics change, not just bytes. |
| `t04-lto-size` | LTO for size | M | duplicate generic instantiations across crates. | link time; sometimes runtime regressions. |
| `t05-remove-deps` | Remove unused features/deps | M | size, compile time, supply chain. | verify functionality carefully. |
| `t06-fewer-derives` | Fewer heavy derives/proc macros | M | compile time. | more hand-written code; risk of missing impls. |
| `t07-nongeneric-extraction` | Move non-generic logic out of generic fns | M | reduced monomorphization and IR volume. | the call may no longer inline; check hot paths. |
| `t08-no-huge-const-macros` | Avoid huge const/static generated per crate | M | compiler memory/time. | API and startup behavior may change. |
| `t09-cargo-check-editing` | cargo check while editing | M | feedback loop. | no runtime validation. |
| `t10-fast-linker` | faster linker | M | slow links. | platform/toolchain support. |
| `t11-workspace-decomposition` | Sensible workspace decomposition | M | large workspaces. | too many crates adds overhead and blocks cross-crate inlining. |
| `t12-limit-const-generics` | Limit const-generic instantiations | M | binary size and LLVM IR volume. | giving up specialization can reduce speed. |
| `t13-llvm-lines-bloat` | Diagnose with cargo llvm-lines / cargo bloat | M | targeting size/compile-time work. | these are pointers, not goals; a big function is not automatically hot. |
| `t14-codegen-units-ci` | Tune codegen-units for CI | M | balancing CI time vs shipped speed. | 1 is not universally better. |
| `t15-pgo-production` | PGO in production build | M | layout matched to real traffic. | two-phase build; profile drift. |

## Measurement & profiling

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `m01-perf-record` | perf record / report / flamegraph | P | first look at any unknown hotspot. | sampling + missing symbols mislead; needs debug = "line-tables-only" and frame pointers. |
| `m02-perf-stat` | perf stat counters | P | deciding memory-bound vs branch-bound vs ALU-bound. | more instructions does not automatically mean slower; counter sets are CPU-specific. |
| `m03-alloc-profilers` | DHAT / heaptrack / Massif | M | suspected allocation churn or RSS blowups. | instrumentation overhead changes timing; use counts, not wall time, from these. |
| `m04-cachegrind` | Cachegrind / Callgrind | M | when hardware counters are unavailable. | cache model is approximate; confirm on real hardware. |
| `m05-flamegraph-tools` | cargo flamegraph / samply | M | quick visualization of hot trees. | needs symbols; sampling bias on short runs. |
| `m06-criterion` | Criterion.rs | M | comparing two implementations of a small function. | never conclude from a single number; microbenchmarks may not reflect the real call pattern. |
| `m07-hyperfine` | hyperfine | M | end-to-end CLI timing. | includes startup, page cache, shell overhead; not for micro-hotspots. |
| `m08-black-box` | std::hint::black_box | P | every microbenchmark of a pure function. | not an absolute guarantee, and it does not replace checking the result is correct. |
| `m09-warmup-repeats` | Warmup and many repetitions | P | stability of any timing. | account for turbo, frequency scaling, scheduler, page faults; first-call latency is a separate metric. |
| `m10-size-sweep` | Multiple data sizes and distributions | P | finding the crossover where a technique starts paying. | small n can invert the result; a win at 10⁶ may be a loss at 10. |
| `m11-abba` | ABBA interleaved ordering | M | any comparison on a noisy machine. | blocks must be independent; report raw times. |
| `m12-taskset` | CPU pinning and fixed load | M | reducing measurement noise. | pinning itself can change scheduling/cache behavior; do not pin when testing scaling. |
| `m13-cargo-asm` | cargo asm / objdump | M | explaining *why* a change helped. | ASM explains mechanism but does not replace timing. |
| `m14-cargo-bloat` | cargo bloat / llvm-size / size | M | size regressions after inlining/monomorphization. | separate debug symbols from executable code. |
| `m15-cargo-llvm-lines` | cargo llvm-lines | M | compile time and code size. | IR volume is not runtime cost. |
| `m16-real-input` | Profile on real input | P | avoiding optimizing a synthetic benchmark. | synthetic and real loads diverge; keep a held-out set. |
| `m17-equivalence-first` | Equivalence checks before benchmarks | P | every optimization. | semantic regressions are worse than milliseconds. |
| `m18-tail-metrics` | p95/p99, RSS, alloc/s, CPU% monitoring | M | servers and latency-sensitive code. | average hides tails; throughput gains can worsen p99. |

## Algorithms / less work

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `a01-better-complexity` | Replace O(n²) with O(n log n)/O(n) | P | growing n, repeated searches. | at tiny n the constants can dominate; always measure the crossover. |
| `a02-no-repeated-passes` | Remove repeated full passes | P | counting, search, aggregation. | a second pass may be required after mutation for correctness. |
| `a03-loop-invariant-hoist` | Hoist loop invariants | P | loops with constant transforms. | LLVM often does this already — check ASM first. |
| `a04-lazy-compute` | Lazy / on-demand computation | P | rare branches, optional outputs. | caching/laziness can increase first-request latency. |
| `a05-memoization` | Memoize pure functions | M | repeated keys in a hot function. | extra memory, hashing cost, invalidation complexity. |
| `a06-precomputed-tables` | Precomputed tables | M | small fixed domains. | memory traffic can exceed computation cost; large tables hurt D-cache. |
| `a07-prefix-fenwick` | Prefix sums / difference arrays / Fenwick | M | repeated range aggregation. | prep/update cost; Fenwick only for point-update+range-query shapes. |
| `a08-sliding-window` | Sliding window | M | moving averages/sums. | overflow and element-expiry correctness. |
| `a09-two-pointer` | Two-pointer merge over sorted data | M | sorted inputs. | requires a sortedness contract. |
| `a10-hash-index` | Hash index instead of repeated linear search | M | many queries over the same collection. | for small sets, Vec linear search is faster and more compact. |
| `a11-sorted-vec-binary-search` | Sorted Vec + binary_search | M | rare inserts, many searches. | mid-insertion is O(n). |
| `a12-small-n-fast-path` | Special-case 0/1/2 elements | M | frequently seen small inputs. | adds branches and code; must stay semantically identical. |
| `a13-select-nth` | select_nth_unstable instead of full sort | M | only one order statistic is needed. | contract — reorders elements including equal ones; even-length median (pair of middles) is a different problem. |
| `a14-binaryheap-topk` | BinaryHeap for top-k | M | small k over a large stream. | for large k a full sort may win. |
| `a15-skip-known-work` | Skip work already known/filtered out | M | high discard rates. | the predicate must be semantically valid; no dropped side effects. |
| `a16-batching` | Batch/packet processing | M | many small operations. | extra memory and latency until the batch fills. |
| `a17-loop-fusion` | Reduce passes via fusion | M | large data, memory-bandwidth-bound. | fusion can block SIMD or parallelism. |
| `a18-fast-path` | Fast path for the most frequent variant | M | skewed distributions. | production frequencies change; keep a slow path for everything else. |
| `a19-incremental-update` | Monotonic / incremental updates | M | many small state changes. | needs invariants and correct invalidation. |
| `a20-less-serialization` | Cut serialization in the pipeline | M | pipelines and network services. | buffer ownership and lifetime questions appear. |
| `a21-dont-compute-discarded` | Don't compute what gets discarded | M | early-exit searches. | side-effect order/count must be preserved. |
| `a22-approximate` | Approximate algorithms / probabilistic structures | E | error/false-positive budget is acceptable. | E, contract — changes the mathematical contract; must state the error bound. |

## Allocations & ownership

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `h01-with-capacity` | with_capacity | P | known/estimable output size with many pushes. | over-reserving raises RSS; with_capacity does not set len. |
| `h02-reserve` | reserve / reserve_exact | M | incremental filling. | reserve_exact does not always save and may reallocate more often. |
| `h03-vec-clear-reuse` | clear() instead of new Vec | P | repeated batch processing. | clear runs Drop on elements and keeps memory; a long-lived buffer must not leak state between requests. |
| `h04-string-capacity-clear` | String with_capacity / clear | P | assembling many strings. | don't turn one short request into a permanently huge buffer. |
| `h05-out-param-vec` | Pass &mut Vec instead of returning a new one | P | hot producer functions. | contract — changes API and clear/append semantics. |
| `h06-str-borrow` | &str instead of String for reads | P | parsing/analysis without ownership. | borrows cannot outlive the source buffer. |
| `h07-slice-borrow` | &[T] instead of copying Vec<T> | P | analytics/parsing. | must guarantee the slice lifetime. |
| `h08-remove-clones` | Remove needless clone/to_owned/to_string | P | per-request copies. | sometimes a copy is required to release a lock or drop a borrow. |
| `h09-clone-from` | clone_from for an existing destination | M | repeated overwrites of the same target. | not every type reuses meaningfully. |
| `h10-cow` | Cow<str> / Cow<[T]> | M | mostly-borrowed pipelines. | to_mut() can copy unexpectedly on the first mutation. |
| `h11-box-slice` | Box<[T]> for immutable sequences | M | immutable collections where capacity is dead weight. | conversion may reallocate; no push. |
| `h12-smallvec` | SmallVec | M | very many short-lived vectors. | bigger inline object, heap/inline branch on every op, expensive moves; not a guaranteed win. |
| `h13-arrayvec` | ArrayVec | M | strict maximum size known. | overflow must be handled; size is fixed even when empty. |
| `h14-array-plus-len` | Small array + length counter | M | small fixed buffers. | manual init/length logic; only initialized elements may be read. |
| `h15-arena` | Arena / bump allocation | M | per-request/per-pass object graphs. | destructors, memory held until arena drop, cross-epoch references. |
| `h16-object-pool` | Object pool / freelist | M | frequent create/destroy of the same shape. | retains memory, complicates concurrency and cleanup. |
| `h17-vec-append` | Vec::append vs extend(drain) | M | transferring whole vectors. | source is emptied; order is preserved. |
| `h18-extend-from-slice` | extend_from_slice | M | appending slices. | for Clone elements the clone semantics apply. |
| `h19-mem-take-replace` | mem::take / mem::replace | M | swapping buffers/state. | the value left behind must be valid/sensible. |
| `h20-flat-vec-offsets` | Flat Vec<T> + offsets instead of Vec<Vec<T>> | M | many small arrays. | harder addressing; updates and ownership. |
| `h21-vec-of-values` | Vec<T> instead of many Box<T> | M | locality + fewer allocations. | moves invalidate addresses/indices; stable addresses need another design. |
| `h22-shorten-big-lifetimes` | Shorten the lifetime of big objects | M | RSS and long-lived slices. | sometimes an intentional small copy beats holding a gigabyte. |
| `h23-hoist-allocations` | Move allocations out of the processing loop | M | packet parsing, temp buffers. | buffers must be cleared and must not leak between requests. |
| `h24-ownership-choice` | Compare Box/Rc/Arc vs by-value | M | shared data, enum size. | Arc uses atomic refcounts; Rc is not Send/Sync. |
| `h25-arc-clone-hot` | Reduce Arc::clone frequency | M | very frequent Arc clones. | holding a borrow longer can complicate logical ownership. |
| `h26-borrowed-map-keys` | No allocation for temporary map keys | M | string-keyed lookups with borrowed input. | key must implement compatible Borrow/Hash/Eq. |
| `h27-retain-dedup` | retain / retain_mut / dedup instead of a second container | M | large removals. | destructive; dedup only removes adjacent duplicates. |
| `h28-shrink-to-fit` | shrink_to_fit for shrunk long-lived containers | M | long-lived containers that shrank a lot. | may allocate/copy; never in a hot loop. |
| `h29-size-of-audit` | Check size_of of frequent enums/structs | M | large arrays of structs / enum payloads. | smaller size does not automatically cut latency. |
| `h30-arena-graph` | Arena/index graph instead of Rc<RefCell<T>> | E | linked nodes, ASTs, ECS. | E — index invalidation and new invariants. |

## Containers & hashing

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `c01-vec` | Vec<T> for sequences | P | locality, compactness, iteration. | expensive mid-insert/remove. |
| `c02-vecdeque` | VecDeque instead of Vec::remove(0) | M | queues with frequent head/tail ops. | not always contiguous; higher iteration overhead. |
| `c03-binaryheap` | BinaryHeap | M | schedulers, streaming top-k. | no sorted sequential traversal. |
| `c04-hashmap` | HashMap | M | many non-sequential lookups. | allocation, hashing cost, iteration order is unspecified. |
| `c05-btreemap` | BTreeMap | M | sorted iteration and ranges. | often overkill for small sets; node-based, less cache-friendly. |
| `c06-sorted-vec-pairs` | Sorted Vec<(K,V)> | M | many reads, rare updates, compact data. | insert/remove shift the tail. |
| `c07-linear-search` | Vec + linear search | M | very few elements. | O(n) per lookup. |
| `c08-hashset-vs-vec` | HashSet vs Vec membership | M | many membership checks. | on small sets linear scan can be faster. |
| `c09-bitset` | Bitset for a bounded small non-negative ID domain | M | dense domain, set intersection. | size is proportional to the *range*, not the element count. |
| `c10-vec-bool` | Vec<bool> | M | memory and sequential scans. | **Rust does not bit-pack `Vec<bool>`**: it is 1 byte per element, same as `Vec<u8>` (verified: `size_of::<bool>() == 1`). The "bit proxy" caveat applies to C++ and to the `bitvec` crate, not std. If you need bit packing, use `bitvec`/`mybitvec` or an explicit mask |
| `c11-vec-u8-flags` | Vec<u8> instead of Vec<bool> | M | frequent per-element read/write. | **not a memory win in Rust** — `Vec<bool>` is already 1 byte/element. Use `u8` for arithmetic/FFI clarity only; use `bitvec` when memory actually matters. |
| `c12-array-by-key` | [V; N] for a small fixed key domain | M | dense small key space. | O(N) memory; index must be validated. |
| `c13-entry-api` | HashMap::entry / or_insert | M | repeated access to the same key. | use or_insert_with when value construction is expensive/lazy. |
| `c14-map-with-capacity` | HashMap/HashSet::with_capacity | M | many known-size inserts. | wasted memory; capacity ≠ length. |
| `c15-fast-hasher` | Alternative hasher | M | trusted, controlled key domains. | contract — loses hash-flooding protection, changes iteration order and reproducibility; external dependency. |
| `c16-intern-keys` | Precompute key → integer ID | M | repeated access by string key. | needs a consistent mapping table and lifetime management. |
| `c17-swap-remove` | swap_remove | M | unordered sets. | contract — **changes order**; for queues/time series this is not equivalent. |
| `c18-retain` | retain instead of remove-in-loop | M | removing many elements. | preserves relative order; shifts still occur. |
| `c19-dedup` | dedup after sort | M | post-sort uniqueness. | without sorting only consecutive duplicates go. |
| `c20-sort-unstable` | sort_unstable | M | equal-element stability is irrelevant. | contract — **reorders equivalent keys**; not always faster. |
| `c21-sort-by-key` | sort_unstable_by_key vs sort_by_cached_key | M | expensive key computation. | sort_by_cached_key allocates; the key must not change during the sort. |
| `c22-select-nth` | select_nth_unstable instead of full sort | M | medians, partial selection. | destructively reorders the collection. |
| `c23-partition-point` | partition_point / binary_search | M | already-sorted data. | predicate must define a monotone split. |
| `c24-btreemap-range` | BTreeMap::range | M | range queries on ordered keys. | requires total order and correct range logic. |
| `c25-split-drain-splice` | split_off / drain / splice | M | batch removal/moves. | may move many elements or allocate. |
| `c26-hashmap-retain` | HashMap::retain | M | pruning many entries. | cost depends on table size, not live entries. |
| `c27-linkedlist` | LinkedList only when node properties are truly needed | M | rare structural-splicing workloads. | node allocations and terrible locality almost always lose for ordinary tasks. |
| `c28-specialized-hash` | Specialized hash tables | E | very specific key profiles. | E — security/API/comparability; must be compared against std, not assumed better. |
| `c29-arena-graph` | ID/arena graph instead of many heap nodes | M | graph/AST/ECS traversal. | stable indices required; references stored separately. |
| `c30-dense-sparse` | Dense vs sparse matrix | M | mostly-zero data. | the threshold depends on density, access and operations. |

## Strings, UTF-8, parsing

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `s01-take-str` | Take &str when ownership is not required | P | functions that read text. | cannot store beyond the owner's lifetime. |
| `s02-bytes-slice` | &[u8] for binary protocols | P | binary/network messages. | do not pretend binary data is UTF-8. |
| `s03-split-once` | split_once / split_whitespace / lines without intermediate Strings | P | small-format parsing. | delimiter, Unicode-whitespace and CRLF semantics differ between these methods. |
| `s04-no-split-collect` | Avoid split(...).collect() when only one field is needed | P | tokenizing. | if you traverse tokens several times, materializing may win. |
| `s05-find-contains` | str::find / contains instead of a manual char loop | M | delimiter search. | match kind must be the same (byte vs char vs substring). |
| `s06-byte-search` | Byte search over as_bytes() | M | ASCII protocols. | as_bytes is safe, but any slice you later take from the str must land on UTF-8 boundaries. |
| `s07-memchr` | memchr / memmem | M | lots of byte/substring searching. | binary semantics; library version behavior. |
| `s08-write-instead-of-format` | push_str / push / write! instead of repeated format! | P | text building in loops. | count allocations; write! formatting is not free. |
| `s09-string-capacity` | String::with_capacity | P | roughly known result length. | over-capacity retains memory. |
| `s10-string-clear` | Reuse String::clear() | P | line-oriented processing. | old-content borrows must be gone. |
| `s11-parse-slice` | str::parse::<u64>() without an intermediate String | M | number parsing. | preserve error, sign and overflow behavior. |
| `s12-ascii-decimal-parser` | Specialized ASCII decimal parser | M | fixed, known format. | contract — handle +, minus, spaces, leading zeros, overflow, empty input; must match the previous parser exactly. |
| `s13-fmt-write-string` | std::fmt::Write into an existing String | M | repeated formatting. | not std::io::Write; handle fmt::Result to keep the old signature. |
| `s14-io-write-vec` | std::io::Write into Vec<u8> | M | packet assembly. | write errors must still be handled even through the generic interface. |
| `s15-ascii-lowercase` | Avoid to_lowercase() where ASCII case is enough | M | HTTP-like ASCII identifiers. | contract — Unicode case folding differs from ASCII and can change length. |
| `s16-eq-ignore-ascii-case` | eq_ignore_ascii_case instead of Unicode normalization | M | contract is **ASCII only**. | contract — not equivalent to full Unicode case-insensitive comparison. |
| `s17-box-str` | String → Box<str> for immutable strings | M | many permanent strings. | cannot append; conversion may reallocate. |
| `s18-intern-strings` | String interning / numeric IDs | M | many identical keys. | the interning table holds memory; lifetime management needed. |
| `s19-zero-copy-tokens` | Parse slices of the source buffer | M | short-lived tokens. | the source buffer cannot be freed/overwritten before consumers finish. |
| `s20-one-pass-concat` | One-pass concatenation instead of a + b + c | M | many small pieces. | data cost dominates syntax; concat may already be optimized. |
| `s21-simd-parsers` | SIMD digit/JSON/CSV parsers | E | very large homogeneous streams. | E, contract — error behavior, Unicode, dates, escapes and format must match. |
| `s22-utf8-cost` | Price of UTF-8 decoding, without deleting Unicode | P | text pipelines. | contract — skipping non-ASCII changes the result. |
| `s23-path-borrow` | &Path instead of PathBuf | M | path-taking APIs. | Path need not be UTF-8; never blindly convert to str. |
| `s24-reuse-regex` | Don't rebuild a regex/parser per line | M | log processing, template matching. | regex needs a crate; construction/cache cost still exists; thread-safety of reuse. |

## I/O & files

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `i01-bufreader` | BufReader for many short reads | P | files, sockets, text. | a single large read_to_end may not benefit. |
| `i02-bufwriter` | BufWriter for many short writes | P | sockets, files. | **must call flush() explicitly and check the error** or data is lost. |
| `i03-stdout-lock` | Lock stdout once | P | bulk message output. | stdout is already buffered/locked per call; gain depends on frequency; contract — other threads' output interleaving changes. |
| `i04-read-line-reuse` | read_line into a reused String | P | line loops. | must clear(); UTF-8 errors allowed only per contract; read_line keeps the terminator unlike lines(). |
| `i05-read-until` | read_until into a reused Vec<u8> | M | arbitrary bytes / invalid UTF-8. | delimiter handling is yours. |
| `i06-read-to-end` | read_to_end / read_to_string for moderate files | M | one pass over the whole file. | memory growth and time-to-first-result. |
| `i07-batched-writes` | Batched writes instead of writeln! per item | M | high throughput output. | bigger buffer, later flush, latency before data is visible. |
| `i08-write-all` | write_all instead of assuming write writes everything | M | correct and efficient writes. | not a speedup by itself; it is a correctness requirement. |
| `i09-vectored-io` | read_vectored / write_vectored | M | composite buffers. | not every Read/Write actually vectorizes. |
| `i10-batch-syscalls` | Larger network sends / batched syscalls | M | many short messages. | higher latency, backpressure, packet-size limits. |
| `i11-mmap` | Memory-mapped I/O | M | large read-mostly files, random access. | SIGBUS / file-change hazards, platform-specific. |
| `i12-zero-copy` | sendfile / splice / zero-copy | M | sending large files. | complex compatibility and error contract. |
| `i13-no-log-hot-loop` | No println!/logging in the hot loop | P | CPU-bound code. | contract — removing logs changes observability; level filters must remain. |
| `i14-fsync-frequency` | Reduce fsync/flush frequency | M | storage/journal workloads. | contract — **changes the durability guarantee**; only with an explicit reliability contract. |
| `i15-fill-buf-consume` | Buffered parser over fill_buf/consume | M | large streams. | the returned slice is invalid after consume/refill. |
| `i16-io-capacity` | BufReader/Writer::with_capacity | M | known block sizes. | oversized buffers raise memory; defaults are often fine. |
| `i17-reuse-connections` | Avoid reopening files / repeating DNS+handshake | M | many small operations. | fd limits, connection lifetime, stale state. |
| `i18-cache-serialized` | Cache serialized immutable responses | M | frequently sent identical responses. | invalidation, memory, data-safety. |
| `i19-check-io-bound` | Verify time is I/O, not CPU | M | slow end-to-end requests. | CPU optimizations cannot fix I/O-bound load. |

## Loops, iterators, bounds checks

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `l01-iterate-not-index` | Iterate elements instead of indexing | P | simpler bounds-check elimination. | indexes are sometimes genuinely needed to relate several arrays. |
| `l02-zip` | zip two slices | M | less complex indexing. | contract — **stops at the shorter slice**; check lengths when equality is required. |
| `l03-chunks-exact` | chunks_exact(k) | M | 2/4/8-wide blocks. | the tail must be handled via remainder(); forgetting it is a silent bug. |
| `l04-as-chunks` | as_chunks::<N>() | M | SIMD-friendly fixed blocks. | remainder must be handled; do not drop the tail. |
| `l05-split-at` | split_at / split_at_mut | M | parallel or two-region processing. | split boundary check; wrong split logic changes results. |
| `l06-iter-mut` | iter_mut instead of repeated indexing | M | in-place updates. | borrow checker may force restructuring. |
| `l07-hoist-invariants` | Hoist len/config/table indexes/pure math | M | repeated constant computation. | LLVM often does it already — check ASM. |
| `l08-any-all-find` | any / all / find / position for early exit | M | element often found early. | contract — side-effect order/count can change. |
| `l09-filter-map` | filter_map / flat_map without intermediate Vecs | M | transformation pipelines. | loop fusion can hurt locality or parallelism. |
| `l10-fold-sum` | fold / sum / product | M | aggregations. | overflow and evaluation order must be explicit. |
| `l11-fewer-branches` | Fewer conditional branches in the hot loop | M | unpredictable branch conditions. | branchless code may do more total work. |
| `l12-hoist-branch` | Move loop-invariant if out of the loop | M | hot loops with a constant flag. | duplicates code and can increase I-cache pressure. |
| `l13-multiple-accumulators` | Independent accumulators | M | long reduction chains. | contract — for floats, changing the order changes rounding. |
| `l14-manual-unroll` | Manual unrolling | M | extremely short tight loops. | LLVM already unrolls; more code and register pressure. |
| `l15-help-auto-simd` | Simplify access/aliasing for auto-SIMD | M | many same-typed elements. | not every loop is auto-vectorized; check ASM. |
| `l16-length-precheck` | Pre-check length / slice before the loop | M | repeated indexing of the same slice. | panic/error conditions must stay correct. |
| `l17-get-unchecked` | get_unchecked | E | only a proven hotspot with irreducible checks. | E — **UB on a wrong index**; no unsafe for cosmetics. |
| `l18-enumerate` | enumerate when index and element are both needed | M | readable and often good ASM. | no guarantee it is faster. |
| `l19-loop-order` | Change nested loop order | M | matrices, locality. | row/column layout and computation dependencies must be respected. |
| `l20-tiling` | Loop tiling / cache blocking | M | large multi-dimensional arrays. | block size must be tuned to cache/core/data type; small matrices just add loop overhead. |
| `l21-in-place-filter` | Single-pass in-place filtering | M | fewer copies. | mutates the source collection. |
| `l22-scan` | scan instead of a separate accumulation collection | M | prefix processing. | extra iterator logic can hinder optimization. |
| `l23-take-skip-while` | take_while / skip_while for monotone data | M | sorted/prefixed data. | skipping on a wrong condition loses data. |
| `l24-check-asm-first` | Inspect ASM before manual micro-optimization | M | every tight inner loop. | ISA and compiler version matter more than source style. |
| `l25-raw-pointers` | Raw pointers / unsafe traversal | E | only profiled cases with proven invariants. | E — lifetime, aliasing, provenance, UB, heavy maintenance. |

## Cache, data layout, locality

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `d01-sequential-access` | Sequential traversal | P | large datasets. | if the algorithm is inherently random-access. |
| `d02-soa` | SoA instead of AoS | M | passes that read only 1–2 fields of many records. | costly restructuring; worse when a pass needs whole records. |
| `d03-aos` | AoS instead of SoA | M | passes that use most fields of one record. | can block SIMD and waste bandwidth. |
| `d04-shrink-types` | Shrink types; measure enums/structs with size_of | M | millions of records. | size_of is not a performance measurement; narrowing can overflow. |
| `d05-field-order` | Reorder fields under repr(C) | E | large arrays of repr(C) structs with padding. | E — **repr(Rust) does not guarantee field order**, so never rely on textual order there; layout changes are ABI changes. |
| `d06-hot-cold-split` | Hot/cold field splitting | M | hot access to a small part of a record. | extra indirection on cold access. |
| `d07-indices-not-pointers` | Indices instead of scattered heap pointers | M | graphs, ASTs, trees, ECS. | needs invalidation strategy / compact storage. |
| `d08-matrix-blocking` | Cache blocking for matrices | M | matrices larger than L1/L2. | small matrices only gain extra loops. |
| `d09-false-sharing` | False-sharing control via padding | M | threads writing adjacent cache lines. | #[repr(align(64))] costs memory; 64B is not a universal line size. |
| `d10-reduce-random-access` | Reduce random memory jumps | M | hash tables, pointer-heavy trees. | the data structure may be dictated by the problem. |
| `d11-fewer-bytes` | Fewer bytes per object | M | processing millions of records. | contract — a narrow type can overflow and change semantics. |
| `d12-prefetch` | Software prefetch intrinsics | E | predictable, far-ahead access patterns. | E — the hardware prefetcher is often better and manual prefetch can pollute cache. |
| `d13-avoid-giant-temps` | Don't hold giant temporaries simultaneously | M | peak RSS and page faults. | may require recomputation. |
| `d14-reuse-memory` | Reuse memory without extra copies | M | staged processing. | memory held longer; race/ownership complexity. |
| `d15-flat-vs-boxed` | Box<[T]> / flat Vec<T> vs Vec<Box<T>> | M | arrays of objects. | stable addresses and polymorphism need other structures. |
| `d16-compact-common-values` | Compact representation of common values | M | many repeats plus rare exceptions. | encode/decode and branches can cost more than they save. |
| `d17-avoid-memcpy` | Avoid extra memcpy and large moved values | M | large structs. | sometimes a copy is cheaper than a level of indirection. |
| `d18-numa` | NUMA-aware placement / first-touch | E | multi-socket servers, working sets > LLC. | E — platform-specific; wrong binding makes things worse. |

## Threads, sync, atomics

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `p01-thread-scope` | std::thread::scope for independent coarse work | M | long computations. | spawning threads for small batches is expensive. |
| `p02-rayon` | Rayon par_iter | M | CPU-bound independent elements. | work per element must repay scheduler overhead. |
| `p03-thread-pool` | Thread pool instead of spawn-per-item | M | many tasks. | pool memory, queue, stealing overhead. |
| `p04-granularity` | Correct granularity / chunk size | M | sums/filters/parsing. | small chunks drown in coordination; large chunks imbalance. |
| `p05-local-accumulators` | Local accumulators + merge | M | aggregation with a shared counter. | merging costs; float order changes. |
| `p06-sharded-map` | Shard Mutex<HashMap> | M | concurrent map updates. | hashing/routing overhead, memory, cross-shard operations. |
| `p07-short-critical-section` | Don't hold MutexGuard across expensive work | M | latency under contention. | releasing early can break atomicity of a logical operation. |
| `p08-rwlock` | RwLock for read-mostly | M | read-heavy shared state. | can lose on short critical sections. |
| `p09-atomic-counter` | AtomicU64 instead of Mutex<u64> | M | telemetry, counters. | atomics do not replace a composite invariant. |
| `p10-relaxed` | Ordering::Relaxed for a statistics-only counter | E | stats counters. | E — Relaxed guarantees atomicity of that access only, **not** publication of other data or happens-before; never replace Acquire/Release without proving the memory model. |
| `p11-thread-local` | thread_local! state | M | avoiding shared locks. | state is not global; memory per thread. |
| `p12-channels` | Message passing instead of shared mutable state | M | decoupled stages. | copies/queues, blocking, backpressure. |
| `p13-bounded-channels` | Bounded channels | M | memory under overload. | senders block when full — latency and timeouts. |
| `p14-batch-dequeue` | Batch dequeue | M | fewer lock acquisitions. | per-message latency grows. |
| `p15-condvar` | Condvar/parking instead of spin | M | long waits. | wakeup and scheduling overhead. |
| `p16-spin-wait` | Spin-wait for microscopic guaranteed waits | E | special low-latency paths. | E — burns CPU, catastrophic under oversubscription. |
| `p17-arc-contention` | Reduce Arc::clone and refcount contention | M | shared immutable structures. | alternate ownership schemes are more complex. |
| `p18-atomic-padding` | Separate hot atomics onto different cache lines | M | false sharing. | more memory. |
| `p19-lockfree-vs-mutex` | Compare lock-free with a plain Mutex | M | proven high contention. | lock-free is harder, can lose, and has memory-reclamation problems. |
| `p20-cap-threads` | Cap threads at CPU/memory saturation | M | high contention, NUMA. | "more threads is better" is false. |
| `p21-work-stealing` | Work stealing / load balancing | M | variable task cost. | migration and cache loss can cancel the gain. |
| `p22-separate-pools` | Separate IO-bound and CPU-bound queues | M | server workloads. | adds a coordination layer. |
| `p23-available-parallelism` | available_parallelism as a starting hint | M | initial pool sizing. | it is a hint, not the optimum. |
| `p24-immutable-shared` | Immutable shared data + local state | M | read-mostly workloads. | copying big structures/snapshots also costs. |
| `p25-rcu-crossbeam` | RCU / crossbeam lock-free structures | E | special read-heavy workloads. | E — memory reclamation and correctness guarantees are subtle. |

## SIMD & CPU features

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `v01-auto-vectorize` | Help LLVM auto-vectorize first | P | dense arithmetic. | may be memory- or branch-bound, not ALU-bound; check ASM. |
| `v02-independence` | Split arrays into independent contiguous slices | M | easier aliasing analysis. | lengths must be preserved exactly. |
| `v03-simplify-body` | Simplify the loop body, remove unpredictable calls | M | vectorizer analysis. | reordering float ops changes results. |
| `v04-target-cpu-native` | target-cpu=native | M | dedicated machine. | binary portability is lost. |
| `v05-intrinsics` | std::arch intrinsics | E | a critical loop after profiling. | E — unsafe, tail handling, alignment, hardware support. |
| `v06-target-feature-dispatch` | #[target_feature(enable = "avx2")] + CPU dispatch | E | heterogeneous fleet. | E — calling the function without the feature is a safety violation (UB). |
| `v07-runtime-detect-once` | is_x86_feature_detected! outside the loop | M | x86 runtime dispatch. | per-element checks add overhead; hoist the check. |
| `v08-scalar-fallback` | Scalar fallback | M | CPUs without the feature. | two implementations to maintain and test. |
| `v09-vectorized-bytes` | Vectorized byte search / UTF-8 validation / hashing | M | long inputs. | SIMD overhead dominates small inputs. |
| `v10-tail-handling` | Handle the tail after SIMD blocks | M | lengths not divisible by the vector width. | dropping the tail is a silent correctness bug. |
| `v11-types-contiguity` | Reasonable data types and contiguous memory | M | vectorization and bandwidth. | a smaller type can overflow. |
| `v12-measure-avx2` | Measure AVX2 vs scalar on the real CPU | M | all SIMD work. | frequency and memory bandwidth can erase the ALU gain. |
| `v13-fma` | FMA (fused multiply-add) | E | dense float kernels. | E, contract — rounding and bitwise results change. |
| `v14-alignment` | Align buffers for SIMD | E | some kernels/instructions. | unaligned loads are often fine; alignment costs RAM. |
| `v15-manual-vs-auto` | Compare hand-written SIMD with auto-SIMD | M | genuinely hot loops. | manual code can be slower and less portable. |
| `v16-portable-simd` | std::simd / portable SIMD | E | potentially portable vector code. | E — **check stability status in your toolchain**; do not assume it is available on stable. |
| `v17-no-per-element-detect` | Avoid per-element runtime ISA detection | M | large arrays. | the check cost dominates short loops. |
| `v18-size-specialization` | Specialize by input size | M | mixed input sizes. | the threshold must be tuned. |

## Dispatch, inlining, layout

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `g01-generic-over-dyn` | Concrete type / generic instead of dyn Trait | M | hot short calls, known types. | monomorphization bloats the binary and build time. |
| `g02-dyn-over-generic` | dyn Trait instead of many instantiations | M | binary size, compile time. | virtual call and lost interprocedural optimization. |
| `g03-enum-dispatch` | enum + match instead of Box<dyn Trait> for a fixed set | M | hot dispatch with a closed set. | API change; enum size is the largest variant (split hot/cold payloads). |
| `g04-inline-attr` | #[inline] on a small hot cross-crate function | M | tiny hot functions. | may grow code and hurt I-cache. |
| `g05-inline-always` | #[inline(always)] in exceptional cases | E | profile/ASM prove the benefit. | E — large I-cache pressure; no guarantee; can regress through code bloat (§37.4). |
| `g06-inline-never` | #[inline(never)] for a large cold branch | M | shrinking the hot footprint. | call cost and worse interprocedural optimization. |
| `g07-cold` | #[cold] on rare error paths | M | hot path layout. | a hint only; a wrong frequency estimate makes it worse. |
| `g08-lto-dispatch` | LTO/ThinLTO for cross-crate optimization | M | library call sites. | build cost, sometimes worse runtime. |
| `g09-avoid-boxed-closures` | Avoid Box<dyn Fn> for short closures | M | a few hot callbacks. | generics complicate APIs and grow code. |
| `g10-fast-path-dispatch` | Dedicated fast path for the common case | M | skewed workloads. | duplicated business logic can drift. |
| `g11-cold-formatting` | Move cold error formatting out of the main loop | M | parsers, binary protocols. | error behavior must stay identical. |
| `g12-ffi-boundary` | Minimize FFI boundary crossings in tight loops | M | many short C calls. | reimplementing in Rust is not always faster than an optimized C library. |
| `g13-fn-pointer-table` | Function-pointer dispatch tables | E | a set of fast implementations. | E — indirect call; a wrong target can violate safety. |
| `g14-remove-wrappers` | Remove wrapper layers in the hot path | M | only when the ASM shows them. | LLVM usually removes them already; manual rewriting can hurt abstraction. |

## Arithmetic & floats

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `n01-right-type` | Use the right integer/float type for the real range | P | size, vectorization, correctness. | narrowing without a range check overflows/truncates. |
| `n02-overflow-semantics` | Choose checked/wrapping/saturating deliberately | P | clear arithmetic and overflow behavior. | contract — **three different semantics**; swapping is not neutral. |
| `n03-const-division` | Constant division optimization | M | hot integer arithmetic. | hand-written shifts are not correct for all signed cases. |
| `n04-shift-division` | Shift instead of division for unsigned 2^k | E | narrow kernels. | E, contract — not valid for signed negatives without an equivalence proof. |
| `n05-bit-ops` | count_ones / leading_zeros / trailing_zeros | M | bit algorithms. | CPU-specific fast paths; no gain for rare calls. |
| `n06-bitmask` | Bitmasks instead of many bools | M | small set domains. | bit order and shift bounds must be explicit. |
| `n07-table-lookup` | Table lookup for an expensive function on a small domain | M | many repeated calls. | memory/cache pressure and indexing cost. |
| `n08-rearrange-ops` | Rearrange operations to cut divisions/expensive calls | M | arithmetic loops. | contract — floating point may change rounding. |
| `n09-int-accumulators` | Independent integer accumulators | M | long add chains. | combining modulo 2^N needs explicit semantics; float order matters. |
| `n10-f32` | f32 instead of f64 | E | GPU/SIMD, memory-bound, acceptable precision. | E, contract — changes precision, numerical stability and values. |
| `n11-fma-mul-add` | FMA / mul_add | E | hot multiply+add. | E, contract — different rounded result. |
| `n12-fewer-transcendentals` | Fewer sqrt/sin/powf calls | M | math-heavy code. | approximations change accuracy. |
| `n13-squared-distance` | Squared distance instead of sqrt for comparisons | M | non-negative distance comparisons. | overflow/NaN/Inf and other contracts. |
| `n14-precompute-coefficient` | Precompute a rarely changing coefficient | M | DSP, models, physics. | values/overflow during precomputation. |
| `n15-fixed-point` | Fixed point instead of float | E | deterministic numbers, known range. | E, contract — overflow, scale and precision. |
| `n16-bigint` | Big integers only when needed | M | crypto/precision code. | replacing big integers with machine ints is **not** equivalent. |
| `n17-reduce-casts` | Scaling without excessive as conversions | M | tight numeric loops. | as can truncate/change values. |
| `n18-approx-math` | Approximate math functions | E | graphics/ML with tolerance. | E, contract — must state a max error over the input domain. |
| `n19-ascii-digit-parse` | is_ascii_digit / b'0' subtraction when parsing ASCII | M | ordered decimal bytes. | validate 0..9, length and overflow. |
| `n20-nonzero-niche` | NonZeroUsize/NonZeroU32 and niche optimization | M | specific Option representations. | measure size_of rather than assuming layout. |
| `n21-saturating-counters` | Saturating counters for statistics | E | "never exceeds ceiling" counters. | E, contract — **changes** behavior at large values. |
| `n22-zero-fast-path` | Zero-check before an expensive rarely-nonzero operation | M | sparse data. | on dense data the branch can hurt. |

## Globals, caches, lazy init

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `q01-const` | const / const fn for compile-time values | P | constant tables/scalars. | not every operation is const-evaluable. |
| `q02-static` | static for one large immutable array | M | large constant data. | const may be inlined at each use; static is one copy but may hurt locality/relative addressing. |
| `q03-once-lock` | OnceLock for one-time init | M | config known at first use. | first access is expensive; reentrant init can block. |
| `q04-lazy-lock` | LazyLock | M | static caches read regularly. | **a panic during initialization poisons the LazyLock**. |
| `q05-thread-local-buffers` | thread_local! per-thread buffers | M | removing shared locks. | per-thread memory; different semantics than global state. |
| `q06-atomic-counters` | Atomic counters instead of Mutex | M | simple counters. | ordering and atomicity limits. |
| `q07-shard-cache` | Shard a shared cache | M | frequent concurrent ops. | invalidation and per-shard memory. |
| `q08-stale-reads` | Less frequent invalidation when stale reads are acceptable | M | read-heavy apps. | contract — **changes the freshness contract**. |
| `q09-precompile` | Precompile regex/parser/schema | M | many identical handlers. | dependencies, memory, cold-start time. |
| `q10-dont-cache-cheap` | Don't cache cheap computations | M | tight hot working memory. | cache lookup can exceed arithmetic cost. |
| `q11-static-mut` | Replace static mut with safe synchronization | E | any global mutable state. | E — primarily safety/correctness, not automatic speed. |
| `q12-lazy-cell` | LazyCell/OnceCell where single-threaded | M | single-threaded local lazy state. | not a synonym for thread-safe OnceLock. |

## Async / Tokio

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `x01-no-blocking-in-async` | No long blocking CPU work on the async worker | P | async servers. | other tasks stop making progress; watch for latency spikes. |
| `x02-spawn-blocking` | spawn_blocking | M | sync libraries inside async. | separate pool; tasks are not automatically cancellable. |
| `x03-backpressure` | Bounded mpsc + semaphore for backpressure | M | request floods. | waiting/timeouts under overload. |
| `x04-limit-tasks` | Don't create millions of unbounded tasks | M | high load. | memory per future, queues, timers. |
| `x05-batch-messages` | Batch messages | M | networking/log pipelines. | latency and buffer size. |
| `x06-short-critical-section` | Minimize the shared-state critical section | M | many tasks. | do not break operation atomicity. |
| `x07-no-std-guard-across-await` | Never hold std MutexGuard across .await | E | any async critical path. | E — deadlock/worker-blocking risk; restructure (scope the guard, or copy data out). |
| `x08-tokio-mutex` | tokio::sync::Mutex when the lock must span .await | M | truly async critical sections. | usually more expensive than a sync mutex for short synchronous access. |
| `x09-bytes` | bytes::Bytes for shared immutable buffers | M | shared network buffers. | refcount and lifetime; not always needed. |
| `x10-no-handoff-copies` | Avoid String/Vec copies at task handoff | M | pipelines. | ownership complexity; long-lived buffer retention. |
| `x11-connection-pool` | Connection pooling | M | many short requests. | timeouts, pool sizing, stale connections. |
| `x12-tls-copies` | Count copies/syscalls during TLS/serialization | M | high-volume networking. | the hotspot may be outside your crate. |
| `x13-fewer-wakeups` | Minimize wakeups for frequent events | M | async high throughput. | fairness/edge cases. |
| `x14-cancellation-safety` | select!/join! with cancellation safety in mind | E | many concurrent operations. | E — cancellation can lose intermediate state. |
| `x15-separate-pools` | Separate CPU-bound and blocking-IO pools | M | mixed loads. | more complex scheduling/limits. |
| `x16-sync-when-simple` | Replace async with sync for simple linear code | M | CLI/compute. | async may be required by the protocol or future scaling. |
| `x17-measure-all` | Measure CPU, RSS, queues and p99 together | M | production services. | throughput optimization can worsen tail latency. |

## Worked examples

| ID | Technique | Pri | When it pays | Check / when it hurts |
|---|---|---|---|---|
| `ex19-01-with-capacity` | Reserve capacity for a known length | P | large predictable push volume. | both versions allocate nothing when input is usually empty; an estimate that is too large wastes RAM. |
| `ex19-03-no-clone-lookup` | Don't clone a String just to look it up | P | HashMap<String, _> plus a temporary String on get. | contract identical for equal keys; the key type must keep Borrow<str> consistent with Hash/Eq. |
| `ex19-04-entry` | One key probe via entry | P | repeated access to the same key (counting). | both versions use plain usize addition, i.e. the same overflow-check settings; real counter overflow is still possible in normal code. |
| `ex19-09-read-line` | Line reading with a reusable String | P | thousands of lines read without keeping them all. | lines() strips the terminator, read_line() keeps it inside the String — normalize semantics first. UTF-8 errors must still be handled. |
| `ex19-11-retain` | Kill O(n²) removal by index | P | discarding many elements from a large Vec. | relative order is preserved; shifts still happen. It mutates the original vector — not equivalent to collecting a new one if the caller needs the old container. |
| `ex19-02-buffer-reuse` | Reuse the buffer between calls | P | repeated similar-size batches. | contract — the API changes; the function returns nothing and overwrites the external buffer. The caller must compare contents after each call. |
| `ex19-05-vecdeque` | Queue instead of shifting the array | P | frequent head removal. | if you only traverse once, values.iter().map(/&x/ x as u64).sum() needs no queue at all. |
| `ex19-06-single-pass` | One pass without an intermediate container | P | intermediate collection is not reused. | fold(0, u64::wrapping_add) explicitly preserves modular overflow in both versions; keep that. |
| `ex19-07-early-exit` | Early exit instead of full count | P | the target is usually found early. | same result for plain u32; for user types with side-effecting PartialEq, fewer comparisons is an observable change. |
| `ex19-08-split-once` | Find one separator without building a Vec | P | only the first separator is needed. | both return borrowed slices; split_once correctly yields "" for an empty part. |
| `ex19-10-stdout-lock` | Lock stdout once | P | frequent output. | contract — concurrent output from other threads is serialized over a larger region, which can **change message interleaving**. |
| `ex19-12-swap-remove` | swap_remove only when order is irrelevant | M | unordered containers. | contract (behavior_change = "order"): both return the removed element, but remaining order **may differ**; not equivalent for a task queue or time series. |
| `ex19-13-chunks-exact` | chunks_exact with a handled tail | M | regular 2/4/8-element blocks. | must not forget the tail or the exact overflow semantics. |
| `ex19-14-zip-length` | zip with an explicit equal-length contract | M | related arrays of equal length. | without the pre-check, zip silently ignores the longer array's tail — **not** a substitute for indexing that mandates equal lengths. |
| `ex19-15-median-select-nth` | Median without a full sort | M | upper median, order of the rest irrelevant. | returns a single middle element; the even-length "average of two middles" is a different algorithm. Reorders the vector. |
| `ex19-16-bitset` | HashSet of small integers → bitmask | M | known dense u8 domain. | cannot do this for random u64; at very small volumes the difference may vanish. |
| `ex19-17-write-not-format` | Build text without format! per value | M | frequent format!/push_str. | contract — APIs differ (String vs Result<String, fmt::Error>); choose a fmt::Result policy and keep the old return type. write! formatting is not free. |
| `ex19-18-return-slice` | Return a slice instead of a mandatory copy | M | prefix extraction. | contract — deliberate API/lifetime change, not a drop-in replacement. |
| `ex19-19-lazy-lock` | One-time init with LazyLock | M | expensive table used repeatedly. | if the table is rarely needed or cheap, laziness only adds complexity. LazyLock is thread-synchronized; a panic during init poisons it. |
| `ex19-20-ascii-specialization` | ASCII-specialized branch with fallback | M | mostly-ASCII input that must still handle Unicode. | results for some non-ASCII characters depend on Unicode tables; this is not grapheme counting. Never replace the Unicode branch with "delete non-ASCII". |
| `ex19-21-retain-condition` | In-place removal by a ready-made condition | M | filtering without a second vector. | **not** equivalent to iter().filter().collect() if the caller must keep the original container; ownership contract changes. |
| `ex19-22-detect-once` | Check the CPU feature once, outside the loop | M | large-array processing. | this is only a dispatcher, not a SIMD kernel; the #[target_feature] function may only be called after a proven check. |
| `ex19-23-parallel-large` | Parallelism only for large work | M | large independent computations. | join() errors are not swallowed (thread::Result). For small arrays, thread creation costs more than the arithmetic. |
| `ex19-24-batched-lock` | Excessive synchronization → local accumulator | M | very frequent locks on one counter. | contract — other threads now see batched updates instead of intermediate values; contention ordering and lock-poison behavior may change. |

---

If a technique is not here, it is probably in the guide this catalog was extracted from; if it is not there either, it is an experiment, and an experiment without a measurement is a guess.
