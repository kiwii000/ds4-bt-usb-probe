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
STATUS_FILE="$RUN_DIR/bridge_status.txt"
RESULT_SUMMARY="$RUN_DIR/result_summary.txt"
PROTON_NOTES="$RUN_DIR/proton_visibility_notes.txt"
PROBE_PID=""

mkdir -p "$RUN_DIR"
cat >"$RUN_DIR/expected_virtual_identity.txt" <<'EOF'
Expected virtual Proton-visible identity:
HID_ID=0003:0000054C:000009CC
HID_NAME=Sony Interactive Entertainment Wireless Controller
bus_type=1
version=0x0100 when captured/default identity permits
input_report=0x01, 64-byte USB-style DS4

Expected uinput fallback identity:
bus=BUS_USB
vendor=0x054c
product=0x09cc
version=captured input version, otherwise 0x8111
name=Sony Interactive Entertainment Wireless Controller

Physical Bluetooth comparison:
HID_ID=0005:0000054C:000009CC
bus_type=2
input_report=0x11, 78-byte Bluetooth DS4
EOF
cat >"$PROTON_NOTES" <<'EOF'
Proton visibility notes
=======================
Expected real USB identity:
  HID_ID=0003:0000054C:000009CC
  HID_NAME=Sony Interactive Entertainment Wireless Controller
  bus_type=1

v0.3 virtual identities:
  UHID: BUS_USB / 054c:09cc with the captured USB descriptor and feature replies.
  uinput: BUS_USB / 054c:09cc evdev gamepad with normal axes and buttons.
  Both advertise USB-like input identity. Actual created-node status is in bridge_status.txt.

Known caveat:
  The UHID device is under /sys/devices/virtual/misc/uhid and has no real USB parent.
  Proton previously saw that hidraw identity but marked it input=-1 / is_gamepad=0.
  The uinput fallback exists to provide the normal evdev gamepad path Diablo IV may require.
EOF
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
  write_result_summary
  echo "[guided] Creating results archive"
  (
    cd "$CAPTURE_ROOT" &&
      tar -czf "$ARCHIVE" "$TIMESTAMP"
  )
  echo
  echo "Send this file back: $ARCHIVE"
}

status_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$STATUS_FILE" 2>/dev/null | tail -n 1
}

status_number() {
  local value
  value="$(status_value "$1")"
  printf '%s\n' "${value:-0}"
}

write_result_summary() {
  {
    echo "DS4 v0.3 guided result summary"
    echo "timestamp=$TIMESTAMP"
    echo
    for mode in usb bluetooth; do
      echo "[$mode real controller identity]"
      if [ -f "$CAPTURE_ROOT/$TIMESTAMP/$mode/identity/summary.txt" ]; then
        cat "$CAPTURE_ROOT/$TIMESTAMP/$mode/identity/summary.txt"
      else
        echo "summary=unavailable"
      fi
      echo
    done
    echo "[virtual bridge status]"
    if [ -f "$STATUS_FILE" ]; then
      cat "$STATUS_FILE"
    else
      echo "bridge_status=unavailable"
    fi
    echo
    echo "[tester answers and guided results]"
    for result in "$RUN_DIR"/steam_*.txt "$RUN_DIR"/diablo_*.txt "$RUN_DIR"/guided_gate_result.txt; do
      [ -f "$result" ] || continue
      printf '%s=' "$(basename "$result" .txt)"
      cat "$result"
    done
  } >"$RESULT_SUMMARY"
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

prepare_uinput() {
  echo
  echo "[guided] Checking uinput fallback support"
  if [ ! -e /dev/uinput ] && [ ! -e /dev/input/uinput ] && command -v modprobe >/dev/null 2>&1; then
    echo "[guided] uinput node is absent; trying: modprobe uinput"
    modprobe uinput 2>&1 || true
  fi
  if [ -e /dev/uinput ] || [ -e /dev/input/uinput ]; then
    echo "[guided] uinput device node is available"
  else
    echo "[guided] WARNING: no uinput device node is visible; bridge startup will archive this failure"
  fi
}

start_probe() {
  echo
  echo "Step 3:"
  echo "[guided] Starting required UHID + uinput + Bluetooth bridge"

  DS4_RAW_CAPTURE_DIR="$RUN_DIR/raw_bluetooth_reports" \
    DS4_STATUS_FILE="$STATUS_FILE" \
    "$ROOT_DIR/scripts/run_probe.sh" --bridge >"$PROBE_LOG" 2>&1 &
  PROBE_PID=$!

  echo "$PROBE_PID" >"$RUN_DIR/probe.pid"
  echo "[guided] Probe PID: $PROBE_PID"
  echo "[guided] Probe output: $PROBE_LOG"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if [ -n "$(status_value uinput_error)" ] && [ "$(status_value uinput_ready)" != "true" ]; then
      uinput_start_failed
      return 1
    fi
    if ! kill -0 "$PROBE_PID" >/dev/null 2>&1; then
      if [ -n "$(status_value uinput_error)" ]; then
        uinput_start_failed
        return 1
      fi
      probe_start_failed "probe process exited early"
      return 1
    fi
    if [ "$(status_value uhid_ready)" = "true" ] &&
      [ "$(status_value uinput_ready)" = "true" ] &&
      [ "$(status_value bluetooth_ready)" = "true" ] &&
      [ "$(status_number bluetooth_reports_read)" -gt 0 ] &&
      [ "$(status_number bluetooth_reports_forwarded)" -gt 0 ] &&
      [ "$(status_number uhid_reports_emitted)" -gt 0 ] &&
      [ "$(status_number uinput_events_emitted)" -gt 0 ]; then
      echo "[guided] Probe startup confirmed."
      printf 'ready\n' >"$RUN_DIR/guided_gate_result.txt"
      return 0
    fi
    sleep 1
  done

  probe_start_failed "UHID, uinput, and active Bluetooth forwarding were not confirmed after 30 seconds"
  return 1
}

uinput_start_failed() {
  echo "[guided] ERROR: uinput fallback failed, so this v0.3 Diablo test is not valid yet. Send back the archive."
  printf 'uinput fallback failed\n' >"$RUN_DIR/guided_gate_result.txt"
  cat "$PROBE_LOG" 2>/dev/null || true
  stop_probe
  copy_summaries
  finish_archive
}

probe_start_failed() {
  local reason="$1"
  echo "[guided] ERROR: $reason. The Diablo IV test will not continue."
  printf '%s\n' "$reason" >"$RUN_DIR/guided_gate_result.txt"
  printf 'probe_start_failed: %s\n' "$reason" >"$RUN_DIR/diablo_test_result.txt"
  echo "[guided] probe.log follows:"
  echo "----------------------------------------"
  cat "$PROBE_LOG" 2>/dev/null || true
  echo "----------------------------------------"
  stop_probe
  copy_summaries
  finish_archive
}

ensure_probe_alive() {
  if [ -n "$PROBE_PID" ] &&
    kill -0 "$PROBE_PID" >/dev/null 2>&1 &&
    [ "$(status_value uhid_ready)" = "true" ] &&
    [ "$(status_value uinput_ready)" = "true" ]; then
    return 0
  fi
  probe_start_failed "probe or Bluetooth bridge exited during the Diablo IV test"
  return 1
}

ask_result() {
  local prompt="$1"
  local output="$2"
  local answer=""
  echo
  while true; do
    read -r -p "$prompt yes/no/unsure: " answer
    case "${answer,,}" in
      yes|no|unsure)
        printf '%s\n' "${answer,,}" >"$RUN_DIR/$output"
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
echo "This script will collect USB identity, collect Bluetooth identity, run the UHID + uinput bridge,"
echo "ask you to test Diablo IV, and create one archive to send back."
echo
echo "[guided] project root: $ROOT_DIR"
echo "[guided] capture folder: $RUN_DIR"

pause_for_enter "Step 1: Connect the controller by USB, then press Enter."
run_capture_step usb

pause_for_enter "Step 2: Disconnect USB, connect the controller by Bluetooth, then press Enter."
run_capture_step bluetooth

prepare_uinput

if ! start_probe; then
  exit 1
fi

echo
echo "Step 4:"
echo "Now launch Steam, make sure Steam Input is disabled for Diablo IV, launch Diablo IV, and check whether PlayStation glyphs appear."
pause_for_enter "Press Enter after you have checked Diablo IV."

if ! ensure_probe_alive; then
  exit 1
fi

ask_result "Did Steam detect the controller?" "steam_controller_detected.txt"
ask_result "Did Steam show it as PlayStation/DS4?" "steam_playstation_ds4.txt"
ask_result "Did Diablo IV detect a controller?" "diablo_controller_detected.txt"
ask_result "Did PlayStation glyphs appear?" "diablo_playstation_glyphs.txt"
ask_result "Did input work?" "diablo_input_worked.txt"
ask_result "Was there duplicate input?" "diablo_duplicate_input.txt"

stop_probe
copy_summaries
finish_archive

echo "[guided] Done."
