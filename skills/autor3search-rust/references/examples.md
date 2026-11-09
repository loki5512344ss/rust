# Worked examples: hypothesis → asm → measurement → verdict

These are *candidates*, not promises. In real runs some of them measure 0 %.
The point of each example is the shape of the reasoning, not the number.

---

## 1. Quadratic `String` rebuild (real harness case, −13.57 %)

**Symptom.** `count_words` is the top symbol in `perf report`.

**Code (slow on purpose):**

```rust
let mut word = String::new();
for c in field.chars() {
    let c = c.to_ascii_lowercase();
    if c.is_ascii_lowercase() || c.is_ascii_digit() {
        word = word + &c.to_string();   // alloc + copy every character
    }
}
```

**What the asm showed.** Inside the loop: `call __rust_alloc`, `call
memcpy`, `call __rust_dealloc` — three calls per character. Not arithmetic
bound; allocator bound.

**Hypothesis.** Removing the per-character allocation removes the calls.

**Patch.**

```rust
let mut word = String::with_capacity(field.len());
for c in field.chars() {
    let c = c.to_ascii_lowercase();
    if c.is_ascii_lowercase() || c.is_ascii_digit() {
        word.push(c);
    }
}
```

**Contract.** Same output for the same input; `with_capacity` is only a hint,
so nothing observable changes.

**Measurement.** 10 interleaved rounds per side, plus a discarded warmup;
Mann-Whitney on the medians.

| metric | before | after | change | p |
|---|---:|---:|---:|---:|
| `count_words` median | 44,702 ns | 38,636 ns | −13.57 % | ≈1.1e-5 |

Complete separation of the two distributions (every after-round faster than
every before-round) is what made the p-value so small with n=10.

**Verdict.** KEEP, score 0.8643.

**Lesson.** The asm named the operation (`call` to allocator), and the fix
removed exactly that operation.

---

## 2. Bounds check that may or may not exist

**Symptom.** "Index loop is slow." No profile yet.

**Code.**

```rust
fn count_above(values: &[u32], threshold: u32) -> usize {
    let mut count = 0;
    for i in 0..values.len() {
        if values[i] > threshold { count += 1; }
    }
    count
}
```

**Step 1 — look, do not assume.**

```bash
cargo asm --lib --rust 'krate::count_above'
```

Outcomes:

- `cmp rdx, rcx` + `jae .panic_bounds_check` in the loop → the check executes.
- No panic path, a single loop over `[rdi, rdi+len*4)` → LLVM proved the bound;
  changing the source will not help.

**Step 2 — safe rewrite regardless.**

```rust
fn count_above(values: &[u32], threshold: u32) -> usize {
    values.iter().filter(|&&v| v > threshold).count()
}
```

**Step 3 — check the asm again.** Often byte-identical. If identical, there is
nothing to keep: revert, because the diff buys nothing.

**Step 4 — if the check is real and the loop is hot**, the ladder is:
`for x in slice` → pre-truncated slice → `chunks_exact` → hoisted `assert!` →
(only with a written proof and Miri) `get_unchecked`.

**Lesson.** The guide's own practicum says the same: a difference in source
shape is not a difference in machine code. Check, then measure.

---

## 3. `clone()` on a lookup key

```rust
// before
fn lookup(map: &HashMap<String, usize>, key: &str) -> Option<usize> {
    map.get(&key.to_owned()).copied()
}
// after
fn lookup(map: &HashMap<String, usize>, key: &str) -> Option<usize> {
    map.get(key).copied()
}
```

**Asm before:** `call alloc`, `memcpy` (short), `call HashMap::get`, `call
dealloc`. **After:** only the `get`.

**Contract.** `Borrow<str>` for `String` keys is part of std; results are
identical.

**When it does not show:** a single lookup per request is invisible; only a
hot lookup path shows a win. Measure the path, not the function in isolation.

---

## 4. `Vec::remove(0)` in a loop

```rust
// before: O(n²) — every remove shifts the whole tail
while !queue.is_empty() { result += u64::from(queue.remove(0)); }
// after: O(n)
while let Some(v) = queue.pop_front() { result += u64::from(v); }
```

**Asm before:** `memmove` inside the loop, size proportional to remaining
length. **After:** pointer bump + occasional wrap.

**Simpler still:** if you only traverse once,
`values.iter().map(|&x| u64::from(x)).sum()` allocates nothing at all. Prefer
the smallest structural change that removes the work.

**Contract.** Same order, same values.

---

## 5. Intermediate `collect()` and early exit

```rust
// before: builds a Vec, counts all matches
values.iter().filter(|&&x| x == target).count() != 0
// after: stops at the first match
values.contains(&target)
```

**Why it matters.** The cost model changes from O(n) with an allocation to
O(position of first match). On a large input with an early hit this is
structural, not micro.

**Contract.** For plain `u32` identical. For a type whose `PartialEq` has side
effects, the number of comparisons changes — declare it.

---

## 6. Branch prediction: `sort_unstable` vs `sort`

A classic story says sorting first makes a later `if` branch predictable and
therefore faster. It is true on some distributions and sizes, false on others,
and it **changes the ordering contract** (`sort_unstable` may reorder equals).

Rules:

- The transformation is a contract change; only apply with permission.
- Measure at the sizes you actually run; the win often needs n in the
  thousands and a near-50/50 branch.
- On modern CPUs with good predictors, the branchless rewrite can be slower
  because it computes both sides.

---

## 7. Independent accumulators (unrolling)

```rust
fn sum_u64(data: &[u64]) -> u64 {
    let mut a = 0u64;
    let mut b = 0u64;
    for pair in data.chunks_exact(2) {
        a = a.wrapping_add(pair[0]);
        b = b.wrapping_add(pair[1]);
    }
    let mut total = a.wrapping_add(b);
    if let [last] = data.chunks_exact(2).remainder() {
        total = total.wrapping_add(*last);
    }
    total
}
```

**When it helps:** the loop is bound by the latency of a single dependent
`add` chain (visible in `llvm-mca` as a long dependency chain, or in asm as one
accumulator register).

**When it does not:** the loop is memory-bound (most large sums are). Then the
extra registers buy nothing.

**Contract.** `wrapping_add` preserves modulo-2^64 semantics exactly. Never do
this to `f64` without declaring a tolerance.

**Test sizes.** 0, 1, 2, 3, 16, 17, 1e6 and 1e6+1 — the tail is where these
rewrites break.

---

## 8. Allocation fix that is slower on small inputs (measured)

A real run on a 2 000-word corpus, 47 KB input, 20 000 word tokens:

**Before** (allocates per character and per word):

```rust
let mut word = String::new();
for c in field.chars() {
    if c.is_ascii_alphanumeric() { word = word + &c.to_string(); }
}
*counts.entry(word).or_insert(0) += 1;
```

**After** (one scratch buffer, borrow on lookup):

```rust
let mut word = String::new();
for field in s.split_whitespace() {
    word.clear();
    for c in field.chars() {
        if c.is_ascii_alphanumeric() { word.push(c.to_ascii_lowercase()); }
    }
    if !word.is_empty() {
        if let Some(count) = counts.get_mut(word.as_str()) { *count += 1; }
        else { counts.insert(word.clone(), 1); }
    }
}
```

Measured (criterion, 4 interleaved ABBA rounds, medians):

| | before | after | delta |
|---|---:|---:|---:|
| `count_words` | 1.426 ms | 0.985 ms | **−30.9 %** |
| instructions (perf stat, CLI) | 286.6 M | 199.8 M | −30.3 % |
| allocations per call | 94 003 | 13 | ~7 200× |
| CLI wall time (hyperfine) | 38.1 ms | 27.6 ms | −27 % |

asm evidence: the loop loses `call __rust_alloc_shim` and
`call ...do_reserve_and_handle` per accepted character; only the cold
capacity-overflow branch keeps a call.

**The honest cost — and why the small-N sweep matters:**

| input | old | new | ratio |
|---|---:|---:|---:|
| empty | 0.044 µs | 0.046 µs | 0.96× |
| 2 words | 0.211 µs | 0.237 µs | 0.89× |
| 10 words | 1.078 µs | 1.204 µs | 0.90× |
| 1 k lines (47 KB) | 672.6 µs | 414.3 µs | 1.62× |
| 100 k lines (4.7 MB) | 68.8 ms | 47.7 ms | 1.44× |
| one 1 MB word | 4.9 ms | 4.3 ms | 1.15× |

Below ~10 words the rewrite is 4–13 % **slower**: a map *miss* now hashes
twice (`get_mut` then `insert`) while `entry` hashed once, and at that size
hashing dominates, not allocation. Above roughly one word per 10 bytes it
wins clearly.

**Lessons for the skill:**

- `entry` → `get_mut` + `insert` trades one hash for one allocation; it is a
  win only when allocation is the cost. Both are correct; measure.
- The small-N table is not optional — it is where the new failure mode lives.
- Reject the sibling idea (`sum_above` rewrite) when the asm diff is empty:
  byte-identical code cannot be faster, whatever the number says.
- Static code can grow while dynamic work falls (457 → 540 instructions,
  −30 % executed); count instructions at runtime, not in the listing.

---

## 9. False sharing: large wall-clock effect, unproven HITM (measured)

Case: four independent `AtomicU64` counters, one per thread, 5M `fetch_add`
each. `dense` keeps them adjacent in one `Vec`; `padded` puts each in
`#[repr(align(64))]`.

| variant | wall time (6 runs, ABBA, `taskset -c 4-7`) |
|---|---|
| dense | 337, 380, 382, 389, 340, 387 ms |
| padded | 34.5, 35.5, 38.8, 54.4, 33.9, 33.9 ms |

About 7–11×. What this proves and does not:

- It proves a large runtime effect of the memory layout on this CPU.
- It does **not** by itself prove false sharing rather than true sharing:
  `perf c2c` is denied here, so there are no HITM counts, no offsets and no
  per-instruction attribution. Say "consistent with false sharing" unless you
  have the address/offset evidence.
- 64 B is an x86-64 assumption. On another CPU the line size and the padding
  that helps will differ.

Lesson for reports: a huge wall-clock delta is still a result, but label the
missing evidence instead of upgrading a hypothesis to a cause.

## 10. Reporting template for any of the above

```text
DIAGNOSIS    perf: count_words 92% of samples; asm: 3 allocator calls per char
CONTRACT     identical output for identical input; no API change
HYPOTHESIS   with_capacity + push removes alloc/memcpy/dealloc per char
PATCH        one function, 6 lines
CORRECTNESS  cargo test (12 tests) + edge cases: empty, 1 word, unicode
BENCHMARK    hyperfine/criterion, 10 interleaved rounds, median 44702 -> 38636 ns
ASSEMBLY     allocator calls gone from the loop; body is load/cmp/store
DECISION     keep, score 0.8643
COST         none measurable (same API, same tests, same binary size +/- 0)
```
