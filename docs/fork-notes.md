# Fork notes

This fork (`loki5512344ss/rust`) adds a much larger, self-contained agent skill
and a Russian reference guide, and — since 2026-11-12 — two changes to the
harness itself (see "Harness changes"). The
goal is one workflow: **measure → localize in a profile → explain in asm →
patch one thing → prove correctness and speed**.

## What is added on top of upstream

| Path | What it is |
|---|---|
| `skills/autor3search-rust/SKILL.md` | rewritten skill: phases, iron rules, output contract |
| `skills/autor3search-rust/references/` | 9 lookup files (see below) |
| `docs/rust_guide.md` | Russian guide, edition 2026-11-09 with Top-Down/`perf mem`/`perf c2c` and the nine-video audit |
| `docs/rust_video_audit.md` | the full audit behind guide §47 (source claims, what was and was not verified) |
| `docs/rust_perf_case/` | reproducible Cargo case: criterion bench, tests, ABBA bootstrap script, false-sharing example |
| `scripts/install-skill.sh` | install/copy/link/uninstall into local agent harnesses |
| `scripts/bench-ab.sh` | interleaved A/B benchmark wrapper (hyperfine) |
| `scripts/instr-count.sh` | A/B by `perf stat` instruction counts, interleaved |
| `scripts/layout-check.sh` | does a small win survive a change in environment size |
| `scripts/vec-remarks.sh` | LLVM remarks on why a loop was or was not vectorized |
| `scripts/perf-diff.sh` | `perf diff` of two flat profiles, honest refusal without `perf record` |
| `scripts/diff-fuzz.sh` | differential-fuzz scaffold, old function vs new, no dependencies |
| `scripts/asm-report.sh` | before/after asm dump for one function (`cargo asm`) |
| `scripts/perf-report.sh` | `perf stat` + `record` + `annotate` evidence bundle |

## Harness changes (2026-11-12)

Until this date nothing in `src/` was modified. Two additions now make the
fork's binary differ from upstream 0.2.1; scoring and every existing gate are
untouched.

| Change | Where | Effect |
|---|---|---|
| unsafe gate | `src/unsafe_gate.rs`, `src/pipeline.rs` step 3b, `Reason::UnsafeAdded` | an experiment that adds or changes an `unsafe` region relative to the baseline commit is `FAIL(unsafe_added)` before the build |
| `allow_unsafe` | `src/config.rs` | human-only switch for the gate; default `false`, omitted from a written config while `false`, so existing configs keep their hash |
| per-benchmark rows | `src/bin/autor3search-rust/cmd_eval.rs` | `eval --json` gains `benchmarks` (name, medians, `pct_change`, `p`, thresholds) whenever measurement ran; the text output prints name, medians, `pct_change` and `p`, but not `keep_threshold_p`/`n_base`/`n_cand` |
| `gitx::file_at` | `src/gitx.rs` | reads a file as of a commit, for the gate |

Why the gate works on tokens and what it cannot see is written at the top of
`src/unsafe_gate.rs`. Tests: 18 unit tests in that module, 6 gate tests in
`tests/pipeline_gates.rs`, and the two real-benchmark tests in
`tests/cmd_eval.rs` (`--ignored`) assert the `benchmarks` rows on KEEP and on
DISCARD.

Instruction counts are deliberately **not** an `eval` gate: `perf stat` works
here, but the score must stay one wall-clock number that means the same thing
on every host, and a PMU counter is absent on many VMs and CI runners. Counters
are evidence for *detecting* a change (`scripts/instr-count.sh`), not for
accepting one.

Consequences: `cargo install autor3search-rust` installs **upstream**, without
either change — build this checkout (`cargo install --path .`) to get them;
and merges from upstream can now conflict in `pipeline.rs`, `verdict.rs`,
`config.rs`, `cmd_eval.rs` and `templates/program.md`.

## The skill

Upstream ships a 55-line skill that inlines the README "Start here" prompt.
It works, but the agent still has to fetch the README to learn the flags,
the verdict JSON shape, the scoring math and the known gaps.

This fork replaces it with:

| Reference | Read it when |
|---|---|
| `asm-reading.md` | you must explain *why* from machine code: symbol → samples → instruction → Rust line |
| `measurement.md` | designing a benchmark: hyperfine, criterion, ABBA, timers, statistics, invalidators |
| `profiling.md` | `perf stat`/`record`/`annotate`, samply, flame graphs, `perf c2c`/`mem`, allocations, async/off-CPU |
| `harness-cli.md` | driving the harness: commands, config schema, gate order, verdict JSON, scoring, what it does not protect |
| `optimization-catalog.md` | 303 distinct techniques with priority and a "when it hurts" column (was 363 rows before duplicates were merged) |
| `semantics-traps.md` | contract classes, forbidden transformations, floats, `unsafe` checklist, Miri/Loom/fuzz |
| `diagnostics.md` | symptom → instrument → likely cause |
| `examples.md` | worked before/after with measurement and asm |
| `experimentation.md` | multi-variant "rewrite it several ways" experiments, with a log of proven methods |

Key design choices:

- **The harness measures; the agent proposes.** One hypothesis, one minimal
  patch, one measurement, one verdict.
- **asm is evidence, not decoration.** The skill requires mapping profile
  samples to instructions before claiming a cause.
- **The harness only reads criterion.** `hyperfine` proves a CLI-level win by
  hand but cannot feed `eval`; adding a bench target is a `Cargo.toml` change
  and therefore a locked-file, human decision.
- **No `unsafe` as an optimization.** This fork's harness refuses an
  experiment that adds or changes an `unsafe` region; upstream's has no gate
  (verified in `src/`). The skill forbids `unsafe` either way unless the whole
  safety checklist is satisfied.

### Validation

The skill was tested A/B on a small crate with a deliberately quadratic
`count_words` and a bounds-checked `sum_above`:

| | without skill | with skill |
|---|---|---|
| profiling | none | `perf stat` + `--emit=asm` + counting allocator |
| change | 3 ideas at once, ~200-line custom hash table | 1 idea, 6 lines |
| evidence | criterion + hyperfine | 200 226 differential inputs, ABBA, small-N sweep |
| rejected idea | — | `sum_above` rewrite: asm byte-identical |
| result | ~3× but a new data structure to maintain | −31 %, −30 % instructions, ~7 200× fewer allocations |

The measured case is written up in `skills/autor3search-rust/references/examples.md` §8.

## The 2026-11-09 second edition (Top-Down / c2c / video audit)

The upstream guide was reissued with:

- `§31.6–31.8`: Top-Down L1/L2 (slots, not time), `perf mem` (use-latency,
  AMD IBS / arm64 SPE), `perf c2c` and the true-sharing vs false-sharing
  distinction (HITM is a signal, not proof).
- `§42.2.1`: paired bootstrap / Wilcoxon / Mann–Whitney / Bonferroni / Holm
  matrix, and `analyze_abba.py` now applies a Bonferroni correction across CSV
  scenarios by default.
- `§47`: an audit of nine videos, with a `hyperfine → samply → DHAT` workflow,
  build-time notes (`debug = "line-tables-only"`, nightly `-Zthreads`,
  Cranelift) and an explicit list of claims not to copy.
- `examples/false_sharing.rs` and the audit file `Rust_Video_Audit_9_Files.md`.

Fork adjustments on top of that edition:

- the two corrections above were lost in the reissue and are re-applied;
- `RESULTS.md` stays a **measured** report (the reissue ships a `NOT MEASURED`
  template) and gains the false-sharing run: 4 threads, 5M increments each,
  `dense` 337–389 ms vs `padded` 34–54 ms (~7–11×), wall-clock only because
  `perf c2c` is denied here;
- the header no longer claims "no rustc in the editing environment";
- `analyze_abba.py` and the example were actually compiled/run, and the guide
  says which claims remain unverified;
- the skill gained an **experiment mode** (`references/experimentation.md`) and
  the statistics/subsection in `measurement.md`, plus the HITM caveat in
  `profiling.md`.

## Harness end-to-end

`autor3search-rust 0.2.1` was run on a copy of `docs/rust_perf_case` in its own
git repository: `init` → `doctor` → `baseline` → patch → `eval --json`. Both
verdict paths were exercised: `DISCARD` (score 0.9920, −0.80 %) and `KEEP`
(score 0.9497, −5.03 %). Details in `docs/rust_perf_case/RESULTS.md`.

## Installing the skill

```bash
bash scripts/install-skill.sh            # copy into OpenCode, Codex, Claude Code, ~/.agents
bash scripts/install-skill.sh --link     # symlink to this checkout (git pull updates it)
bash scripts/install-skill.sh --uninstall
```

Copy is the default: a half-updated checkout should not silently change what
an unattended agent does.

The `~/.agents/skills/autor3search-rust` copy installed by the `skills` CLI
(`~/.agents/.skill-lock.json`) is overwritten by the script. Its lock entry
still points at `autor3search/rust`; updating it through the CLI will restore
the upstream thin version, so re-run this script afterwards.

## Corrections applied to the guide

The guide is the edition of 2026-11-09 (stable 1.99.1, MSRV matrix in §39,
beta/nightly watchlist in §40, Miri/fuzzing in §41, statistics in §42,
reproducible case in §43, async p99 in §44, CI in §45). Its own §46 lists the
editorial audit. Two fixes remain fork-only because that edition still has
them:

- §29.1 called `-C force-frame-pointers=yes` "release without changing
  optimizations". Frame pointers change codegen (a reserved register,
  prologue/epilogue, register pressure), so it is a profiling build, not the
  shipping binary; absolute numbers do not transfer.
- §2 used `perf record -g` on a release build with no frame pointers (stacks
  get truncated); now suggests `--call-graph dwarf` or the §29.1 build.

Earlier editions had errors that the 2026-11-09 edition already corrected
(kept here for the record):

- `Vec<bool>` is **not** bit-packed in Rust (`size_of::<bool>() == 1`).
- Haswell L1D is **32 KiB**, so a "64 KiB read from L1" example is impossible.
- MSRV notes for `first_chunk` (1.77), `as_chunks` (1.88), `as_array` (1.93),
  `LazyLock` (1.80), unsafe attributes (1.82), edition 2024 (1.85).
- §19.17 compared functions with different return types without flagging the
  signature change.
- §28.3 did not explain what `black_box` does and does not suppress.
- §24.1 sort-then-truncate lacks the `select_nth_unstable` / bounded-heap
  alternatives.

## Updating from upstream

```bash
git fetch upstream
git merge upstream/main     # or rebase
```

Conflicts are expected only in `skills/autor3search-rust/SKILL.md` (upstream
owns the thin version) and `README.md` if upstream changes it. The reference
files, scripts and `docs/rust_guide.md` are fork-only.
