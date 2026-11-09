#!/usr/bin/env bash
set -euo pipefail
rustc -Vv
cargo -V
cargo fmt --all -- --check
cargo test --locked --all-targets
cargo clippy --locked --all-targets -- -D warnings
cargo bench --locked --bench select_active
