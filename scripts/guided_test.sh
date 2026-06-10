#!/usr/bin/env bash
set -uo pipefail

if [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -n "${DISTROBOX_ENTER_PATH:-}" ] || [ -n "${CONTAINER_ID:-}" ] || [ -n "${TOOLBOX_PATH:-}" ]; then
  echo "[guided] ERROR: Do not run this from distrobox/toolbox. Extract the GitHub Actions artifact on the Bazzite host and run it from a normal host terminal." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "[guided] Re-running with sudo so the probe can access /dev/uhid and hidraw diagnostics."
    exec sudo -E bash "$0" "$@"
  fi
  echo "[guided] ERROR: this script must be run with sudo/root." >&2
  echo "[guided] Try: sudo ./scripts/guided_test.sh" >&2
  exit 1
fi

if [ ! -e /dev/uhid ]; then
  echo "[guided] ERROR: /dev/uhid does not exist." >&2
  echo "[guided] Try: sudo modprobe uhid" >&2
  echo "[guided] Then rerun: sudo ./scripts/guided_test.sh" >&2
  exit 1
fi

if [ ! -w /dev/uhid ]; then
  echo "[guided] ERROR: /dev/uhid is not writable by the current effective user." >&2
  echo "[guided] Try: sudo modprobe uhid" >&2
  echo "[guided] Then rerun: sudo ./scripts/guided_test.sh" >&2
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

start_probe() {
  echo
  echo "Step 3:"
  echo "[guided] Starting UHID probe in the background"

  "$ROOT_DIR/scripts/run_probe.sh" >"$PROBE_LOG" 2>&1 &
  PROBE_PID=$!

  echo "$PROBE_PID" >"$RUN_DIR/probe.pid"
  echo "[guided] Probe PID: $PROBE_PID"
  echo "[guided] Probe output: $PROBE_LOG"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "$PROBE_PID" >/dev/null 2>&1; then
      probe_start_failed "probe process exited early"
      return 1
    fi
    if grep -Eq '/dev/uhid opened|sending neutral USB-style DS4 input reports' "$PROBE_LOG"; then
      echo "[guided] Probe startup confirmed."
      return 0
    fi
    sleep 1
  done

  probe_start_failed "probe initialization was not confirmed after 10 seconds"
  return 1
}

probe_start_failed() {
  local reason="$1"
  echo "[guided] ERROR: $reason. The Diablo IV test will not continue."
  printf 'probe_start_failed: %s\n' "$reason" >"$RUN_DIR/diablo_test_result.txt"
  echo "[guided] probe.log follows:"
  echo "----------------------------------------"
  cat "$PROBE_LOG" 2>/dev/null || true
  echo "----------------------------------------"
  stop_probe
  copy_summaries
  finish_archive
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

if ! start_probe; then
  exit 1
fi

echo
echo "Step 4:"
echo "Now launch Steam, make sure Steam Input is disabled for Diablo IV, launch Diablo IV, and check whether PlayStation glyphs appear."
pause_for_enter "Press Enter after you have checked Diablo IV."

ask_diablo_result

stop_probe
copy_summaries
finish_archive

echo "[guided] Done."
