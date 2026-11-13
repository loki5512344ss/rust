#!/usr/bin/env bash
# vec-remarks.sh — ask LLVM why a loop was or was not vectorized, no asm needed.
#
# Verified on rustc 1.99.1 / cargo 1.99.1 (stable, x86_64 Linux), by experiment:
#   - `-C remark=loop-vectorize`, `-C remark=all` and several passes in one
#     value (`-C "remark=loop-vectorize slp-vectorizer"`) all work. rustc -C help
#     says: "space separated, or all".
#   - Remarks are printed by rustc to STDERR as level "note" diagnostics:
#       note: <file>:<line>:<col> <pass> (success|missed|analysis): <text>
#     success = applied; missed = generic "not done"; analysis = the reason
#     (e.g. "cannot prove it is safe to reorder floating-point operations").
#   - Without debuginfo rustc warns '-C remark requires "-C debuginfo=n" to
#     show source locations' and every location is "<unknown file>:0:0". With
#     `-C debuginfo=1` locations are real, so this script always passes it.
#   - With more than one codegen unit rustc prints NO loop-vectorize remarks
#     (checked: codegen-units=1 gives remarks, 2 and 16 give none, 16 being the
#     cargo release default). The script therefore passes -C codegen-units=1.
#     Consequence: this build can inline differently from your real profile;
#     use it to learn why a loop fails, then confirm in the real build's asm.
#   - The LLVM message carries no function name. Locations of loops written
#     with iterators often point into core/std (e.g. slice/iter/macros.rs),
#     because that is where the inlined loop body lives. --filter therefore
#     matches the whole line (path or mangled name), not a Rust function. To
#     analyse one function, build a crate/example that contains only it.
#   - A tiny non-generic `pub fn` in a lib is not compiled in that lib at all
#     (cross-crate inlining), so it yields no remarks; mark it
#     #[inline(never)] or analyse the bin/bench/example that calls it.
#   - `cargo rustc` does NOT show these notes: cargo swallows them, with
#     human and json message formats alike (checked). rustc's own stderr is
#     therefore captured through a RUSTC_WRAPPER that tees it to a file.
#   - Remarks appear only when the crate is actually recompiled; a cached
#     build prints nothing. A throwaway --cfg makes every run recompile.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  vec-remarks.sh [options]

Builds one cargo target in release mode with
  cargo rustc --release <target> -- -C remark=<passes> -C debuginfo=1 -C codegen-units=1
into <crate>/target/vec-remarks (a separate target dir: your normal build
cache is not touched) and prints only the LLVM remark lines, then a count.

Options:
  --manifest-path P   Cargo.toml to build (default: nearest from $PWD)
  --lib               build the library (default)
  --bin NAME          build binary NAME
  --bench NAME        build bench target NAME
  --example NAME      build example NAME
  --filter SUBSTR     keep only remark lines containing SUBSTR (file path,
                      line or mangled symbol; case sensitive)
  --passes "LIST"     space separated LLVM pass names or "all"
                      (default: "loop-vectorize slp-vectorizer")
  -h, --help          show this help

Output lines are "file:line:col pass (kind): message"; kinds are
success, missed and analysis (the reason behind a miss). The count line
reports vectorized (success) vs missed per pass.
Exit: 0 ok (even with zero matching remarks), 1 build failed, 2 usage/tool.
EOF
}

die() { printf 'vec-remarks.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'vec-remarks.sh: %s\n' "$*" >&2; exit 1; }

MANIFEST="" TARGET=(--lib) FILTER="" PASSES="loop-vectorize slp-vectorizer"
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --lib) TARGET=(--lib); shift ;;
    --bin|--bench|--example)
      [[ $# -ge 2 ]] || die "$1 needs a target name"
      TARGET=("$1" "$2"); shift 2 ;;
    --manifest-path|--filter|--passes)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in
        --manifest-path) MANIFEST=$2 ;; --filter) FILTER=$2 ;; --passes) PASSES=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown option '$1'" ;;
  esac
done

[[ "$PASSES" =~ ^[A-Za-z0-9_\ -]+$ ]] || die "--passes must be space separated pass names or 'all'"
[[ -n "${PASSES//[ ]/}" ]] || die "--passes is empty"
if [[ -n "$MANIFEST" ]]; then
  [[ -f "$MANIFEST" ]] || die "--manifest-path '$MANIFEST' is not a file"
fi

command -v cargo >/dev/null 2>&1 \
  || die "cargo not found: install Rust via rustup (https://rustup.rs)"
command -v rustc >/dev/null 2>&1 \
  || die "rustc not found: install Rust via rustup (https://rustup.rs)"
command -v python3 >/dev/null 2>&1 \
  || die "python3 not found: install python3 (needed to parse rustc's JSON diagnostics)"

MANIFEST_ARGS=()
LOCATE=(cargo locate-project --message-format plain)
if [[ -n "$MANIFEST" ]]; then
  MANIFEST_ARGS=(--manifest-path "$MANIFEST")
  LOCATE+=(--manifest-path "$MANIFEST")
fi
MANIFEST_PATH=$("${LOCATE[@]}" 2>/dev/null) || die "no Cargo.toml found from '$PWD'"
CRATE_DIR=$(dirname -- "$MANIFEST_PATH")
TARGET_DIR="$CRATE_DIR/target/vec-remarks"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vec-remarks.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# Only the crate under analysis gets -C remark (cargo rustc applies the extra
# flags to the final package alone), so only its invocation is tee'd. Probes
# like `rustc -vV` and dependency builds pass straight through.
cat >"$TMP/rustc-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *remark=*)
    "$@" 2>"$VEC_REMARKS_TMP/last.err"
    rc=$?
    cat "$VEC_REMARKS_TMP/last.err" >>"$VEC_REMARKS_LOG"
    cat "$VEC_REMARKS_TMP/last.err" >&2
    exit "$rc" ;;
  *) exec "$@" ;;
esac
EOF
chmod +x "$TMP/rustc-wrapper.sh"
: >"$TMP/remarks.log"

# The cfg is never read; it only changes the fingerprint so cargo recompiles
# the crate, because a cached build would emit no remarks at all.
if ! RUSTC_WRAPPER="$TMP/rustc-wrapper.sh" VEC_REMARKS_TMP="$TMP" VEC_REMARKS_LOG="$TMP/remarks.log" \
     CARGO_TARGET_DIR="$TARGET_DIR" \
     cargo rustc --release "${MANIFEST_ARGS[@]}" "${TARGET[@]}" -- \
       -C "remark=$PASSES" -C debuginfo=1 -C codegen-units=1 --cfg "vec_remarks_run=\"$$\"" \
     >"$TMP/build.out" 2>"$TMP/build.err"; then
  cat "$TMP/build.err" >&2
  fail "cargo rustc failed (target: ${TARGET[*]})"
fi

cat >"$TMP/parse.py" <<'PY'
import json, re, sys
log, filt, passes = sys.argv[1:]
pat = re.compile(r"^(?P<loc>\S+:\d+:\d+) (?P<pass>[\w.-]+) \((?P<kind>success|missed|analysis)\): (?P<text>.*)$", re.S)
# Not deduplicated: different functions can share a location (inlined std
# iterator code), and merging them would undercount the loops.
rows = []
with open(log, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("level") != "note":
            continue
        m = pat.match(d.get("message", ""))
        if not m:
            continue
        # Analysis messages continue on following lines; keep them on one.
        text = " | ".join(p.strip() for p in m["text"].splitlines() if p.strip())
        out = "%s %s (%s): %s" % (m["loc"], m["pass"], m["kind"], text)
        if filt and filt not in out:
            continue
        rows.append((m["pass"], m["kind"], out))
for _, _, out in rows:
    print(out)
counts = {}
for p, k, _ in rows:
    counts.setdefault(p, {"success": 0, "missed": 0, "analysis": 0})[k] += 1
print()
if not rows:
    print("no remarks matched (passes: %s%s)" % (passes, ", filter: " + filt if filt else ""))
    print("hint: a tiny pub fn in a lib is not compiled there (cross-crate inlining); use #[inline(never)] or a bin/bench/example target")
for p, c in sorted(counts.items()):
    print("%s: vectorized/applied %d, missed %d (reasons given: %d)" % (p, c["success"], c["missed"], c["analysis"]))
PY

python3 "$TMP/parse.py" "$TMP/remarks.log" "$FILTER" "$PASSES"
