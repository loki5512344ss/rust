#!/usr/bin/env bash
# perf-diff.sh — which symbols got more or fewer samples between two commands.
#
# A total-time delta says that something changed; the per-symbol diff says
# where. Both profiles must use the same event or the columns are not
# comparable, so the event is chosen once (hardware cycles in user space,
# else the cpu-clock timer) and used for both sides.
#
# Read it carefully: "Baseline" and "Delta Abs" are shares of each profile,
# not absolute time. If B does twice the work in one symbol, every other
# symbol's share falls even though it did not get faster. The period columns
# (-p) are the absolute event counts and are what to quote.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  perf-diff.sh [--freq HZ] -- <cmdA> <cmdB>

Records each command (run through `sh -c`) with
  perf record -F HZ -e cycles:u        (falls back to -e cpu-clock)
and prints the top 30 rows of
  perf diff -p -s symbol A.data B.data
Columns: baseline share, baseline period, delta of the share (B - A), B period.

Options:
  --freq HZ    sampling frequency (default: 999; odd values avoid lockstep
               with periodic work)
  -h, --help   show this help

Never uses sudo. If neither event can be recorded, nothing is shown and the
paranoid level plus the fallback ladder are printed. The workload's stdout is
discarded. Exit: 0 ok, 1 recording failed or refused, 2 usage/missing tool.
EOF
}

die() { printf 'perf-diff.sh: %s\n' "$*" >&2; exit 2; }
fail() { printf 'perf-diff.sh: %s\n' "$*" >&2; exit 1; }

FREQ=999
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    --freq)
      [[ $# -ge 2 ]] || die "--freq needs a value"
      FREQ=$2; shift 2 ;;
    *) die "unknown option '$1' (commands go after --)" ;;
  esac
done

[[ "$FREQ" =~ ^[0-9]+$ ]] && [[ "$FREQ" != 0* ]] || die "--freq must be a positive integer"
(( FREQ <= 100000 )) || die "--freq above 100000 is not accepted by most kernels"
(( $# == 2 )) || die "need exactly two commands after -- (got $#)"
CMD_A=$1
CMD_B=$2

command -v perf >/dev/null 2>&1 \
  || die "perf not found: pacman -S perf / apt install linux-perf (or: samply record -- <cmd>)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/perf-diff.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null) || PARANOID=unknown

# A probe on `true` separates "perf cannot record here" from "the workload
# exited nonzero", which perf record reports with the same status.
EVENT=""
for ev in cycles:u cpu-clock; do
  if perf record -q -F "$FREQ" -e "$ev" -o "$TMP/probe.data" -- sh -c true \
       >/dev/null 2>"$TMP/probe-$ev.err"; then
    EVENT=$ev
    break
  fi
done
if [[ -z "$EVENT" ]]; then
  printf 'perf-diff.sh: perf record is not possible here (tried cycles:u, cpu-clock):\n' >&2
  head -n 3 "$TMP/probe-cycles:u.err" >&2 || true
  printf '  /proc/sys/kernel/perf_event_paranoid = %s\n' "$PARANOID" >&2
  printf '  fallback ladder:\n' >&2
  printf '    1. counts only, no symbols: instr-count.sh -- <cmdA> <cmdB>   (perf stat)\n' >&2
  printf '    2. sampling without perf_event access: samply record -- <cmd>  (cargo install samply)\n' >&2
  printf '    3. a one-time root action: sysctl kernel.perf_event_paranoid=1\n' >&2
  printf '  No profile was recorded.\n' >&2
  exit 1
fi
if [[ "$EVENT" == cpu-clock ]]; then
  printf 'note: hardware cycles are not available here; using the cpu-clock timer (includes kernel time, coarser attribution).\n'
fi

record_one() { # side cmd
  if ! perf record -q -F "$FREQ" -e "$EVENT" -o "$TMP/$1.data" -- sh -c "$2" >/dev/null 2>"$TMP/$1.err"; then
    cat "$TMP/$1.err" >&2
    fail "recording command $1 failed (command exited nonzero?): $2"
  fi
}

# Sequential, A then B: perf record has no interleaved mode, so a drifting
# machine biases the diff. Repeat with the sides swapped when it matters.
record_one A "$CMD_A"
record_one B "$CMD_B"

printf 'A: %s\nB: %s\nevent: %s, %s Hz\n\n' "$CMD_A" "$CMD_B" "$EVENT" "$FREQ"

# Header lines start with '#'; `head` closing the pipe early would SIGPIPE
# perf diff, which is harmless, so its status is not checked here.
if ! perf diff -p -s symbol "$TMP/A.data" "$TMP/B.data" >"$TMP/diff.txt" 2>"$TMP/diff.err"; then
  cat "$TMP/diff.err" >&2
  fail "perf diff failed"
fi
grep '^# Baseline' "$TMP/diff.txt" || true
grep -v -e '^#' -e '^[[:space:]]*$' "$TMP/diff.txt" | head -n 30

if grep -qE '\[\.\] 0x[0-9a-f]{8,}' <(grep -v '^#' "$TMP/diff.txt" | head -n 30); then
  printf '\nrows shown as raw addresses have no symbol: the binary is stripped; rebuild with\n'
  printf "  RUSTFLAGS='-C debuginfo=1 -C strip=none' cargo build --release\n"
fi
