#!/usr/bin/env bash
set -uo pipefail

GUIDED_MODE="${DS4_GUIDED_MODE:-stable-default}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      shift
      GUIDED_MODE="${1:-}"
      ;;
    *)
      echo "[guided] ERROR: unknown argument: $1" >&2
      echo "[guided] usage: sudo ./scripts/guided_test.sh [--mode stable-default|strict-isolation]" >&2
      exit 2
      ;;
  esac
  shift
done
case "$GUIDED_MODE" in
  stable-default|strict-isolation) ;;
  *)
    echo "[guided] ERROR: invalid mode: $GUIDED_MODE" >&2
    echo "[guided] expected stable-default or strict-isolation" >&2
    exit 2
    ;;
esac

if [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -n "${DISTROBOX_ENTER_PATH:-}" ] || [ -n "${CONTAINER_ID:-}" ] || [ -n "${TOOLBOX_PATH:-}" ]; then
  echo "[guided] ERROR: Do not run this from distrobox/toolbox. Extract the GitHub Actions artifact on the Bazzite host and run it from a normal host terminal." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "[guided] Re-running with sudo so the probe can access host devices."
    exec env DS4_GUIDED_MODE="$GUIDED_MODE" sudo -E bash "$0"
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
PERM_DIR="$RUN_DIR/device_permissions"
ARCHIVE="$ROOT_DIR/ds4-probe-results-$TIMESTAMP.tar.gz"
GUIDED_LOG="$RUN_DIR/guided_test.log"
PROBE_LOG="$RUN_DIR/probe.log"
STATUS_FILE="$RUN_DIR/bridge_status.txt"
MONITOR_DIR="$RUN_DIR/uhid_event_touchpad_monitor"
RESULT_SUMMARY="$RUN_DIR/result_summary.txt"
PROTON_NOTES="$RUN_DIR/proton_visibility_notes.txt"
MANIFEST="$PERM_DIR/manifest.tsv"
DISCOVERED_NODES="$PERM_DIR/discovered_physical_bt_nodes.tsv"
RESTRICTED_NODES="$PERM_DIR/restricted_nodes.tsv"
ISOLATION_LOG="$PERM_DIR/isolation.log"
RESTORE_LOG="$PERM_DIR/restore.log"
PROBE_PID=""
RESTORE_STATUS="not_attempted"
SELECTED_RUNTIME_MODE="full-uhid-input"
BRIDGE_STABLE_PRE_DIABLO="no"

mkdir -p "$RUN_DIR" "$PERM_DIR" "$MONITOR_DIR"
exec > >(tee -a "$GUIDED_LOG") 2>&1

TARGET_USER="${DS4_TEST_USER:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  echo "[guided] ERROR: could not determine the normal Steam user to isolate."
  echo "[guided] Re-run with sudo from the Steam user's terminal, or set DS4_TEST_USER=<username>."
  exit 1
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "[guided] ERROR: target user does not exist: $TARGET_USER"
  exit 1
fi
if ! command -v getfacl >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
  echo "[guided] ERROR: v0.5.1 requires getfacl, setfacl, and sudo for ACL-only isolation."
  echo "[guided] This v0.5.1 Diablo test is not valid yet. Install ACL tools or send this archive/log back."
  printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
  printf 'no\n' >"$RUN_DIR/v0.5_valid_diablo_test.txt"
  printf 'missing getfacl/setfacl/sudo\n' >"$RUN_DIR/v0.5_invalid_reason.txt"
fi

cat >"$RUN_DIR/expected_virtual_identity.txt" <<'EOF'
Expected virtual Proton-visible identity:
HID_ID=0003:0000054C:000009CC
HID_NAME=Sony Interactive Entertainment Wireless Controller
bus_type=1
input_report=0x01, 64-byte USB-style DS4

Expected uinput fallback identity:
bus=BUS_USB
vendor=0x054c
product=0x09cc
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

v0.5.1 virtual identities:
  UHID: BUS_USB / 054c:09cc with the captured USB descriptor and feature replies.
  uinput: BUS_USB / 054c:09cc evdev gamepad with normal axes and buttons.

v0.5.1 isolation attempt:
  After the bridge opens the physical Bluetooth hidraw device, stable-default leaves that active hidraw node untouched and uses ACLs only for physical evdev/js nodes.
  Virtual UHID/uinput nodes are not restricted.

v0.5.1 touchpad idle fix:
  UHID USB DS4 reports intentionally encode no active touchpad contacts and freeze the touchpad block until a correct touchpad conversion is implemented.
  The UHID virtual event node is externally monitored before Diablo.

Known caveat:
  UHID still lives under /sys/devices/virtual/misc/uhid, not a real USB parent.
  The v0.5.1 test checks whether a stable Bluetooth reader, uinput output, and externally clean UHID touchpad idle state let Proton/Diablo select the virtual outputs.
EOF

printf 'kind\tnode\tsyspath\tacl_file\tstat_file\n' >"$MANIFEST"
: >"$DISCOVERED_NODES"
: >"$RESTRICTED_NODES"
: >"$ISOLATION_LOG"
: >"$RESTORE_LOG"

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

restore_permissions() {
  local entries
  entries="$(awk 'NR > 1 && NF { count++ } END { print count + 0 }' "$MANIFEST" 2>/dev/null || echo 0)"
  if [ ! -s "$MANIFEST" ] || [ "$entries" -eq 0 ]; then
    RESTORE_STATUS="nothing_to_restore"
    printf '%s\n' "$RESTORE_STATUS" >"$RUN_DIR/permission_restore_status.txt"
    return 0
  fi

  echo "[guided] Restoring physical Bluetooth node ACLs"
  local failures=0
  local restored=0
  local kind node syspath acl_file stat_file
  while IFS=$'\t' read -r kind node syspath acl_file stat_file; do
    [ "$kind" != "kind" ] || continue
    [ -n "$acl_file" ] || continue
    if [ ! -f "$acl_file" ]; then
      echo "[restore] missing ACL backup for $node: $acl_file" | tee -a "$RESTORE_LOG"
      failures=$((failures + 1))
      continue
    fi
    if [ ! -e "$node" ]; then
      echo "[restore] skipped: node no longer exists: $node" | tee -a "$RESTORE_LOG"
      continue
    fi
    if [ -n "$syspath" ] && [ ! -e "$syspath" ]; then
      echo "[restore] skipped: node was recreated or syspath disappeared: $node -> $syspath" | tee -a "$RESTORE_LOG"
      continue
    fi
    if setfacl --restore="$acl_file" >>"$RESTORE_LOG" 2>&1; then
      echo "[restore] restored $node" | tee -a "$RESTORE_LOG"
      restored=$((restored + 1))
    else
      echo "[restore] FAILED $node" | tee -a "$RESTORE_LOG"
      failures=$((failures + 1))
    fi
  done <"$MANIFEST"

  if [ "$failures" -eq 0 ]; then
    RESTORE_STATUS="restored:$restored"
    printf 'yes\n' >"$RUN_DIR/permissions_restored.txt"
  else
    RESTORE_STATUS="restore_failed:$failures"
    printf 'no\n' >"$RUN_DIR/permissions_restored.txt"
  fi
  printf '%s\n' "$RESTORE_STATUS" >"$RUN_DIR/permission_restore_status.txt"
  [ "$failures" -eq 0 ]
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

find_probe_binary() {
  local candidate
  for candidate in "$ROOT_DIR/ds4-bt-usb-probe" "$ROOT_DIR/target/release/ds4-bt-usb-probe"; do
    if [ -f "$candidate" ]; then
      chmod +x "$candidate" 2>/dev/null || true
      if [ -x "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    fi
  done
  return 1
}

line_count() {
  local file="$1"
  if [ -f "$file" ]; then
    wc -l <"$file" | tr -d ' '
  else
    printf '0\n'
  fi
}

kind_count() {
  local file="$1"
  local kind="$2"
  awk -F '\t' -v kind="$kind" '$1 == kind { count++ } END { print count + 0 }' "$file" 2>/dev/null || echo 0
}

write_result_summary() {
  {
    echo "DS4 v0.5.1 guided result summary"
    echo "timestamp=$TIMESTAMP"
    echo "target_user=$TARGET_USER"
    echo "guided_mode=$GUIDED_MODE"
    echo "valid_diablo_test=$(cat "$RUN_DIR/valid_diablo_test.txt" 2>/dev/null || echo unknown)"
    echo "v0.5_valid_diablo_test=$(cat "$RUN_DIR/v0.5_valid_diablo_test.txt" 2>/dev/null || echo unknown)"
    echo "v0.5_invalid_reason=$(cat "$RUN_DIR/v0.5_invalid_reason.txt" 2>/dev/null || echo none)"
    echo "selected_runtime_mode=$(cat "$RUN_DIR/selected_runtime_mode.txt" 2>/dev/null || echo "$SELECTED_RUNTIME_MODE")"
    echo "bridge_stable_pre_diablo=$(cat "$RUN_DIR/bridge_stable_pre_diablo.txt" 2>/dev/null || echo no)"
    echo "permission_restore_status=$RESTORE_STATUS"
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
    echo "[v0.5.1 touchpad checks]"
    echo "touchpad_neutralization_enabled=$(status_value touchpad_neutralization_enabled)"
    echo "touchpad_no_touch_encoding=$(status_value touchpad_no_touch_encoding)"
    echo "touchpad_mode=$(status_value touchpad_mode)"
    echo "uhid_identity_only=$(status_value uhid_identity_only)"
    echo "internal_touchpad_idle_clean=$(status_value touchpad_idle_clean)"
    echo "touchpad_idle_samples_checked=$(status_number touchpad_idle_samples_checked)"
    echo "internal_touchpad_active_contacts_emitted=$(status_number touchpad_active_contacts_emitted)"
    echo "uhid_event_touchpad_idle_clean=$(cat "$RUN_DIR/uhid_event_touchpad_idle_clean.txt" 2>/dev/null || echo unknown)"
    echo "uhid_event_touchpad_events_seen=$(cat "$RUN_DIR/uhid_event_touchpad_events_seen.txt" 2>/dev/null || echo 0)"
    echo "uhid_event_touchpad_event_samples=$(cat "$RUN_DIR/uhid_event_touchpad_event_samples.txt" 2>/dev/null || echo none)"
    echo "usb_idle_template_captured=$(cat "$CAPTURE_ROOT/$TIMESTAMP/usb/idle_input/status.txt" 2>/dev/null | sed -n 's/^usb_idle_template_captured=//p' | tail -n 1 || echo unknown)"
    echo
    echo "[physical Bluetooth isolation]"
    echo "physical_bt_nodes_found=$(line_count "$DISCOVERED_NODES")"
    echo "physical_bt_hidraw_nodes_found=$(kind_count "$DISCOVERED_NODES" hidraw)"
    echo "physical_bt_event_nodes_found=$(kind_count "$DISCOVERED_NODES" event)"
    echo "physical_bt_js_nodes_found=$(kind_count "$DISCOVERED_NODES" js)"
    echo "restricted_nodes=$(line_count "$RESTRICTED_NODES")"
    echo "restricted_hidraw_nodes=$(kind_count "$RESTRICTED_NODES" hidraw)"
    echo "restricted_event_nodes=$(kind_count "$RESTRICTED_NODES" event)"
    echo "restricted_js_nodes=$(kind_count "$RESTRICTED_NODES" js)"
    echo "isolation_success=$(cat "$RUN_DIR/physical_isolation_success.txt" 2>/dev/null || echo no)"
    echo "active_physical_hidraw=$(status_value bluetooth_hidraw)"
    echo "active_physical_hidraw_restricted=$(cat "$RUN_DIR/active_physical_hidraw_restricted.txt" 2>/dev/null || echo no)"
    echo "evdev_js_nodes_restricted=$(cat "$RUN_DIR/evdev_js_nodes_restricted.txt" 2>/dev/null || echo no)"
    echo "bluetooth_reports_forwarded=$(status_number bluetooth_reports_forwarded)"
    echo "uinput_events_emitted=$(status_number uinput_events_emitted)"
    echo "clean_hidraw_loss=$(status_value clean_hidraw_loss)"
    echo "bluetooth_reconnect_success=$(status_value bluetooth_reconnect_success)"
    echo "virtual_uhid_nodes=$(status_value uhid_hidraw_nodes),$(status_value uhid_input_nodes)"
    echo "virtual_uinput_node=$(status_value uinput_event_node)"
    echo "manifest=$MANIFEST"
    echo "discovered_nodes=$DISCOVERED_NODES"
    echo "restricted_nodes_file=$RESTRICTED_NODES"
    echo "isolation_log=$ISOLATION_LOG"
    echo "restore_log=$RESTORE_LOG"
    echo
    if [ -s "$DISCOVERED_NODES" ]; then
      echo "[physical BT nodes found]"
      cat "$DISCOVERED_NODES"
      echo
    fi
    if [ -s "$RESTRICTED_NODES" ]; then
      echo "[physical BT nodes restricted]"
      cat "$RESTRICTED_NODES"
      echo
    fi
    echo "[tester answers and guided results]"
    for result in "$RUN_DIR"/steam_*.txt "$RUN_DIR"/script_*.txt "$RUN_DIR"/diablo_*.txt "$RUN_DIR"/guided_gate_result.txt; do
      [ -f "$result" ] || continue
      printf '%s=' "$(basename "$result" .txt)"
      cat "$result"
    done
  } >"$RESULT_SUMMARY"
}

cleanup_on_signal() {
  echo
  echo "[guided] Interrupted; restoring permissions and cleaning up."
  printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
  printf 'no\n' >"$RUN_DIR/v0.5_valid_diablo_test.txt"
  printf 'interrupted\n' >"$RUN_DIR/v0.5_invalid_reason.txt"
  restore_permissions || true
  stop_probe
  copy_summaries
  finish_archive
  exit 130
}

trap cleanup_on_signal INT TERM

pause_for_enter() {
  local prompt="$1"
  echo
  read -r -p "$prompt"
}

wait_for_enter_while_probe_alive() {
  local prompt="$1"
  local ignored=""
  echo
  printf '%s' "$prompt"
  while true; do
    if read -r -t 1 ignored; then
      return 0
    fi
    if [ -z "$PROBE_PID" ] || ! kill -0 "$PROBE_PID" >/dev/null 2>&1; then
      startup_failed "probe or Bluetooth bridge exited during the Diablo IV test"
      return 1
    fi
  done
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
    echo "[guided] Continuing so you can still run the bridge and send diagnostics."
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
  local runtime_mode="${1:-full-uhid-input}"
  local identity_only
  echo
  echo "Step 3:"
  echo "[guided] Starting required UHID + uinput + Bluetooth bridge ($runtime_mode)"
  SELECTED_RUNTIME_MODE="$runtime_mode"
  PROBE_LOG="$RUN_DIR/probe-$runtime_mode.log"
  : >"$STATUS_FILE"
  if [ "$runtime_mode" = "identity-only-uhid" ]; then
    identity_only="yes"
  else
    identity_only="no"
  fi

  DS4_UHID_IDENTITY_ONLY="$identity_only" \
    DS4_TOUCHPAD_MODE="hard-disabled" \
  DS4_RAW_CAPTURE_DIR="$RUN_DIR/raw_bluetooth_reports" \
    DS4_STATUS_FILE="$STATUS_FILE" \
    "$ROOT_DIR/scripts/run_probe.sh" --bridge >"$PROBE_LOG" 2>&1 &
  PROBE_PID=$!

  echo "$PROBE_PID" >"$RUN_DIR/probe.pid"
  echo "[guided] Probe PID: $PROBE_PID"
  echo "[guided] Probe output: $PROBE_LOG"
  local attempt
  for attempt in $(seq 1 30); do
    if [ -n "$(status_value uinput_error)" ] && [ "$(status_value uinput_ready)" != "true" ]; then
      startup_failed "uinput fallback failed"
      return 1
    fi
    if ! kill -0 "$PROBE_PID" >/dev/null 2>&1; then
      startup_failed "probe process exited early"
      return 1
    fi
    local uhid_output_ok
    if [ "$runtime_mode" = "identity-only-uhid" ] || [ "$(status_number uhid_reports_emitted)" -gt 0 ]; then
      uhid_output_ok="yes"
    else
      uhid_output_ok="no"
    fi
    if [ "$(status_value uhid_ready)" = "true" ] &&
      [ "$(status_value uinput_ready)" = "true" ] &&
      [ "$(status_value bluetooth_ready)" = "true" ] &&
      [ -n "$(status_value bluetooth_hidraw)" ] &&
      [ "$(status_number bluetooth_reports_read)" -gt 0 ] &&
      [ "$(status_number bluetooth_reports_forwarded)" -gt 0 ] &&
      [ "$uhid_output_ok" = "yes" ] &&
      [ "$(status_number uinput_events_emitted)" -gt 0 ]; then
      echo "[guided] Probe startup confirmed."
      return 0
    fi
    sleep 1
  done

  startup_failed "UHID, uinput, physical Bluetooth hidraw ownership, and active forwarding were not confirmed after 30 seconds"
  return 1
}

startup_failed() {
  local reason="$1"
  echo "[guided] ERROR: $reason. The Diablo IV test will not continue."
  printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
  printf 'no\n' >"$RUN_DIR/v0.5_valid_diablo_test.txt"
  printf '%s\n' "$reason" >"$RUN_DIR/v0.5_invalid_reason.txt"
  printf '%s\n' "$reason" >"$RUN_DIR/guided_gate_result.txt"
  printf 'probe_start_failed: %s\n' "$reason" >"$RUN_DIR/diablo_test_result.txt"
  echo "[guided] probe.log follows:"
  echo "----------------------------------------"
  cat "$PROBE_LOG" 2>/dev/null || true
  echo "----------------------------------------"
  restore_permissions || true
  stop_probe
  copy_summaries
  finish_archive
}

input_node_matches_physical_bt() {
  local sys="$1"
  local bus vendor product
  bus="$(cat "$sys/id/bustype" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  vendor="$(cat "$sys/id/vendor" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  product="$(cat "$sys/id/product" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  [ "$bus" = "0005" ] && [ "$vendor" = "054c" ] && [ "$product" = "09cc" ]
}

hidraw_node_matches_physical_bt() {
  local sys="$1"
  grep -Eiq '^HID_ID=0005:0000054C:000009CC' "$sys/uevent" 2>/dev/null
}

node_is_virtual_output() {
  local node="$1"
  local uinput_node uhid_hidraw_nodes uhid_input_nodes
  uinput_node="$(status_value uinput_event_node)"
  uhid_hidraw_nodes="$(status_value uhid_hidraw_nodes)"
  uhid_input_nodes="$(status_value uhid_input_nodes)"
  [ -n "$uinput_node" ] && [ "$node" = "$uinput_node" ] && return 0
  case ",$uhid_hidraw_nodes,$uhid_input_nodes," in
    *",$node,"*) return 0 ;;
  esac
  return 1
}

node_is_active_physical_hidraw() {
  local node="$1"
  local active_hidraw
  active_hidraw="$(status_value bluetooth_hidraw)"
  [ -n "$active_hidraw" ] && [ "$node" = "$active_hidraw" ]
}

add_physical_node() {
  local kind="$1"
  local node="$2"
  local sys="$3"
  [ -e "$node" ] || return 0
  if node_is_virtual_output "$node"; then
    echo "[isolation] skipping virtual output node: $node" | tee -a "$ISOLATION_LOG"
    return 0
  fi
  if [ "$GUIDED_MODE" = "stable-default" ] && [ "$kind" = "hidraw" ]; then
    if node_is_active_physical_hidraw "$node"; then
      echo "[isolation] stable-default skipping active physical hidraw reader: $node" | tee -a "$ISOLATION_LOG"
    else
      echo "[isolation] stable-default skipping physical hidraw node: $node" | tee -a "$ISOLATION_LOG"
    fi
    printf 'no\n' >"$RUN_DIR/active_physical_hidraw_restricted.txt"
    return 0
  fi
  printf '%s\t%s\t%s\n' "$kind" "$node" "$sys" >>"$DISCOVERED_NODES"
}

discover_physical_nodes() {
  : >"$DISCOVERED_NODES"
  local hidraw_dev hidraw_base sys input_dev input_base

  for hidraw_dev in /dev/hidraw*; do
    [ -e "$hidraw_dev" ] || continue
    hidraw_base="$(basename "$hidraw_dev")"
    sys="/sys/class/hidraw/$hidraw_base/device"
    if hidraw_node_matches_physical_bt "$sys"; then
      add_physical_node "hidraw" "$hidraw_dev" "$sys"
    fi
  done

  for input_dev in /dev/input/event* /dev/input/js*; do
    [ -e "$input_dev" ] || continue
    input_base="$(basename "$input_dev")"
    sys="/sys/class/input/$input_base/device"
    if input_node_matches_physical_bt "$sys"; then
      add_physical_node "${input_base%%[0-9]*}" "$input_dev" "$sys"
    fi
  done

  sort -u "$DISCOVERED_NODES" -o "$DISCOVERED_NODES"
  echo "[isolation] physical Bluetooth nodes discovered:"
  sed 's/^/[isolation]   /' "$DISCOVERED_NODES" || true
}

restrict_physical_nodes() {
  echo
  echo "Step 4:"
  echo "[guided] Applying ACL-only isolation to physical Bluetooth DS4 nodes"
  if ! command -v getfacl >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
    isolation_failed "missing getfacl/setfacl/sudo; ACL-only isolation cannot run"
    return 1
  fi

  discover_physical_nodes
  if [ ! -s "$DISCOVERED_NODES" ]; then
    if [ "$GUIDED_MODE" = "stable-default" ]; then
      echo "[isolation] stable-default found no evdev/js nodes to restrict; continuing with active hidraw untouched" | tee -a "$ISOLATION_LOG"
      printf 'yes\n' >"$RUN_DIR/physical_isolation_success.txt"
      printf 'no\n' >"$RUN_DIR/active_physical_hidraw_restricted.txt"
      printf 'no\n' >"$RUN_DIR/evdev_js_nodes_restricted.txt"
      return 0
    else
      isolation_failed "no physical Bluetooth DS4 nodes were discovered"
      return 1
    fi
  fi

  : >"$RESTRICTED_NODES"
  printf 'no\n' >"$RUN_DIR/active_physical_hidraw_restricted.txt"
  printf 'no\n' >"$RUN_DIR/evdev_js_nodes_restricted.txt"
  local count=0
  local kind node syspath acl_file stat_file
  while IFS=$'\t' read -r kind node syspath; do
    [ -n "$node" ] || continue
    count=$((count + 1))
    acl_file="$PERM_DIR/acl-$count-$(basename "$node").txt"
    stat_file="$PERM_DIR/stat-$count-$(basename "$node").txt"

    if ! getfacl -p "$node" >"$acl_file" 2>>"$ISOLATION_LOG"; then
      isolation_failed "could not back up ACL for $node"
      return 1
    fi
    stat -Lc 'node=%n owner=%U group=%G mode=%a type=%F major_minor=%t:%T' "$node" >"$stat_file" 2>>"$ISOLATION_LOG" || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$node" "$syspath" "$acl_file" "$stat_file" >>"$MANIFEST"

    echo "[isolation] restricting $node for user $TARGET_USER" | tee -a "$ISOLATION_LOG"
    if ! setfacl -m "u:${TARGET_USER}:---" "$node" >>"$ISOLATION_LOG" 2>&1; then
      isolation_failed "setfacl failed for $node"
      return 1
    fi
    if sudo -u "$TARGET_USER" test -r "$node" 2>/dev/null || sudo -u "$TARGET_USER" test -w "$node" 2>/dev/null; then
      isolation_failed "target user can still access $node after ACL restriction"
      return 1
    fi
    if [ "$kind" = "hidraw" ] && node_is_active_physical_hidraw "$node"; then
      printf 'yes\n' >"$RUN_DIR/active_physical_hidraw_restricted.txt"
    fi
    if [ "$kind" = "event" ] || [ "$kind" = "js" ]; then
      printf 'yes\n' >"$RUN_DIR/evdev_js_nodes_restricted.txt"
    fi
    printf '%s\t%s\t%s\n' "$kind" "$node" "$syspath" >>"$RESTRICTED_NODES"
  done <"$DISCOVERED_NODES"

  if ! verify_virtual_nodes_present; then
    isolation_failed "virtual UHID/uinput nodes were not still visible after isolation"
    return 1
  fi

  printf 'yes\n' >"$RUN_DIR/physical_isolation_success.txt"
  printf 'yes\n' >"$RUN_DIR/v0.5_valid_diablo_test.txt"
  printf 'none\n' >"$RUN_DIR/v0.5_invalid_reason.txt"
  printf 'ready\n' >"$RUN_DIR/guided_gate_result.txt"
  echo "[guided] Physical Bluetooth isolation confirmed."
}

print_pre_diablo_check() {
  echo
  echo "Pre-Diablo readiness check:"
  echo "  UHID virtual DS4 ready: $(status_value uhid_ready)"
  echo "  uinput fallback ready: $(status_value uinput_ready)"
  if [ "$(status_number bluetooth_reports_forwarded)" -gt 0 ]; then
    echo "  Bluetooth reports forwarding: yes"
  else
    echo "  Bluetooth reports forwarding: no"
  fi
  echo "  physical BT isolation active: $(cat "$RUN_DIR/physical_isolation_success.txt" 2>/dev/null || echo no)"
  echo "  internal UHID touchpad decoder clean: $(status_value touchpad_idle_clean)"
  echo "  external UHID event touchpad idle clean: $(cat "$RUN_DIR/uhid_event_touchpad_idle_clean.txt" 2>/dev/null || echo unchecked)"
  echo "  UHID touchpad idle samples checked: $(status_number touchpad_idle_samples_checked)"
  echo "  UHID active touch contacts emitted: $(status_number touchpad_active_contacts_emitted)"
  echo "  active physical hidraw restricted: $(cat "$RUN_DIR/active_physical_hidraw_restricted.txt" 2>/dev/null || echo no)"
  echo "  selected runtime mode: $SELECTED_RUNTIME_MODE"
}

select_uhid_event_node() {
  local uinput_node uhid_input_nodes node
  uinput_node="$(status_value uinput_event_node)"
  uhid_input_nodes="$(status_value uhid_input_nodes)"
  IFS=',' read -r -a nodes <<<"$uhid_input_nodes"
  for node in "${nodes[@]}"; do
    [ -n "$node" ] || continue
    [ "$node" != "$uinput_node" ] || continue
    [ -e "$node" ] || continue
    printf '%s\n' "$node"
    return 0
  done
  return 1
}

monitor_uhid_touchpad_idle() {
  local runtime_mode="$1"
  local event_node probe_bin output_dir status_file clean events samples
  event_node="$(select_uhid_event_node || true)"
  output_dir="$MONITOR_DIR/$runtime_mode"
  mkdir -p "$output_dir"
  if [ -z "$event_node" ]; then
    echo "[guided] ERROR: could not find UHID virtual DS4 event node for external touchpad monitor"
    printf 'no\n' >"$RUN_DIR/uhid_event_touchpad_idle_clean.txt"
    printf '0\n' >"$RUN_DIR/uhid_event_touchpad_events_seen.txt"
    printf 'missing UHID event node\n' >"$RUN_DIR/uhid_event_touchpad_invalid_reason.txt"
    return 1
  fi
  printf '%s\n' "$event_node" >"$RUN_DIR/uhid_event_node.txt"
  echo
  echo "[guided] External UHID event touchpad idle monitor"
  echo "[guided] Do not touch the controller for this short check."
  echo "[guided] Monitoring $event_node for touchpad events."
  probe_bin="$(find_probe_binary || true)"
  if [ -z "$probe_bin" ]; then
    echo "[guided] ERROR: probe binary unavailable; cannot run external touchpad event monitor"
    printf 'no\n' >"$RUN_DIR/uhid_event_touchpad_idle_clean.txt"
    printf '0\n' >"$RUN_DIR/uhid_event_touchpad_events_seen.txt"
    printf 'probe binary unavailable\n' >"$RUN_DIR/uhid_event_touchpad_invalid_reason.txt"
    return 1
  fi
  "$probe_bin" monitor-touchpad-events \
    --event "$event_node" \
    --output-dir "$output_dir" \
    --duration-ms 7000 \
    >"$output_dir/monitor.log" 2>&1
  status_file="$output_dir/status.txt"
  clean="$(sed -n 's/^uhid_event_touchpad_idle_clean=//p' "$status_file" 2>/dev/null | tail -n 1)"
  events="$(sed -n 's/^uhid_event_touchpad_events_seen=//p' "$status_file" 2>/dev/null | tail -n 1)"
  samples="$(sed -n 's/^uhid_event_touchpad_event_samples=//p' "$status_file" 2>/dev/null | tail -n 1)"
  printf '%s\n' "${clean:-no}" >"$RUN_DIR/uhid_event_touchpad_idle_clean.txt"
  printf '%s\n' "${events:-0}" >"$RUN_DIR/uhid_event_touchpad_events_seen.txt"
  printf '%s\n' "${samples:-$output_dir/touchpad-events.txt}" >"$RUN_DIR/uhid_event_touchpad_event_samples.txt"
  echo "[guided] UHID event touchpad idle clean: ${clean:-no}"
  echo "[guided] UHID event touchpad events seen: ${events:-0}"
  [ "${clean:-no}" = "yes" ]
}

pre_diablo_stability_gate() {
  local runtime_mode="$1"
  local wait_attempt
  echo
  echo "[guided] Running pre-Diablo bridge stability gate"
  for wait_attempt in $(seq 1 10); do
    if ! kill -0 "$PROBE_PID" >/dev/null 2>&1; then
      printf 'no\n' >"$RUN_DIR/bridge_stable_pre_diablo.txt"
      startup_failed "bridge exited before the Diablo IV step"
      return 1
    fi
    sleep 1
  done
  if [ "$(status_value uhid_ready)" = "true" ] &&
    [ "$(status_value uinput_ready)" = "true" ] &&
    [ "$(status_number bluetooth_reports_forwarded)" -gt 0 ] &&
    [ "$(cat "$RUN_DIR/active_physical_hidraw_restricted.txt" 2>/dev/null || echo no)" != "yes" ]; then
    printf 'yes\n' >"$RUN_DIR/bridge_stable_pre_diablo.txt"
    BRIDGE_STABLE_PRE_DIABLO="yes"
  else
    printf 'no\n' >"$RUN_DIR/bridge_stable_pre_diablo.txt"
    startup_failed "bridge stability checks did not pass before Diablo IV"
    return 1
  fi
  if monitor_uhid_touchpad_idle "$runtime_mode"; then
    print_pre_diablo_check
    return 0
  fi
  print_pre_diablo_check
  return 1
}

verify_virtual_nodes_present() {
  local uinput_node uhid_hidraw_nodes uhid_input_nodes node found_uhid
  uinput_node="$(status_value uinput_event_node)"
  uhid_hidraw_nodes="$(status_value uhid_hidraw_nodes)"
  uhid_input_nodes="$(status_value uhid_input_nodes)"
  found_uhid=0

  if [ -z "$uinput_node" ] || [ ! -e "$uinput_node" ]; then
    echo "[isolation] virtual uinput node missing: ${uinput_node:-unknown}" | tee -a "$ISOLATION_LOG"
    return 1
  fi

  IFS=',' read -r -a nodes <<<"${uhid_hidraw_nodes},${uhid_input_nodes}"
  for node in "${nodes[@]}"; do
    [ -n "$node" ] || continue
    if [ -e "$node" ]; then
      found_uhid=1
    fi
  done
  if [ "$found_uhid" -ne 1 ]; then
    echo "[isolation] no virtual UHID node from bridge_status.txt is present" | tee -a "$ISOLATION_LOG"
    return 1
  fi
  return 0
}

isolation_failed() {
  local reason="$1"
  echo "[guided] ERROR: v0.5.1 was not a valid Diablo test because physical Bluetooth isolation failed: $reason"
  printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
  printf 'no\n' >"$RUN_DIR/physical_isolation_success.txt"
  printf 'no\n' >"$RUN_DIR/v0.5_valid_diablo_test.txt"
  printf 'physical isolation failed: %s\n' "$reason" >"$RUN_DIR/v0.5_invalid_reason.txt"
  printf 'physical isolation failed: %s\n' "$reason" >"$RUN_DIR/guided_gate_result.txt"
  restore_permissions || true
  stop_probe
  copy_summaries
  finish_archive
}

ensure_probe_alive() {
  if [ -n "$PROBE_PID" ] &&
    kill -0 "$PROBE_PID" >/dev/null 2>&1 &&
    [ "$(status_value uhid_ready)" = "true" ] &&
    [ "$(status_value uinput_ready)" = "true" ] &&
    [ "$(cat "$RUN_DIR/physical_isolation_success.txt" 2>/dev/null)" = "yes" ] &&
    [ "$(cat "$RUN_DIR/uhid_event_touchpad_idle_clean.txt" 2>/dev/null)" = "yes" ]; then
    return 0
  fi
  startup_failed "probe, bridge, physical Bluetooth isolation, or external UHID touchpad idle state failed during the Diablo IV test"
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

if ! command -v getfacl >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
  copy_summaries
  finish_archive
  exit 1
fi

echo "DS4 Bluetooth/USB Probe Guided Test v0.5.1"
echo "========================================"
echo
echo "This script collects USB/Bluetooth identity, starts the UHID + uinput bridge,"
echo "temporarily hides the original physical Bluetooth DS4 from user $TARGET_USER with ACLs,"
echo "asks you to test Diablo IV, restores permissions, and creates one archive to send back."
echo
echo "[guided] project root: $ROOT_DIR"
echo "[guided] capture folder: $RUN_DIR"
echo "[guided] target Steam/Proton user: $TARGET_USER"
echo
echo "Important: close Steam completely before continuing. The script will tell you when to launch Steam again."

pause_for_enter "Before Step 1: Close Steam completely, then press Enter."

pause_for_enter "Step 1: Connect the controller by USB, leave it untouched for the idle capture, then press Enter."
run_capture_step usb

pause_for_enter "Step 2: Disconnect USB, connect the controller by Bluetooth, then press Enter."
run_capture_step bluetooth

prepare_uinput

if ! start_probe full-uhid-input; then
  exit 1
fi

if ! restrict_physical_nodes; then
  exit 1
fi

if ! pre_diablo_stability_gate full-uhid-input; then
  if [ "$(cat "$RUN_DIR/uhid_event_touchpad_idle_clean.txt" 2>/dev/null)" = "no" ]; then
    echo "[guided] Full UHID input still emits touchpad events at idle; trying identity-only UHID fallback."
    stop_probe
    restore_permissions || true
    if ! start_probe identity-only-uhid; then
      exit 1
    fi
    if ! restrict_physical_nodes; then
      exit 1
    fi
    if ! pre_diablo_stability_gate identity-only-uhid; then
      echo "[guided] ERROR: UHID touchpad bug is still not fixed. The Diablo IV test will not continue."
      printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
      printf 'UHID event touchpad idle monitor failed in full and identity-only modes\n' >"$RUN_DIR/v0.5_invalid_reason.txt"
      stop_probe
      restore_permissions || true
      copy_summaries
      finish_archive
      exit 1
    fi
  else
    exit 1
  fi
fi

printf 'yes\n' >"$RUN_DIR/valid_diablo_test.txt"
printf '%s\n' "$SELECTED_RUNTIME_MODE" >"$RUN_DIR/selected_runtime_mode.txt"

echo
echo "Step 5:"
echo "Now launch Steam, make sure Steam Input is disabled for Diablo IV, launch Diablo IV, and check whether PlayStation glyphs appear."
if ! wait_for_enter_while_probe_alive "Press Enter after you have checked Diablo IV."; then
  exit 1
fi

if ! ensure_probe_alive; then
  exit 1
fi

ask_result "Did Steam detect the controller?" "steam_controller_detected.txt"
ask_result "In Steam controller tester, is there still a permanent touchpad contact?" "steam_permanent_touchpad_contact.txt"
ask_result "Does the script say UHID event touchpad idle clean?" "script_uhid_event_touchpad_idle_clean.txt"
ask_result "Did Diablo IV detect a controller?" "diablo_controller_detected.txt"
ask_result "Did PlayStation glyphs appear?" "diablo_playstation_glyphs.txt"
ask_result "Did input work?" "diablo_input_worked.txt"
ask_result "Duplicate input?" "diablo_duplicate_input.txt"

stop_probe
restore_permissions || true
copy_summaries
finish_archive

echo "[guided] Done."
