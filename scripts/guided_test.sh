#!/usr/bin/env bash
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "[guided] Re-running with sudo so the probe can access /dev/uhid and hidraw diagnostics."
    exec sudo -E bash "$0" "$@"
  fi
  echo "[guided] ERROR: this script must be run with sudo/root." >&2
  echo "[guided] Try: sudo ./scripts/guided_test.sh" >&2
  exit 1
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAPTURE_ROOT="$ROOT_DIR/captures"
RUN_DIR="$CAPTURE_ROOT/$TIMESTAMP/guided"
ARCHIVE="$ROOT_DIR/ds4-probe-results-$TIMESTAMP.tar.gz"
GUIDED_LOG="$RUN_DIR/guided_test.log"
PROBE_LOG="$RUN_DIR/probe.log"
PROBE_PID=""

mkdir -p "$RUN_DIR"
exec > >(tee -a "$GUIDED_LOG") 2>&1

stop_probe() {
  if [ -n "$PROBE_PID" ] && kill -0 "$PROBE_PID" >/dev/null 2>&1; then
    echo "[guided] Stopping probe PID $PROBE_PID"
    kill -INT "$PROBE_PID" >/dev/null 2>&1 || true
    sleep 2
    if kill -0 "$PROBE_PID" >/dev/null 2>&1; then
      echo "[guided] Probe did not exit after SIGINT; sending SIGTERM"
      kill -TERM "$PROBE_PID" >/dev/null 2>&1 || true
      sleep 1
    fi
    wait "$PROBE_PID" >/dev/null 2>&1 || true
  fi
}

finish_archive() {
  echo "[guided] Creating results archive"
  (
    cd "$CAPTURE_ROOT" &&
      tar -czf "$ARCHIVE" "$TIMESTAMP"
  )
  echo
  echo "Send this file back: $ARCHIVE"
}

cleanup_on_signal() {
  echo
  echo "[guided] Interrupted; cleaning up."
  stop_probe
  finish_archive
  exit 130
}

trap cleanup_on_signal INT TERM

pause_for_enter() {
  local prompt="$1"
  echo
  read -r -p "$prompt"
}

run_capture_step() {
  local mode="$1"
  local log="$RUN_DIR/${mode}_capture_output.log"

  echo
  echo "[guided] Running $mode identity capture"
  DS4_CAPTURE_TIMESTAMP="$TIMESTAMP" "$ROOT_DIR/scripts/collect_ds4_identity.sh" "$mode" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  echo "$status" >"$RUN_DIR/${mode}_capture_exit_status.txt"
  if [ "$status" -ne 0 ]; then
    echo "[guided] WARNING: $mode capture exited with status $status."
    echo "[guided] Continuing so you can still run the probe and send diagnostics."
  fi
}

find_probe_binary() {
  if [ -x "$ROOT_DIR/ds4-bt-usb-probe" ]; then
    printf '%s\n' "$ROOT_DIR/ds4-bt-usb-probe"
    return 0
  fi
  if [ -x "$ROOT_DIR/target/release/ds4-bt-usb-probe" ]; then
    printf '%s\n' "$ROOT_DIR/target/release/ds4-bt-usb-probe"
    return 0
  fi
  return 1
}

latest_usb_descriptor_arg() {
  local descriptor="$CAPTURE_ROOT/$TIMESTAMP/usb/report_descriptor.bin"
  if [ -f "$descriptor" ]; then
    printf '%s\n' "$descriptor"
    return 0
  fi
  descriptor="$CAPTURE_ROOT/$TIMESTAMP/usb/hidraw/report_descriptor.bin"
  if [ -f "$descriptor" ]; then
    printf '%s\n' "$descriptor"
    return 0
  fi
  return 1
}

start_probe() {
  echo
  echo "[guided] Starting UHID probe in the background"

  local probe_bin
  if probe_bin="$(find_probe_binary)"; then
    local args=(--capture-root "$CAPTURE_ROOT")
    local descriptor
    if descriptor="$(latest_usb_descriptor_arg)"; then
      echo "[guided] Using captured USB descriptor: $descriptor"
      args+=(--descriptor "$descriptor")
    else
      echo "[guided] WARNING: no USB descriptor captured; probe will use its fallback descriptor."
    fi

    "$probe_bin" "${args[@]}" >"$PROBE_LOG" 2>&1 &
    PROBE_PID=$!
  else
    echo "[guided] Release binary not found; falling back to scripts/run_probe.sh"
    "$ROOT_DIR/scripts/run_probe.sh" >"$PROBE_LOG" 2>&1 &
    PROBE_PID=$!
  fi

  echo "$PROBE_PID" >"$RUN_DIR/probe.pid"
  echo "[guided] Probe PID: $PROBE_PID"
  echo "[guided] Probe output: $PROBE_LOG"
  sleep 2
  if ! kill -0 "$PROBE_PID" >/dev/null 2>&1; then
    echo "[guided] WARNING: probe process exited early. See $PROBE_LOG"
  fi
}

ask_diablo_result() {
  local answer=""
  echo
  while true; do
    read -r -p "Did Diablo IV show PlayStation glyphs? yes/no/unsure: " answer
    case "${answer,,}" in
      yes|no|unsure)
        printf '%s\n' "${answer,,}" >"$RUN_DIR/diablo_test_result.txt"
        return 0
        ;;
      *)
        echo "Please answer yes, no, or unsure."
        ;;
    esac
  done
}

copy_summaries() {
  mkdir -p "$RUN_DIR/summaries"
  for mode in usb bluetooth; do
    if [ -f "$CAPTURE_ROOT/$TIMESTAMP/$mode/identity/summary.txt" ]; then
      cp "$CAPTURE_ROOT/$TIMESTAMP/$mode/identity/summary.txt" "$RUN_DIR/summaries/${mode}_summary.txt" 2>/dev/null || true
    fi
  done
}

echo "DS4 Bluetooth/USB Probe Guided Test"
echo "==================================="
echo
echo "This script will collect USB identity, collect Bluetooth identity, run the UHID probe,"
echo "ask you to test Diablo IV, and create one archive to send back."
echo
echo "[guided] project root: $ROOT_DIR"
echo "[guided] capture folder: $RUN_DIR"

pause_for_enter "Step 1: Connect the controller by USB, then press Enter."
run_capture_step usb

pause_for_enter "Step 2: Disconnect USB, connect the controller by Bluetooth, then press Enter."
run_capture_step bluetooth

start_probe

echo
echo "Step 4:"
echo "Now launch Steam, make sure Steam Input is disabled for Diablo IV, launch Diablo IV, and check whether PlayStation glyphs appear."
pause_for_enter "Press Enter after you have checked Diablo IV."

ask_diablo_result

stop_probe
copy_summaries
finish_archive

echo "[guided] Done."
