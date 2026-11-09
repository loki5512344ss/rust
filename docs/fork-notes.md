# Fork notes

This fork (`loki5512344ss/rust`) keeps the upstream harness intact and adds a
much larger, self-contained agent skill plus a Russian reference guide. The
goal is one workflow: **measure → localize in a profile → explain in asm →
patch one thing → prove correctness and speed**.

## What is added on top of upstream

| Path | What it is |
|---|---|
| `skills/autor3search-rust/SKILL.md` | rewritten skill: phases, iron rules, output contract |
| `skills/autor3search-rust/references/` | 8 lookup files (see below) |
| `docs/rust_guide.md` | Russian guide, edition 2026-11-09 (stable 1.99.1 / beta 1.100) |
| `docs/rust_perf_case/` | reproducible Cargo case: criterion bench, tests, ABBA bootstrap script |
| `scripts/install-skill.sh` | install/copy/link/uninstall into local agent harnesses |
| `scripts/bench-ab.sh` | interleaved A/B benchmark wrapper (hyperfine) |
| `scripts/asm-report.sh` | before/after asm dump for one function (`cargo asm`) |
| `scripts/perf-report.sh` | `perf stat` + `record` + `annotate` evidence bundle |

Nothing in `src/` is modified: upstream's gates, scoring and CLI behave
exactly as documented upstream.

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
| `optimization-catalog.md` | 363 techniques with priority and a "when it hurts" column |
| `semantics-traps.md` | contract classes, forbidden transformations, floats, `unsafe` checklist, Miri/Loom/fuzz |
| `diagnostics.md` | symptom → instrument → likely cause |
| `examples.md` | worked before/after with measurement and asm |

Key design choices:

- **The harness measures; the agent proposes.** One hypothesis, one minimal
  patch, one measurement, one verdict.
- **asm is evidence, not decoration.** The skill requires mapping profile
  samples to instructions before claiming a cause.
- **The harness only reads criterion.** `hyperfine` proves a CLI-level win by
  hand but cannot feed `eval`; adding a bench target is a `Cargo.toml` change
  and therefore a locked-file, human decision.
- **No `unsafe` as an optimization.** The harness has no unsafe gate (verified
  in `src/`), so the skill forbids it unless the whole safety checklist is
  satisfied.

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
