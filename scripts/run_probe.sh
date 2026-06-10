#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BIN=""

echo "[run_probe] root=$ROOT_DIR"

if [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -n "${DISTROBOX_ENTER_PATH:-}" ] || [ -n "${CONTAINER_ID:-}" ] || [ -n "${TOOLBOX_PATH:-}" ]; then
  echo "[run_probe] ERROR: Do not run this from distrobox/toolbox. Extract the GitHub Actions artifact on the Bazzite host and run it from a normal host terminal."
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "[run_probe] ERROR: this script must be run with sudo/root so it can open /dev/uhid."
  echo "[run_probe] Try: sudo ./scripts/run_probe.sh"
  exit 1
fi

if [ ! -e /dev/uhid ]; then
  echo "[run_probe] ERROR: /dev/uhid does not exist."
  echo "[run_probe] Try: sudo modprobe uhid"
  echo "[run_probe] Then rerun: sudo ./scripts/guided_test.sh"
  exit 1
fi

if [ ! -w /dev/uhid ]; then
  echo "[run_probe] ERROR: /dev/uhid is not writable by the current effective user."
  echo "[run_probe] Try: sudo modprobe uhid"
  echo "[run_probe] Then rerun: sudo ./scripts/guided_test.sh"
  exit 1
fi

find_cargo() {
  if command -v cargo >/dev/null 2>&1; then
    command -v cargo
    return 0
  fi
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local user_home
    user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)"
    if [ -n "$user_home" ] && [ -x "$user_home/.cargo/bin/cargo" ]; then
      printf '%s\n' "$user_home/.cargo/bin/cargo"
      return 0
    fi
  fi
  return 1
}

if [ -f "$ROOT_DIR/ds4-bt-usb-probe" ]; then
  chmod +x "$ROOT_DIR/ds4-bt-usb-probe" || {
    echo "[run_probe] ERROR: artifact binary exists but could not be made executable: $ROOT_DIR/ds4-bt-usb-probe"
    exit 1
  }
  BIN="$ROOT_DIR/ds4-bt-usb-probe"
  echo "[run_probe] using artifact binary: $BIN"
elif [ -f "$ROOT_DIR/target/release/ds4-bt-usb-probe" ]; then
  chmod +x "$ROOT_DIR/target/release/ds4-bt-usb-probe" || {
    echo "[run_probe] ERROR: source-build binary exists but could not be made executable: $ROOT_DIR/target/release/ds4-bt-usb-probe"
    exit 1
  }
  BIN="$ROOT_DIR/target/release/ds4-bt-usb-probe"
  echo "[run_probe] using source-build binary: $BIN"
else
  echo "[run_probe] release binary not found; building it now"
  CARGO_BIN="$(find_cargo || true)"
  if [ -z "${CARGO_BIN:-}" ]; then
    echo "[run_probe] ERROR: no probe binary found and cargo is unavailable."
    echo "[run_probe] Preferred fix: extract the GitHub Actions artifact on the Bazzite host and rerun this script."
    exit 1
  fi
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && command -v sudo >/dev/null 2>&1; then
    echo "[run_probe] building as $SUDO_USER to avoid root-owned target files"
    (cd "$ROOT_DIR" && sudo -u "$SUDO_USER" "$CARGO_BIN" build --release)
  else
    (cd "$ROOT_DIR" && "$CARGO_BIN" build --release)
  fi
  BIN="$ROOT_DIR/target/release/ds4-bt-usb-probe"
fi

if [ ! -x "$BIN" ]; then
  echo "[run_probe] ERROR: binary was not produced at $BIN"
  exit 1
fi

descriptor=""
if [ -d "$ROOT_DIR/captures" ]; then
  descriptor="$(
    find "$ROOT_DIR/captures" \
      \( -path '*/usb/report_descriptor.bin' -o -path '*/usb/hidraw/report_descriptor.bin' \) \
      -type f -printf '%T@ %p\n' 2>/dev/null \
      | sort -nr \
      | awk 'NR == 1 { sub(/^[^ ]+ /, ""); print; exit }'
  )"
fi

args=(--capture-root "$ROOT_DIR/captures")
if [ -n "$descriptor" ]; then
  echo "[run_probe] using captured descriptor: $descriptor"
  args+=(--descriptor "$descriptor")
else
  echo "[run_probe] WARNING: no USB capture descriptor found; probe will use fallback descriptor"
  echo "[run_probe] WARNING: run sudo ./scripts/collect_ds4_identity.sh usb first for the preferred real-controller descriptor"
fi

echo "[run_probe] launching probe. Keep this terminal open during the Diablo IV test."
echo "[run_probe] probe effective user: $(id -u) (must be 0/root)"
exec "$BIN" "${args[@]}"
