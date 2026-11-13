#!/usr/bin/env bash
# diff-fuzz.sh — scaffold a differential test "old implementation vs new one".
#
# A faster rewrite is only a win if it returns the same answer for every input
# the old one accepted. Benchmarks never check that, and hand-picked unit tests
# miss the sizes where SIMD/unrolled paths switch (7/8/9, 15/16/17, 31/32/33 ...)
# and the inputs where line-ending or UTF-8 handling differs. This writes a
# dependency-free Rust integration test that sweeps exactly those cases with a
# fixed-seed xorshift64* generator, so a failure is replayable.
#
# The harness freezes tests/** at `baseline`; a file dropped there after that
# is restored away or flagged, and writing there mid-run edits a gate input.
# So the default is a scratch directory outside tests/, and a tests/ directory
# under an autor3search run is refused unless --force-tests-dir is given.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  diff-fuzz.sh --out DIR --old PATH --new PATH --sig SIG [options]

Writes DIR/diff_fuzz.rs, a self-contained integration test asserting
old(input) == new(input) over boundary sizes, value distributions and (for
text signatures) CRLF / lone CR / no trailing newline / multibyte UTF-8, plus
invalid UTF-8 for slice-u8. Copy it to <crate>/tests/ by hand when you want
it to run (see below), or point --out at a scratch cargo project.

Required:
  --out DIR     directory to write diff_fuzz.rs into (created if missing)
  --old PATH    Rust path of the old function, e.g. my_crate::old::count
  --new PATH    Rust path of the new function, e.g. my_crate::count
  --sig SIG     slice-u64   fn(&[u64]) -> R
                slice-u8    fn(&[u8])  -> R
                str         fn(&str)   -> R
                R must implement PartialEq + Debug.

Options:
  --iters N          random cases in the random_cases test (default: 20000)
  --force-tests-dir  allow writing into a tests/ directory that belongs to an
                     autor3search run (detected by .autor3search/config.yaml in
                     a parent directory). Only before `baseline`, or accept
                     that the harness will treat the file as frozen/changed.
  -h, --help         show this help

In an integration test `crate::` means the test crate itself: use your
library's name instead (my_crate::old::count). The old function must stay
callable, so keep it in the code under a different name, or in the test file.
Replay a failure with the command it prints, e.g.
  DIFF_FUZZ_REPLAY=random,4097,0x1234 cargo test --test diff_fuzz replay
Environment for the generated test: DIFF_FUZZ_ITERS overrides --iters.
Exit: 0 ok, 1 refused (tests/ under a run), 2 usage.
EOF
}

die() { printf 'diff-fuzz.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'diff-fuzz.sh: %s\n' "$*" >&2; exit 1; }

OUT="" OLD="" NEW="" SIG="" ITERS=20000 FORCE=0
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --force-tests-dir) FORCE=1; shift ;;
    --out|--old|--new|--sig|--iters)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in
        --out) OUT=$2 ;; --old) OLD=$2 ;; --new) NEW=$2 ;; --sig) SIG=$2 ;; --iters) ITERS=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown option '$1'" ;;
  esac
done

[[ -n "$OUT" ]] || die "--out is required"
[[ -n "$OLD" ]] || die "--old is required"
[[ -n "$NEW" ]] || die "--new is required"
[[ -n "$SIG" ]] || die "--sig is required"
PATH_RE='^[A-Za-z_][A-Za-z0-9_]*(::[A-Za-z_][A-Za-z0-9_]*)*$'
[[ "$OLD" =~ $PATH_RE ]] || die "--old must be a Rust path like crate_name::module::function"
[[ "$NEW" =~ $PATH_RE ]] || die "--new must be a Rust path like crate_name::module::function"
[[ "$OLD" != "$NEW" ]] || die "--old and --new are the same path; the test would compare a function with itself"
case "$SIG" in
  slice-u64) ELEM=u64 ;;
  slice-u8) ELEM=u8 ;;
  str) ELEM="" ;;
  *) die "--sig must be slice-u64, slice-u8 or str" ;;
esac
[[ "$ITERS" =~ ^[0-9]+$ ]] || die "--iters must be a non-negative integer"
if [[ "$OLD" == crate::* || "$NEW" == crate::* ]]; then
  printf 'warning: a path starting with crate:: refers to the test crate in tests/; use your library name instead.\n' >&2
fi

# Resolve without requiring DIR to exist yet.
ABS_OUT=$(realpath -m -- "$OUT")

# A `tests` path component under a directory tree that has an autor3search
# config means this would land in files the harness freezes.
in_tests=0
IFS=/ read -r -a PARTS <<<"$ABS_OUT"
for part in "${PARTS[@]}"; do
  [[ "$part" == tests ]] && in_tests=1
done
if (( in_tests )); then
  d=$ABS_OUT
  while [[ "$d" != / ]]; do
    if [[ -f "$d/.autor3search/config.yaml" ]]; then
      if (( ! FORCE )); then
        printf 'diff-fuzz.sh: refusing to write into %s\n' "$ABS_OUT" >&2
        printf '  %s has .autor3search/config.yaml, so tests/** is frozen by baseline:\n' "$d" >&2
        printf '  a new file there changes a gate input mid-run. Write to a scratch directory\n' >&2
        printf '  and copy the file in before baseline, or pass --force-tests-dir.\n' >&2
        exit 1
      fi
      printf 'warning: --force-tests-dir: writing into a tests/ directory of an autor3search run (%s)\n' "$d" >&2
      break
    fi
    d=$(dirname -- "$d")
  done
fi

mkdir -p -- "$ABS_OUT"
FILE="$ABS_OUT/diff_fuzz.rs"
if [[ -e "$FILE" ]]; then
  fail "$FILE already exists; remove it first (a previous test may carry local edits)"
fi

# Fragments are quoted heredocs so Rust braces and backticks pass through
# untouched; the few @TOKENS@ are replaced afterwards.
{
cat <<'EOF'
// Generated by scripts/diff-fuzz.sh: differential test, old vs new.
// old: @OLD@
// new: @NEW@
// sig: @SIG@
//
// Run:    cargo test --release --test diff_fuzz
// Replay: DIFF_FUZZ_REPLAY=<dist>,<size>,<case_seed> cargo test --test diff_fuzz replay
#![allow(dead_code)]

use @OLD@ as old_impl;
use @NEW@ as new_impl;

const SEED: u64 = 0x9E37_79B9_7F4A_7C15;
const ITERS: usize = @ITERS@;
// Sizes around the points where unrolled/SIMD paths and tails switch.
const SIZES: [usize; 28] = [
    0, 1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257, 1023,
    1024, 1025, 4095, 4096, 4097,
];

// xorshift64* (Vigna): fixed seed, no external crates, identical on every run.
struct Rng(u64);
impl Rng {
    fn new(seed: u64) -> Rng {
        Rng(if seed == 0 { 0x2545_F491_4F6C_DD1D } else { seed })
    }
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
}

// One seed per (size, distribution index), so each case replays on its own.
fn case_seed(size: usize, dist_index: usize) -> u64 {
    SEED ^ (size as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
        ^ (dist_index as u64 + 1).wrapping_mul(0xC2B2_AE3D_27D4_EB4F)
}

fn iters() -> usize {
    std::env::var("DIFF_FUZZ_ITERS").ok().and_then(|v| v.parse().ok()).unwrap_or(ITERS)
}

fn parse_seed(s: &str) -> u64 {
    match s.strip_prefix("0x") {
        Some(h) => u64::from_str_radix(h, 16).expect("bad hex seed"),
        None => s.parse().expect("bad seed"),
    }
}

EOF

if [[ "$SIG" != str ]]; then
cat <<'EOF'
type Elem = @ELEM@;
const NUM_DISTS: [&str; 6] = ["zeros", "max", "ascending", "descending", "few_distinct", "random"];

fn gen_num(dist: &str, size: usize, seed: u64) -> Vec<Elem> {
    let mut rng = Rng::new(seed);
    match dist {
        "zeros" => vec![0; size],
        "max" => vec![Elem::MAX; size],
        "ascending" => (0..size).map(|i| @ASC@).collect(),
        "descending" => (0..size).map(|i| @DESC@).collect(),
        "few_distinct" => (0..size).map(|_| (rng.next() % 4) as Elem).collect(),
        "random" => (0..size).map(|_| rng.next() as Elem).collect(),
        _ => unreachable!("unknown distribution {dist}"),
    }
}

EOF
fi

if [[ "$SIG" != slice-u64 ]]; then
cat <<'EOF'
const TEXT_DISTS: [&str; 7] =
    ["ascii", "lf", "crlf", "lone_cr", "no_trailing_newline", "multibyte", "mixed"];

// Pieces are valid UTF-8; a byte-exact cut at `size` may split a multibyte
// character, which is intended for byte slices and repaired for &str.
fn gen_text(dist: &str, size: usize, seed: u64) -> Vec<u8> {
    let mut rng = Rng::new(seed);
    let mut out: Vec<u8> = Vec::with_capacity(size + 8);
    let multi: [&[u8]; 6] = ["é".as_bytes(), "日".as_bytes(), "😀".as_bytes(), b"a", b"\n", "ß".as_bytes()];
    let mixed: [&[u8]; 7] = [b"a", b"\n", b"\r\n", b"\r", "é".as_bytes(), "日".as_bytes(), "😀".as_bytes()];
    while out.len() < size {
        match dist {
            "ascii" => out.push(0x20 + (rng.next() % 95) as u8),
            "lf" | "crlf" | "lone_cr" | "no_trailing_newline" => {
                for _ in 0..(rng.next() % 40) {
                    out.push(b'a' + (rng.next() % 26) as u8);
                }
                match dist {
                    "crlf" => out.extend_from_slice(b"\r\n"),
                    "lone_cr" => out.push(b'\r'),
                    _ => out.push(b'\n'),
                }
            }
            "multibyte" => out.extend_from_slice(multi[(rng.next() % 6) as usize]),
            "mixed" => out.extend_from_slice(mixed[(rng.next() % 7) as usize]),
            "invalid_utf8" => out.extend_from_slice(multi[(rng.next() % 6) as usize]),
            _ => unreachable!("unknown distribution {dist}"),
        }
    }
    out.truncate(size);
    if dist == "no_trailing_newline" {
        if let Some(last) = out.last_mut() {
            if *last == b'\n' {
                *last = b'x';
            }
        }
    }
    if dist == "invalid_utf8" && size > 0 {
        const BAD: [u8; 6] = [0x80, 0xC0, 0xC1, 0xF5, 0xFF, 0xED];
        for _ in 0..=(size / 64) {
            let at = (rng.next() % size as u64) as usize;
            out[at] = BAD[(rng.next() % 6) as usize];
        }
        // A truncated multibyte lead as the very last byte.
        out[size - 1] = 0xE6;
    }
    out
}

// Hand-picked line-ending, UTF-8 and invalid-UTF-8 corner cases.
const FIXED: [&[u8]; 24] = [
    b"", b"\n", b"\r\n", b"\r", b"a\r", b"\r\na", b"no newline", b"a\nb\n", b"a\r\nb\r\n",
    b"\r\r\n", b"\n\r", b"a\rb\rc", "é".as_bytes(), "日本語\n".as_bytes(), "😀".as_bytes(),
    "a😀\r\nb".as_bytes(), b"\xFF", b"\xC3", b"\xE6\x97", b"\xED\xA0\x80", b"\xC0\x80",
    b"a\xFFb\n", b"\xF0\x9F\x98", b"\x80abc",
];

EOF
fi

case "$SIG" in
  slice-u64)
cat <<'EOF'
const DISTS: &[&str] = &NUM_DISTS;

fn build(dist: &str, size: usize, seed: u64) -> Vec<Elem> {
    gen_num(dist, size, seed)
}

fn run(dist: &str, size: usize, seed: u64, input: &[Elem]) {
    let a = old_impl(input);
    let b = new_impl(input);
    if a != b {
        let head = &input[..input.len().min(64)];
        panic!(
            "old != new\n  dist={dist} size={size} case_seed={seed:#x} (base seed {SEED:#x})\n  input[..{}]={head:?}\n  old={a:?}\n  new={b:?}\n  replay: DIFF_FUZZ_REPLAY={dist},{size},{seed:#x} cargo test --test diff_fuzz replay",
            head.len()
        );
    }
}
EOF
    ;;
  slice-u8)
cat <<'EOF'
const ALL_DISTS: [&str; 14] = [
    "zeros", "max", "ascending", "descending", "few_distinct", "random", "ascii", "lf", "crlf",
    "lone_cr", "no_trailing_newline", "multibyte", "mixed", "invalid_utf8",
];
const DISTS: &[&str] = &ALL_DISTS;

fn build(dist: &str, size: usize, seed: u64) -> Vec<Elem> {
    if NUM_DISTS.contains(&dist) {
        gen_num(dist, size, seed)
    } else {
        gen_text(dist, size, seed)
    }
}

fn run(dist: &str, size: usize, seed: u64, input: &[Elem]) {
    let a = old_impl(input);
    let b = new_impl(input);
    if a != b {
        let head = &input[..input.len().min(64)];
        panic!(
            "old != new\n  dist={dist} size={size} case_seed={seed:#x} (base seed {SEED:#x})\n  input[..{}]={head:?}\n  old={a:?}\n  new={b:?}\n  replay: DIFF_FUZZ_REPLAY={dist},{size},{seed:#x} cargo test --test diff_fuzz replay",
            head.len()
        );
    }
}

#[test]
fn fixed_cases() {
    for (i, case) in FIXED.iter().enumerate() {
        run(&format!("fixed#{i}"), case.len(), 0, case);
    }
}
EOF
    ;;
  str)
cat <<'EOF'
const DISTS: &[&str] = &TEXT_DISTS;

fn build(dist: &str, size: usize, seed: u64) -> String {
    let mut bytes = gen_text(dist, size, seed);
    // Drop a split trailing character so the input is valid &str.
    while std::str::from_utf8(&bytes).is_err() {
        bytes.pop();
    }
    String::from_utf8(bytes).expect("repaired to valid UTF-8")
}

fn run(dist: &str, size: usize, seed: u64, input: &str) {
    let a = old_impl(input);
    let b = new_impl(input);
    if a != b {
        let head: String = input.chars().take(64).collect();
        panic!(
            "old != new\n  dist={dist} size={size} case_seed={seed:#x} (base seed {SEED:#x})\n  input[..64 chars]={head:?}\n  old={a:?}\n  new={b:?}\n  replay: DIFF_FUZZ_REPLAY={dist},{size},{seed:#x} cargo test --test diff_fuzz replay",
        );
    }
}

#[test]
fn fixed_cases() {
    for (i, case) in FIXED.iter().enumerate() {
        // Invalid UTF-8 corner cases do not exist as &str; skip them.
        if let Ok(s) = std::str::from_utf8(case) {
            run(&format!("fixed#{i}"), s.len(), 0, s);
        }
    }
}
EOF
    ;;
esac

cat <<'EOF'

#[test]
fn boundary_sizes() {
    for (di, dist) in DISTS.iter().enumerate() {
        for &size in &SIZES {
            let seed = case_seed(size, di);
            run(dist, size, seed, &build(dist, size, seed));
        }
    }
}

#[test]
fn random_cases() {
    let mut rng = Rng::new(SEED);
    for _ in 0..iters() {
        let di = (rng.next() % DISTS.len() as u64) as usize;
        let size = (rng.next() % 5001) as usize;
        let seed = rng.next();
        run(DISTS[di], size, seed, &build(DISTS[di], size, seed));
    }
}

// DIFF_FUZZ_REPLAY=<dist>,<size>,<case_seed> reruns exactly one failing case.
#[test]
fn replay() {
    let Ok(spec) = std::env::var("DIFF_FUZZ_REPLAY") else { return };
    let parts: Vec<&str> = spec.split(',').collect();
    assert_eq!(parts.len(), 3, "DIFF_FUZZ_REPLAY must be dist,size,seed");
    let size: usize = parts[1].parse().expect("bad size");
    let seed = parse_seed(parts[2]);
    run(parts[0], size, seed, &build(parts[0], size, seed));
}
EOF
} >"$FILE.tmp"

if [[ "$SIG" == slice-u8 ]]; then
  ASC='(i * 256 \/ size.max(1)) as u8'
  DESC='255 - (i * 256 \/ size.max(1)) as u8'
else
  ASC='i as Elem'
  DESC='(size - 1 - i) as Elem'
fi
sed -e "s/@OLD@/$OLD/g" -e "s/@NEW@/$NEW/g" -e "s/@SIG@/$SIG/g" \
    -e "s/@ITERS@/$ITERS/g" -e "s/@ELEM@/$ELEM/g" \
    -e "s/@ASC@/$ASC/g" -e "s/@DESC@/$DESC/g" "$FILE.tmp" >"$FILE"
rm -f -- "$FILE.tmp"

printf 'wrote %s (sig %s, %s random cases)\n' "$FILE" "$SIG" "$ITERS"
printf 'run:  cargo test --release --test diff_fuzz   (from the crate that contains the file under tests/)\n'
