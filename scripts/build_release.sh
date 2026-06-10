#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if ! command -v cargo >/dev/null 2>&1; then
  echo "[build_release] ERROR: cargo not found. Install Rust first." >&2
  exit 1
fi

echo "[build_release] building release binary"
(cd "$ROOT_DIR" && cargo build --release)
echo "[build_release] binary: $ROOT_DIR/target/release/ds4-bt-usb-probe"
