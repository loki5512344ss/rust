#!/usr/bin/env bash
# asm-report.sh — capture `cargo asm` for one symbol before and after a patch.
#
# The previous dump rotates to before.s, so the second invocation prints a
# unified diff. If that diff is empty, the "optimization" never reached
# codegen — see references/asm-reading.md, section 10.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  asm-report.sh --lib <symbol> [--out DIR]
  asm-report.sh --bin NAME <symbol> [--out DIR]
  asm-report.sh --bench NAME <symbol> [--out DIR]

Dumps `cargo asm <artifact> --rust <symbol>` into DIR/after.s, rotates a
previous DIR/after.s to DIR/before.s, writes DIR/meta.txt, and prints the
unified diff when both snapshots exist.

Options:
  --out DIR   output directory (default: <repo>/target/asm/<symbol>;
              a relative DIR is resolved against the repo root)
  -h, --help  show this help

Run it once before the patch, once after. Needs cargo-show-asm:
  cargo install cargo-show-asm     # provides `cargo asm`
EOF
}

die() { printf 'asm-report.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'asm-report.sh: %s\n' "$*" >&2; exit 1; }

ART=()
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --lib) ART=(--lib); shift ;;
  --bin|--bench)
    [[ $# -ge 2 ]] || die "$1 needs a target name"
    ART=("$1" "$2"); shift 2 ;;
  "") usage >&2; exit 2 ;;
  *) die "first argument must be --lib, --bin NAME or --bench NAME" ;;
esac

[[ $# -ge 1 ]] || die "missing <symbol>"
SYMBOL=$1
shift
OUT=""
while (( $# )); do
  case "$1" in
    --out)
      [[ $# -ge 2 ]] || die "--out needs a directory"
      OUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unexpected argument '$1'" ;;
  esac
done

command -v cargo >/dev/null 2>&1 \
  || die "cargo not found: install Rust via rustup (https://rustup.rs)"
if ! cargo asm --version >/dev/null 2>&1; then
  die "cargo-show-asm is missing: cargo install cargo-show-asm (provides 'cargo asm')"
fi

# cargo asm resolves the crate from the manifest, so run from the repo root.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=$PWD
[[ -f "$ROOT/Cargo.toml" ]] || die "no Cargo.toml at repo root '$ROOT'"

# One directory per symbol keeps `::` out of the filesystem.
SLUG=${SYMBOL//[^A-Za-z0-9_.-]/_}
DIR=${OUT:-target/asm/$SLUG}
[[ "$DIR" = /* ]] || DIR="$ROOT/$DIR"

mkdir -p -- "$DIR"
HAD_BEFORE=0
if [[ -f "$DIR/after.s" ]]; then
  mv -f -- "$DIR/after.s" "$DIR/before.s"
  HAD_BEFORE=1
fi

printf -v CMDLINE '%q ' cargo asm "${ART[@]}" --rust "$SYMBOL"
if ! ( cd "$ROOT" && cargo asm "${ART[@]}" --rust "$SYMBOL" ) \
     >"$DIR/after.s" 2>"$DIR/asm.err"; then
  printf 'cargo asm failed; stderr:\n' >&2
  cat "$DIR/asm.err" >&2
  # A truncated dump that looks like a real one is worse than no dump.
  rm -f -- "$DIR/after.s"
  printf 'hint: list available symbols with: cargo asm %s\n' "${ART[*]}" >&2
  printf 'hint: in a virtual workspace, run from the member crate or pass -p PACKAGE to cargo asm\n' >&2
  exit 1
fi

# Keep a failed run from leaving a truncated dump that looks real.
rm -f -- "$DIR/asm.err"

GIT_HEAD=$(cd "$ROOT" && git rev-parse HEAD 2>/dev/null) || GIT_HEAD='not a git repo'
GIT_BRANCH=$(cd "$ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null) || GIT_BRANCH=unknown
{
  printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'git HEAD: %s\n' "$GIT_HEAD"
  printf 'git branch: %s\n' "$GIT_BRANCH"
  printf 'symbol: %s\n' "$SYMBOL"
  printf 'artifact: %s\n' "${ART[*]}"
  printf 'command: cd %q && %s\n' "$ROOT" "$CMDLINE"
  printf 'cargo asm: %s\n' "$(cargo asm --version 2>&1 | head -n 1)"
  printf 'rustc:\n'
  rustc -Vv
} >"$DIR/meta.txt"

if (( HAD_BEFORE )); then
  # diff exits 1 on difference; guard set -e and separate it from real errors.
  set +e
  diff -u --label before.s --label after.s "$DIR/before.s" "$DIR/after.s" >"$DIR/diff.patch"
  RC=$?
  set -e
  case "$RC" in
    0)
      rm -f -- "$DIR/diff.patch"
      printf 'assembly identical: the change did not reach codegen\n' ;;
    1)
      cat "$DIR/diff.patch"
      printf '\nfull diff: %s\n' "$DIR/diff.patch" ;;
    *)
      rm -f -- "$DIR/diff.patch"
      fail "diff failed (exit $RC) comparing before.s and after.s" ;;
  esac
else
  printf 'first dump: %s/after.s (nothing to diff yet)\n' "$DIR"
fi

printf 'meta: %s/meta.txt\n' "$DIR"
