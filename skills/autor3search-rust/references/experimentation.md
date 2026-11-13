# Experimentation mode: many radical rewrites, one proven winner

Use this when the request is **"experiment with optimizing this"**, not
"fix this one hot spot". The goal is not one careful patch; it is a set of
structurally different implementations of the same contract, each measured,
with the winner kept and the knowledge written down.

The danger is equally clear: rewriting everything destroys attribution. The
discipline below keeps attribution intact while allowing radical changes.

## 0. Non-negotiables

1. **Freeze the baseline first.** `git status` clean, tag or record the exact
   commit and binary hash. Every variant is measured against *that* baseline,
   never against the previous variant (unless you are deliberately stacking,
   and then say so).
2. **The contract is the test.** Write down outputs/order/errors/float
   tolerance before variant 1. Build a differential test: original
   implementation as oracle vs candidate, on real inputs plus generated ones.
   A variant that fails equivalence is rejected regardless of speed.
3. **One variant = one branch/commit = one measurement.** Never mix two ideas
   in one candidate, even in "experiment" mode.
4. **Every number has a command.** `not measured` is a valid result.
5. **No variant is "better" until the small-N and real-distribution sweeps
   agree.** The fastest code on the benchmark's favorite size is often a
   regression on real data.

## 1. Snapshot: keep the original working implementation

```bash
git status                                   # must be clean
git tag exp-baseline-$(date +%Y%m%d-%H%M%S)  # name the frozen point
cargo build --release
cp target/release/app /tmp/app.baseline      # keep the binary too
sha256sum /tmp/app.baseline
```

Keep the original source available as an oracle for differential testing
(copy the function into the test module under `#[cfg(test)]`, or keep the
pre-change file under `benches/oracle/` if the crate allows it). Do not rely
on memory of "how it used to work".

## 2. Generate variants (aim for 4–8, structurally different)

Variants must differ in *mechanism*, not formatting. A useful set for a hot
loop or parser:

| Variant family | Example change |
|---|---|
| V0 | baseline, untouched |
| V1 | remove allocations (scratch buffer, `with_capacity`, `Cow`) |
| V2 | different container (sorted `Vec`, `IndexMap`, dense index, `SmallVec`) |
| V3 | different algorithm (single pass, early exit, top-k heap, prefix sums) |
| V4 | byte-level instead of char-level (with an explicit UTF-8 argument) |
| V5 | layout change (SoA, hot/cold split, smaller integer type) |
| V6 | autovectorization-friendly rewrite (`chunks_exact`, independent accumulators) |
| V7 | `unsafe`/SIMD — only with a written proof, and only after V1–V6 are measured |

Rules for generating:

- Each variant is a *complete* alternative implementation of the same
  function, not a diff against V1.
- Keep public signatures identical unless the request allows API changes; if
  an API change is part of the experiment, note it and measure the call sites.
- Do not "improve" unrelated code in the same variant.
- Reject variants that need a contract change (stable sort, ordering, error
  type, precision) unless the human approved it explicitly.

## 3. Measure each variant identically

```bash
# same flags, same inputs, same machine state for all variants
for v in v0 v1 v2 v3; do
  git switch "$v"
  cargo build --release
  cp target/release/app "/tmp/app.$v"
done

# interleaved A/B against the frozen baseline, not sequential blocks
bash scripts/bench-ab.sh --warmup 3 --runs 25 -- /tmp/app.baseline /tmp/app.v2 -- input.bin
```

Then, for the plausible winners only:

- `perf stat` before/after (cycles, instructions, branch/cache misses);
- `cargo asm` diff of the hot function (or `objdump` of both binaries);
- allocation counts (bench-only counting allocator);
- small-N sweep (`0,1,2,3,16,1k,1M`) and the real production distribution.

A variant is a candidate only if: all tests pass, differential test passes,
median improves beyond noise, and no measured regression elsewhere.

## 4. Decide, and write down what was learned

Keep the winner. Revert losers. Then append to the optimization log — this is
part of the task, not an optional nicety.

**Where:** `<repo>/OPTIMIZATION_LOG.md` (create if absent). Do not put it in
`docs/` if the project keeps docs elsewhere; ask if the convention is unclear.
Never edit the log to make a rejected idea look successful.

**Format — one entry per *proven* method:**

```markdown
## <short method name>

- **Date / rustc / machine:** 2026-11-09 / 1.99.1 / Xeon E5-2680 v3
- **Where:** `src/parser.rs::parse_line`
- **Problem:** one heap allocation per token; profile: 3 allocator calls per
  character, `call __rust_alloc` in the loop.
- **Method:** one scratch `String`, `clear()` per token, `push` instead of
  `word = word + &c.to_string()`.
- **Contract:** identical output for identical input; verified on N inputs.
- **Evidence:** 1.426 ms → 0.985 ms (−30.9 %, interleaved medians);
  instructions −30.3 % (`perf stat`); asm: allocator calls gone from the loop.
- **Limits:** 4–13 % slower for inputs ≤ 10 tokens (double hash on miss);
  wins above ~1 token per 10 bytes.
- **Applies when:** tokenisation with many short tokens; `&str` in, owned keys
  out.
- **Rejected alternatives:** byte-slice tokenizer (not measured, needs UTF-8
  proof); `ida`-style SIMD (no profile evidence).
```

Log rules:

- Only methods with a real measurement. "Should be faster" goes in the
  rejected list with `not measured`, never in the method entry.
- Record the **cost** and the **conditions**, not just the win. A method
  without limits is marketing.
- Record the failing variants too, with one line on why they lost — the next
  agent should not repeat them.
- If the same method already exists in the log, append new evidence rather
  than duplicating the section.
- Keep entries short enough to scan; link to the commit/benchmark artifact.

## 5. What to do when nothing wins

Write it down: "V1–V6 measured, none cleared the noise floor; bottleneck is
I/O, not code" is a valuable result. Do not invent a winner and do not widen
the benchmark until something passes.

## 6. Interaction with the autor3search-rust harness

- The harness evaluates one commit at a time; experimentation maps to one
  branch per variant and `eval` on each (or `git reset --hard HEAD~1` between
  variants).
- `KEEP` advances the measurement baseline. For fair variant comparison,
  measure every variant against the *frozen* baseline, then apply the winner
  to the branch as one commit.
- The harness has no allocation metrics: the log is your only record of them.
  This fork's harness refuses new or changed `unsafe` (`FAIL(unsafe_added)`),
  so a V7-style variant cannot go through `eval` unless a human set
  `allow_unsafe: true` before `baseline`; measure it by hand instead.
- Never let the experiment machinery touch `tests/`, `benches/`, config or
  `results.tsv`.

## 7. Reporting back

```text
BASELINE     commit/tag, binary hash, exact commands
CONTRACT     what had to stay identical, and how it was checked
VARIANTS     V1..Vn: mechanism, measured result, verdict, one-line reason
WINNER       patch/commit, numbers, asm change, limits
LOG          path to OPTIMIZATION_LOG.md, entry title
REJECTED     ideas that lost or could not be measured, with reasons
UNKNOWN      what remains unverified
```
