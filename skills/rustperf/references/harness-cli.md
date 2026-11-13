# rustperf: driving the harness (verified against source, v0.3.0)

Everything below was checked against `src/` in the fork, not copied from the
README. Where README and code disagree, this file follows the code and says so.

## 1. Commands and flags

| Command | Flags | Does |
|---|---|---|
| `init` | `-C`, `--force` | discovers criterion benches, writes `.rustperf/config.yaml` + `program.md`, gitignores run artifacts |
| `doctor` | `-C` | machine fitness report; **always exits 0**, gates nothing |
| `baseline --tag <t>` | `-C`, `--tag`, `--force` | creates run branch, freezes `tests/**`+`benches/**`, hashes inline tests + locked files, pins measurement worktree |
| `eval` | `-C`, `--json`, `--desc <text>`, `--no-log` | one experiment: gates → build → test → measure → verdict → one `results.tsv` row |
| `status` | `-C`, `--tag` | read-only run state |
| `stop` | `-C`, `--tag`, `--clear`, `--force` | graceful stop request; `--clear` cancels; `--force` aborts the in-flight eval |
| `report` | `-C` | counts + cumulative speedup from `results.tsv` |
| `profile` | `-C`, `--tag` | samply samples of the declared benches; needs `samply` |
| `version` | — | binary version/commit |

Parser quirks: single-dash long flags are refused (`-force` is an error);
`--flag=value` works for value flags; `--force=false` is an error; repeated
flags last-wins; unknown positionals are silently ignored; `-C <dir>` is
accepted by every command.

## 2. Exit codes

| Code | Meaning |
|---|---|
| 0 | KEEP |
| 1 | DISCARD |
| 2 | FAIL **or** ABORTED **or** harness malfunction |
| 3 | CRASH (build failure / timeout) |
| 64 | usage error (undocumented in README) |

`2` is overloaded: a gate failure writes a row, a harness malfunction writes
none. Distinguish by whether a new `results.tsv` row appeared.

## 3. `.rustperf/config.yaml`

`deny_unknown_fields` — a typo'd key is a hard error. All keys optional.

| Key | Default | Notes |
|---|---|---|
| `benchmarks` | `[]` | explicit criterion ids; empty = all discovered. Read only at `baseline` |
| `bench_targets` | `[]` | `{package, target}` pairs |
| `scope` | `["src/**"]` | writable globs; `./...` → `**`; `*` does not cross `/` |
| `count` | `10` | rounds per side; **must be ≥ 4** (below that no rank test can hit p<0.05) |
| `sample_size` | `50` | criterion `--sample-size`; ≥ 10 |
| `measurement_time` | `"2s"` | Go-style duration, unit required |
| `warm_up_time` | `"1s"` | same |
| `max_regress_pct` | `5.0` | regression guard threshold |
| `min_effect_pct` | `1.0` | KEEP requires score `< 1 - min_effect_pct/100` (strict) |
| `timeout` | `"15m"` | per cargo subprocess phase |
| `unfreeze` | `[]` | test files exempt from freezing (human-only) |
| `allow_unsafe` | `false` | **fork addition.** `true` switches the unsafe gate off (human-only). Omitted from a written config while `false` |

The file is hashed at `baseline`; any edit → `FAIL(config_changed)`. It is
never the agent's to edit, even though it lives in the repo.

## 4. Gate order in `eval`

1. Stop requested already? → `ABORTED(stop_forced)`, no row.
2. Scope gate over `git diff + git status` → `FAIL(scope_violation)`.
   `results.tsv`, `run.log`, config, `tests/**`, `benches/**` are skipped.
3. Locked files re-stat'd from disk (`Cargo.toml`, `Cargo.lock`,
   `.cargo/config[.toml]`, `rust-toolchain[.toml]`, any depth) →
   `FAIL(scope_violation)` on add/remove/change.
4. Config hash → `FAIL(config_changed)`.
4b. **Unsafe gate (fork addition).** Every changed `.rs` file outside
    `tests/`/`benches/` is tokenized, baseline commit vs disk. An `unsafe`
    region — block, `unsafe fn` with its body, `unsafe impl`/`trait`/`extern`,
    `#[unsafe(..)]` — that the baseline did not contain token for token →
    `FAIL(unsafe_added)`, with `file:line` in the message. Runs before the
    build. Removing, moving or reformatting unsafe code passes; comments and
    string contents are ignored; macro bodies are scanned.
5. Restore frozen tests from the state store → `FAIL(symlink_swap)`,
   `FAIL(frozen_store_tampered)`.
6. Inline `#[cfg(test)]` + doctest token hashes → `FAIL(inline_test_modified)`.
7. Unknown test file on disk → `FAIL(new_test_file)`; vanished → `FAIL(missing_test_file)`.
8. `cargo build --release --all-targets --workspace` → `CRASH(build_failed|timeout)`.
9. `cargo test --workspace` in **debug** (overflow checks and `debug_assert!`
   live) → `FAIL(tests_failed|timeout)`.
10. Baseline worktree `HEAD` == recorded `measure_commit` → `FAIL(baseline_tampered)`.
11. Interleaved measurement, `count` rounds + 1 discarded warmup, side order
    swapped each round.
12. Score + decision.
13. On KEEP only: advance the measurement worktree to the candidate commit.

## 5. `eval --json` — the real shape

```json
{
  "status": "KEEP",
  "reason": "improved",
  "score": 0.8643,
  "message": "...",
  "stop_requested": false,
  "run": {
    "tag": "sep6",
    "branch": "rustperf/sep6",
    "baseline_commit": "a3f1c2d",
    "measure_commit": "9b7e410",
    "worktree": "/…/baseline-worktree",
    "experiment": 5
  }
}
```

Facts that bite:

- `regressions` and `warnings` are **omitted when empty** (`skip_serializing_if`).
  A parser must not require them.
- **Fork addition:** whenever measurement ran (KEEP and DISCARD), the object
  carries `benchmarks`: one row per benchmark with `name`, `base_ns`,
  `cand_ns` (medians), `pct_change`, `p`, `significant` (raw alpha),
  `keep_threshold_p` (`alpha/k`, the bar a KEEP needs), `n_base`, `n_cand`.
  Absent on FAIL/CRASH/ABORTED — nothing was measured. Use it to tell "one
  benchmark moved 8 %" from "everything moved 1 %". Upstream 0.2.1 has no
  such key; `results.tsv` still carries only `best_bench_delta`.
- `run.experiment` on `ABORTED` is the pre-existing row count (no row written).
- Score `0.0` for any gate failure or ABORTED.

## 6. Scoring (exact)

```
score = exp( (1/k) * Σ ln(cand_median_i / base_median_i) )   # geomean
```

Decision:

1. Any `p < 0.05` (raw, **uncorrected**) regression with
   `pct_change > max_regress_pct` → `DISCARD(guard_regression)`.
2. `improved = any(pct_change < 0 && p < alpha/k)` — Bonferroni over the
   number of benchmarks compared.
3. `score < 1 - min_effect_pct/100` **and** `improved` → `KEEP(improved)`.
   Strict inequality: 0.99 at the 1 % default is a DISCARD.
4. `improved` but score ≥ threshold → `DISCARD(improvement_below_min_effect)`.
5. otherwise → `DISCARD(no_significant_improvement)`.

Mann-Whitney: exact test when both sides ≤ 20 and no ties; otherwise normal
approximation with continuity + tie correction (warning emitted). With `k`
benchmarks the p floor is `alpha/k`, so `count=4` may be structurally unable to
KEEP — the harness warns rather than errors.

## 7. `results.tsv`

```
commit  score  best_bench_delta  status  description
```

`score` 4 dp, `best_bench_delta` 2 dp (percent, most-negative delta), status
one of `KEEP|DISCARD|FAIL|CRASH` (ABORTED never written), description
whitespace-flattened and truncated to 256 chars. Written by `eval` only,
`fsync` per row. The loader is strict: one malformed line makes every later
`eval` exit 2 before doing anything. **Never touch this file.**

## 8. State location

`<state_home>/<sha256(canonical repo path)[0..16]>/<tag>/` where
`<state_home>` = `$RUSTPERF_STATE_HOME` (must be absolute) or
`~/.cache/rustperf`. Holds `baseline.json`, `baseline-worktree/`,
`frozen/` + manifest, per-round criterion homes, profiles, `stop`, `eval.pid`.

The key is derivable from the repo path, so "outside the repo" is not
"inaccessible": it is only tamper-*detected* (HEAD movement, store hashes).
Do not touch it. A human may set the env var for containers.

## 9. Preconditions and refusals

- `baseline` refuses a dirty tree and a reused tag. `--force` does **not**
  bypass the tag collision; it only skips a `results.tsv` precondition.
- `init` refuses to overwrite an existing config without `--force`, but
  **always overwrites `program.md`** — human edits there are lost on re-run.
- Benchmarks are discovered only from `[[bench]] harness = false` in a
  package's `Cargo.toml`; criterion versions are recognized by the `--list`
  suffix (`": benchmark"` = 0.5+, `": bench"` = 0.3/0.4). A `criterion`
  dependency is never inspected.
- Zero benchmarks → `init` errors out (exit 2). There is no fallback runner.
- Each declared benchmark id must appear in **every** measurement round, or the
  experiment is `CRASH(build_failed)` naming the missing id.

## 10. What the harness does not protect against (code-verified)

1. **The unsafe gate (fork) is narrow.** It refuses new or changed `unsafe`
   regions. It does not see a *safe* edit that breaks the invariant an
   unchanged `unsafe` region relies on (deleting the bounds check in front of
   an existing `get_unchecked`), nor unsafe code reached through a dependency
   or a proc macro's output. Upstream 0.2.1 has no gate at all. Still review
   every kept diff that touches a file containing `unsafe`.
2. `results.tsv` and `run.log` are agent-writable (explicitly exempt from the
   scope gate). Forged rows corrupt `report`/`status`, not verdicts.
3. Baseline-worktree edits without a commit change no `HEAD`, so they are
   measured but undetected. Only `HEAD` movement trips gate 10.
4. Gate 1 is git-based: a **gitignored source file** can be edited invisibly
   (it is neither a locked shape nor hashed).
5. Freeze/restore covers only the **workspace root** `tests/**`/`benches/**`;
   member-crate test dirs are run but not frozen.
6. New in-scope source files never get their inline tests hashed. **Renaming**
   an existing source file fails with `FAIL(inline_test_modified)`: inline-test
   hashes are keyed by path and a missing path fails closed by design, so the
   rename would look like deleted tests. Split a file by extracting into a new
   module and keeping the old one.
7. No clippy, no Miri, no allocation metrics (median time only).
8. `doctor` gates nothing; a throttling laptop still produces verdicts.
9. The regression guard requires `p < 0.05`; a real 50 % regression measured
   with high variance can pass unnoticed.
10. `k` is fixed at baseline (config hash), so a repo with many benchmarks may
    be unable to KEEP at all — only a warning.
11. No grace-then-SIGKILL for `stop --force` (10 s, then it reports state).
12. `program.md` has no integrity check; it is the agent's instruction file,
    not a control.

## 11. program.md rules the driver must obey

- One change per experiment; commit before `eval`; `KEEP` keeps the commit,
  anything else → `git reset --hard HEAD~1`.
- Always pass `--desc "<idea>"`.
- Do not redirect/tee stdout of `eval --json`; it prints one JSON object.
- Print the context line before each experiment:
  `[exp <n> | <branch> | vs <measure_commit> | stop: rustperf stop]`
- `stop_requested: true` or `ABORTED` → apply the verdict, run `report`,
  summarize, exit the loop.
- Never edit `program.md`, `.rustperf/config.yaml`, `results.tsv`, or run
  state; never pass `--force` to any command.
- Do not stop on your own: running out of ideas is not a stop condition. The
  human stops with `rustperf stop`.

## 12. Known README/code discrepancies (do not trust the README here)

- `regressions: []` / `warnings: []` never appear (keys are omitted).
- README claims `eval` reports benchmarks "significant at alpha but not at
  alpha/k" — upstream does not; this fork's `benchmarks` rows expose
  `significant` (raw alpha) and `keep_threshold_p` (`alpha/k`), so the
  distinction is computable, but there is no dedicated flag for it.
- `program.md`'s reason list omits `symlink_swap`, `frozen_store_tampered`,
  `baseline_tampered` (it does list the fork's `unsafe_added`).
- Exit code `64` is undocumented; harness malfunction also returns `2`.
- `baseline --force` does not redo a tag.
- README overstates state-dir unreachability (key is a plain path hash).
