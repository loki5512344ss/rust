# Semantics traps: when "faster" is a different program

Speed obtained by changing behavior is not an optimization. It is a rewrite
that happens to pass the tests you ran. This file is the list of contracts that
break silently.

## 1. Write the contract before the patch

Fill this in; if a line is unknown, say so instead of assuming.

```text
Inputs:            domain, sizes, encoding, empty/None cases
Outputs:           exact bytes? canonical form? both?
Ordering:          stable sort? insertion order? FIFO? tie-breakers?
Counts:            does every element get processed? is truncation allowed?
Numbers:           checked vs wrapping? integer width? signedness?
Floats:            tolerance (abs/rel/ULP)? NaN/inf/-0.0 policy? reassociation?
Errors:            panic vs Result vs Option? when detected? partial effects?
Strings:           UTF-8 boundaries? byte vs char semantics? normalization?
Concurrency:       memory order, lost/duplicated messages, cancellation, panic state
Observable:        logs, metrics, counters, Drop order, external call timing
API/ABI:           public signatures, serialized format, struct layout
```

## 2. Transformations that require an explicit decision (never automatic)

| Change | Why it is not free |
|---|---|
| `sort` → `sort_unstable` | equal elements may reorder; stability is part of the contract |
| `remove(i)` → `swap_remove(i)` | order changes |
| `checked_add` → `wrapping_add` | error becomes modulo arithmetic |
| `u64` → `u32` / `usize` → `u32` | silent truncation above the limit |
| `String` → `[u8; N]` / `SmallString` | bound and encoding policy must exist |
| `.chars()` → `.bytes()` | UTF-8 semantics change |
| `zip` without length check | truncates to the shorter input |
| `chunks_exact` without `remainder()` | drops the last 1..N-1 elements |
| `.take(limit)` moved/removed | changes how many items are processed |
| reordering events / batching | breaks causality, FIFO, per-client order, fairness |
| merging ticks (`ticks += n`) | changes temporal semantics of handlers |
| hoisting `Instant::now()` | per-event timestamps become one timestamp |
| replacing `Mutex` with `Relaxed` atomics | publication protocol is not preserved |
| `f64` sum reordered / FMA substitution | result bits change |
| removing `flush()` / `fsync()` | durability and visibility change |
| faster non-cryptographic hasher on untrusted input | HashDoS |
| `-C target-cpu=native` in a shipped binary | `SIGILL` on other CPUs |
| `panic=abort` | no unwinding, no `catch_unwind`, destructors skipped |
| `#[repr(packed)]` | unaligned refs are UB-adjacent and slower |

Every row above needs (a) a human decision, (b) a test that would fail under
the old contract if behavior changed, and (c) a line in the report saying the
contract changed.

## 3. Floats are a separate discipline

- `a + b + c` ≠ `a + (b + c)` in IEEE-754. Any reassociation, any SIMD
  reduction, any parallel sum changes bits.
- FMA computes `a*b + c` with one rounding — often *more* accurate, never
  bit-identical to separate multiply/add.
- Define tolerance before vectorizing: absolute, relative, or ULP. Test near
  zero, denormals, `NaN`, `±inf`, and `-0.0`.
- `f32` halves memory but loses precision; do not switch types to win a
  benchmark.
- `sort_by(|a, b| a.partial_cmp(b).unwrap())` panics on `NaN`; that is a
  contract, not a nuisance.

## 4. Integers

- Debug builds check overflow and panic; release wraps. A benchmark that is
  fast only because it wraps differently is not a win.
- `x / 8` is not `x >> 3` for negative signed values (truncation vs floor).
- Shift amount ≥ bit width is UB in debug-ish terms (`panic` with checks,
  masked in release) — never "optimize" it into a mask.
- `%` by a power of two only equals `& (m-1)` for **unsigned** `x` and
  `m = 2^k`. Constant divisors are already turned into multiply-shift by LLVM.

## 5. `unsafe` — a checklist, not a shortcut

For every `unsafe` block:

- [ ] `// SAFETY:` comment stating the invariant in terms of the actual inputs.
- [ ] The proof covers: empty slice, length 0/1, tail elements, overflow in
      index arithmetic, aliasing, initialization, alignment, lifetime.
- [ ] Tests for each of those cases, including a `debug_assert!` of the
      invariant where it is cheap.
- [ ] Miri run on the relevant tests (`cargo +nightly miri test`).
- [ ] A safe alternative tried first and its measured cost documented.
- [ ] Reviewer can verify the invariant without running the program.

If any box is unchecked, the speedup is not available to you. `get_unchecked`
passes the tests that happen to cover the tested inputs; that is the entire
problem.

Fork addition: the harness fails an experiment that adds or changes an
`unsafe` region relative to the baseline (`FAIL(unsafe_added)`, before the
build). It compares tokenized regions rather than names, so a new
`get_unchecked` is caught through the region that contains it; `unsafe` that
was already there is not judged. Passing the gate is not a safety argument.

### Tooling that actually checks this

```bash
# UB in unsafe code (slow; run on the modules that contain unsafe)
rustup component add miri
cargo +nightly miri test

# concurrency: exhaustive interleavings for lock-free code
# Cargo.toml: [dev-dependencies] loom = "0.7"  (cfg(loom) model tests)
RUSTFLAGS="--cfg loom" cargo test --release

# fuzzing: input-space search for panics/UB
cargo install cargo-fuzz
cargo fuzz init && cargo fuzz run target_name -- -max_total_time=60

# property tests: differential old-vs-new on generated inputs
# proptest = "1" / quickcheck; compare outputs exactly (or within float tolerance)

# sanitizers (nightly, Linux): races and memory errors in C-like unsafe
RUSTFLAGS="-Zsanitizer=thread" cargo +nightly test -Zbuild-std --target x86_64-unknown-linux-gnu
```

Rules for using them:

- Miri proves "no UB on these tests", not "sound for all inputs"; keep the
  invariant comment anyway.
- Loom tests the *protocol*, not your whole app; model the shared state only.
- Fuzzing finds crashes, not logic errors; pair it with a property assertion.
- A sanitizer that finds nothing is not evidence of absence in code the tests
  never reach.
- None of these replace a differential test against the old implementation.

## 6. Concurrency contracts

- `Relaxed` is fine for an independent counter, wrong for publishing data.
  If two fields must be seen together, you need a lock, a seqlock, or
  Acquire/Release with a documented protocol.
- Batching improves throughput and worsens p99; both are outputs.
- Cancellation and `Quit`/shutdown paths must still be handled at every batch
  boundary.
- A `Mutex` poisoned by a panic changes behavior; `unwrap()` on the guard is a
  contract change.
- Removing a lock can turn a rare race into a rare data corruption — which
  tests will not catch.

## 7. Observability changes that count as behavior

Removing a log line, a metric increment, or a counter changes what operators
see. Sometimes that is desirable (hot-path logging), but it is a declared
change, not a side effect of "optimization". Same for `Drop` order and for
when external calls happen relative to each other.

## 8. How to prove equivalence

1. **Targeted tests** for each contract line: empty, one, many, max, duplicate
   keys, UTF-8 multi-byte, overflow boundary, `NaN`.
2. **Differential test**: run old and new implementations on randomized inputs
   (property test / proptest) and compare outputs exactly — or within the
   declared tolerance for floats.
3. **Replay**: for event systems, a recorded deterministic log replayed through
   both versions, comparing full state.
4. **Oracle**: an independent, slow, obviously-correct implementation for small
   inputs.
5. State which of these you actually ran. "Tests pass" without naming them is
   not evidence.

## 8b. Kani: proving a property for all inputs up to a bound

Tests and fuzzing sample inputs. Kani (a bounded model checker for Rust, from
the `kani-verifier` project) translates a harness to a logical formula and
checks it for **every** input value, with loops unrolled up to a bound. If the
property can fail within the bound, it returns a concrete counterexample.

Good fits for optimization work:

- arithmetic rewrites: `x / 8` vs `x >> 3`, `x % m` vs `x & (m - 1)`,
  multiply-shift replacing a division, overflow-free midpoint;
- bit tricks: popcount/SWAR, branchless min/max/abs, sign handling;
- index arithmetic: a computed index is always `< len`, chunk/remainder
  splits cover every element exactly once;
- small `unsafe` blocks: the precondition of `get_unchecked`, `from_utf8_unchecked`
  or a pointer offset holds for all inputs that reach it.

Shape of a harness (old vs new over all `u32`):

```rust
#[cfg(kani)]
mod proofs {
    #[kani::proof]
    fn div8_matches_shift() {
        let x: u32 = kani::any();
        assert_eq!(crate::old_div8(x), crate::new_div8(x));
    }

    #[kani::proof]
    #[kani::unwind(9)]            // loop bound + 1
    fn sum_matches_on_short_slices() {
        let v: [u8; 8] = kani::any();
        let n: usize = kani::any();
        kani::assume(n <= 8);
        assert_eq!(crate::old_sum(&v[..n]), crate::new_sum(&v[..n]));
    }
}
```

```bash
cargo install --locked kani-verifier && cargo kani setup
cargo kani                       # runs every #[kani::proof]
```

Limits — the proof is only as wide as these:

- **Bounds.** The second harness proves equality for slices of length ≤ 8,
  not for all lengths. A bug that needs 9 elements, or a SIMD path that only
  starts at 16, is outside the proof. State the bound in the report.
- **Loops** must be unwound; too low a bound fails the unwinding check (good),
  too high a bound makes the solver run for hours.
- **Heap-heavy code** (large `Vec`, `HashMap`, trees) and floating-point
  transcendental functions are slow or unsupported in practice; prove the
  arithmetic kernel, test the container code.
- **Concurrency** is out of scope; use Loom (§5).
- Build time: Kani compiles through its own toolchain and the solver time is
  unpredictable; keep harnesses small and run them on the changed functions.
- A proof of `old == new` inherits any bug in `old`. Add independent
  properties (bounds, monotonicity) where the contract has them.

**Kani is not installed on this machine: the harness and commands above are
`not verified on this machine` (API as documented by the Kani project).**

## 8c. Differential-fuzz scaffold (no dependencies)

`scripts/diff-fuzz.sh` writes a dependency-free differential test that runs
the old and the new function on generated inputs and compares the outputs:

```bash
scripts/diff-fuzz.sh --out <DIR> --old my_crate::old::count --new my_crate::count --sig slice-u64
# --sig: slice-u64 | slice-u8 | str — the input type both functions take
# paths start with the LIBRARY name: in an integration test `crate::` is the test crate.
# writes <DIR>/diff_fuzz.rs; a failure prints a DIFF_FUZZ_REPLAY=... command that reruns that one case.
# refuses to write into tests/ of a repo under a rustperf run (tests/** is frozen at baseline).
```

Read and adjust what it generates before trusting it: the input sizes must
include the boundaries of *your* code (0, 1, lane width ± 1, chunk size ± 1),
and the comparison must match the contract (exact, or a declared float
tolerance).

Where it sits:

| Tool | Inputs | Finds | Costs |
|---|---|---|---|
| `diff-fuzz.sh` scaffold | pseudo-random + fixed boundary sizes, plain `cargo test` | output mismatches on common shapes | no shrinking, no coverage guidance |
| `proptest` | generated with strategies, shrinks failures | mismatches with a minimal counterexample | a dev-dependency |
| `cargo-fuzz` (libFuzzer) | coverage-guided mutation, hours | rare paths, panics, UB with sanitizers | nightly, a fuzz crate, CPU time (not installed here) |
| Kani (§8b) | all inputs within a bound | any violation within the bound | bounds, solver time (not installed here) |

Use the scaffold first because it needs nothing; move to proptest when you
need shrinking, to cargo-fuzz when the input is a format (parser, decoder),
and to Kani when the function is small and the input space is the risk.

## 9. The two failure classes — do not conflate them

| Class | Example | Evidence needed |
|---|---|---|
| **Slower but correct** | extra clone, unjustified `HashMap` | a benchmark |
| **Semantically wrong** | dropped tail, reordered events, changed overflow | a counterexample test |

A wrong program can be arbitrarily fast. That is not an optimization, and no
percentage makes it one.
