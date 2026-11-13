# Reading asm to explain *why* Rust is slow

Purpose: when a profile says "this function is 40% of time", the disassembly
says *which operation* is burning it. Without this step you are guessing at
Rust style; with it you are removing a specific instruction, cache miss, or
dependency chain.

**Rule zero:** presence of an instruction is not proof of cost. One `idiv` in
a cold error path is free; one `idiv` per element in a hot loop is a
catastrophe. Cost = instruction cost × execution frequency × dependency
depth. Frequency comes from `perf annotate` samples, not from counting lines.

## 1. Inventory on this machine

| Tool | Command | Use |
|---|---|---|
| `cargo asm` (cargo-show-asm) | `cargo asm --lib 'crate::f'` | per-function asm, no linker noise |
| `objdump` | `objdump -d -C --no-show-raw-insn bin` | final linked binary, real layout |
| `nm` | `nm -C bin \| grep f` | find the mangled symbol |
| `llvm-objdump` | `llvm-objdump -d --demangle bin` | LLVM-flavored disassembly |
| `llvm-mca` | `llvm-mca -mcpu=native loop.s` | port pressure / dependency math |
| `perf` | `perf annotate --stdio -s sym` | samples per instruction |
| `rustc` | `--emit=mir,llvm-ir,asm` | compiler-internal layers |

Nothing here needs nightly.

## 2. Getting the code out

```bash
# One function, with Rust source lines interleaved
cargo asm --lib --rust 'my_crate::parser::parse_line'   # --lib, --bin NAME, --bench NAME
cargo asm --bin app 'my_crate::parser::parse_line'      # binary target
cargo asm --lib                                          # list available symbols

# Whole binary, symbols preserved
objdump -d -C --no-show-raw-insn target/release/app > app.asm
nm -C --defined-only target/release/app | grep -E 'parse_line|process_event'

# Compiler layers (MIR -> LLVM IR -> asm)
cargo rustc --release --bin app -- --emit=mir,llvm-ir,asm
ls target/release/deps/*.mir target/release/deps/*.ll

# Single file, no cargo
rustc --edition=2024 -C opt-level=3 --crate-type=lib --emit=mir,llvm-ir,asm x.rs

# Line attribution for perf (does not change codegen)
RUSTFLAGS='-C debuginfo=1 -C force-frame-pointers=yes' cargo build --release
```

Caveats that change conclusions:

- `.s` from `--emit=asm` is **before** linking/LTO; the final ELF may differ.
  Compare final binaries when the question is "what actually runs".
- MIR text format is not a stable API across rustc versions.
- Fully inlined functions have no symbol — inspect the caller and use
  line-level attribution.
- `alloca` in LLVM IR is not necessarily a heap or stack allocation in the
  final code; SROA/mem2reg remove most of them.

## 3. What each layer answers

| Layer | Look for | Means |
|---|---|---|
| MIR | extra `Clone`, temp collection, `drop`, `assert` | the *source-level* work Rust scheduled |
| LLVM IR | `load`/`store` density, `memcpy`, `call` vs inlined | whether the optimizer removed the work |
| LLVM IR | `<4 x i64>`, `llvm.fmuladd` | vectorization intent (verify it reached asm) |
| asm | allocator `call`, `idiv`, `lock`, spills, bounds panic | what the CPU actually pays for |
| perf | which asm addresses own the samples | which of the above matters |

## 4. Instruction dictionary

| Group | Examples | What it does | Check |
|---|---|---|---|
| load/store | `mov`, `vmovdqu`, `vmovdqa` | move data | address pattern, size, cache/TLB misses |
| arithmetic | `add`, `sub`, `imul` | integer math | overflow semantics, dependency chain |
| division | `div`, `idiv` | quotient+remainder | frequency; can the algorithm avoid it |
| bit ops | `and`, `or`, `xor`, `shl`, `shr`, `sar` | masks/shifts | signedness, shift amount vs width |
| address math | `lea` | `base + index*scale + disp` | often arithmetic, not a memory access |
| compare | `cmp`, `test` | set flags | which `jcc`/`setcc`/`cmov` consumes them |
| jumps | `jmp`, `je`, `jne`, `ja`, `jl` | control flow | predictability, code density |
| branchless | `cmovcc`, `setcc` | select from flags | dependency chain; both sides computed |
| calls | `call`, `ret` | function entry/exit | calls left inside the hot loop |
| stack | `push`, `pop`, `sub rsp`, `[rsp+N]` | frame, spills | spills = register pressure |
| atomics | `lock add`, `lock cmpxchg`, `xchg` | cross-core sync | contention, cache-line bouncing |
| SIMD int | `vpaddd`, `vpaddq`, `vpshufb`, `vpcmpeqb` | packed integer | width, ISA, tail handling |
| SIMD float | `vaddps`, `vmulps`, `vfmadd*` | packed float/FMA | rounding, NaN, reassociation |
| ISA hygiene | `vzeroupper` | AVX→SSE transition | present on some generations |
| syscall | `syscall` | kernel entry | batching, buffering, count |

**Do not rank code by instruction count.** Out-of-order execution,
speculation, and µop fusion mean a 200-instruction loop can beat a 50
instruction one whose every instruction waits on a cache miss.

## 5. Rust idioms → asm signatures

| You see | Likely Rust source | Fix direction |
|---|---|---|
| `call ...alloc` / `__rust_alloc` in the loop | `String::new`, `to_string`, `format!`, `Vec::push` past capacity | `with_capacity`, reuse buffer, borrow `&str` |
| `call ...memcpy` with big size | `clone()`, slice copy, `collect()` | borrow, `Cow`, move instead of copy |
| `cmp` + `jae` + `call panic_bounds_check` | indexing `v[i]` | iterators, `chunks_exact`, pre-truncated slice, hoisted len |
| `idiv` / `div` | `%`, `/` on runtime values | bitmask for power of two, avoid per-element division, magic constants |
| `lock` prefix in a loop | `Atomic*` update per iteration | batch, relax ordering, per-thread accumulator |
| `mov [rsp+..], reg` repeated | register spills | smaller live set, split function, avoid huge inlined body |
| `cmov` chain feeding another `cmov` | branchless `min`/`max`/`abs` chains | let the branch exist if predictable; break the chain |
| `vzeroupper` before a call | mixed AVX/SSE (often unavoidable) | usually ignore; it is one cheap instruction |
| no `v*` instructions in a numeric loop | autovectorization failed | remove branches from loop body, `chunks_exact`, aliasing hints, `#[repr(C)]` |
| loop with `movzx`/`mov` per byte | byte-at-a-time parse | `memchr`, `chunks_exact`, SWAR, SIMD |

## 6. Bounds checks: the safe ladder

Do these in order, and only continue while the profile still shows the check:

1. `for x in &v` / `for (i, x) in v.iter().enumerate()` instead of `v[i]`.
2. Slice once: `let tail = &v[..n];` then index `tail[..k]` where LLVM can
   prove `k <= n`.
3. `chunks_exact(4)` / `windows` / `split_at` to carry the proof in the type.
4. `assert!(i < v.len())` hoisted outside the loop — LLVM uses the invariant.
5. Only then discuss `get_unchecked`, and only with a written proof that every
   caller satisfies the invariant, plus tests for empty/short inputs.

`get_unchecked` passes every test that happens to cover the tested inputs.
That is exactly why it is the most expensive "optimization" in this list.

## 7. Divisions and remainders

- Constant divisor: LLVM already emits multiply-shift ("magic number"). Manual
  `x & (m-1)` only helps when `m` is a power of two and unsigned — and LLVM
  usually knows that too.
- Runtime divisor in a hot loop: the fix is algorithmic (bucket by divisor,
  precompute reciprocals, restructure to avoid per-element `%`).
- `div` cost varies by microarchitecture and operand width; measure, do not
  quote cycle counts.

## 8. SIMD reality check

1. First make the loop autovectorizable: no data-dependent branches, no early
   exit, contiguous access, `chunks_exact` for the body + explicit tail.
2. Verify in asm that `v*` packed instructions appear; if not, look at LLVM IR
   for scalar `load`/`fmul` or `call` (a non-inlined helper kills
   vectorization).
3. `-C target-cpu=native` changes what is legal — it is a locked file change
   for the harness and a deployment decision for humans.
4. Always benchmark tails: `n = 0,1,2,3,15,16,17` and a large odd size.
5. `f32`/`f64` reassociation changes bits. Define tolerance before you
   vectorize a reduction.

## 9. `llvm-mca` — static scheduling estimate

```bash
llvm-mca -mcpu=native -iterations=100 -timeline hot_loop.s
```

Answers: which port is saturated, how long the dependency chain is, whether
throughput or latency binds. Does **not** model cache residency, OS noise, or
real branch behavior. Use it to explain a `perf` finding, never to replace
one.

## 10. Before/after discipline

```bash
# identical flags, clean target dir for both sides
cp target/release/app app.before
# ... apply patch ...
cp target/release/app app.after
sha256sum app.before app.after
perf stat -r 7 -- ./app.before input.bin
perf stat -r 7 -- ./app.after  input.bin
diff -u before.s after.s | head -100
```

If the asm is byte-identical, the "optimization" did not happen — you changed
style, not code. If the asm changed but the time did not, you moved work
around instead of removing it.

## 11. Common misreadings

| Misreading | Reality |
|---|---|
| "more instructions = slower" | OoO execution; count samples, not lines |
| "`cmov` is always faster than a branch" | cmov computes both sides and serializes |
| "`lea` is a memory load" | it is three-component address arithmetic |
| "`unsafe` removed the check, so it is faster" | maybe not measurable; UB risk is permanent |
| "AVX2 exists, therefore 4×" | memory bandwidth, tails, and frequency say no |
| "the loop disappeared" | optimizer folded it; the benchmark measures nothing |
| "IR has `<4 x i64>`, so SIMD shipped" | check the final asm |

## 12. Checklist before you claim an asm-level diagnosis

- [ ] Symbol identified from `perf report`, not guessed from source.
- [ ] Sample addresses mapped to a Rust line (`--rust`, debug info).
- [ ] Dominant instructions named and their execution frequency estimated.
- [ ] Bottleneck classified: compute / memory / branch / contention / syscall.
- [ ] Hypothesis written as "removing operation X will remove instructions Y".
- [ ] Safe alternative tried before `unsafe`.
- [ ] Before/after asm diff attached to the report.
