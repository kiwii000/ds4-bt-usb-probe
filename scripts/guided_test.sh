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

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAPTURE_ROOT="$ROOT_DIR/captures"
RUN_DIR="$CAPTURE_ROOT/$TIMESTAMP/guided"
MODES_DIR="$RUN_DIR/modes"
PERM_DIR="$RUN_DIR/device_permissions"
ARCHIVE="$ROOT_DIR/ds4-probe-results-$TIMESTAMP.tar.gz"
GUIDED_LOG="$RUN_DIR/guided_test.log"
RESULT_SUMMARY="$RUN_DIR/result_summary.txt"
PROTON_NOTES="$RUN_DIR/proton_visibility_notes.txt"
MANIFEST="$PERM_DIR/manifest.tsv"
DISCOVERED_NODES="$PERM_DIR/discovered_physical_bt_nodes.tsv"
RESTRICTED_NODES="$PERM_DIR/restricted_nodes.tsv"
ISOLATION_LOG="$PERM_DIR/isolation.log"
RESTORE_LOG="$PERM_DIR/restore.log"

MODE_ORDER=(
  full-uhid-only
  full-uhid-plus-uinput-hidden
  uinput-only
  identity-only-uhid-plus-uinput
)

PROBE_PID=""
CURRENT_MODE=""
CURRENT_MODE_DIR=""
STATUS_FILE=""
PROBE_LOG=""
RESTORE_STATUS="not_attempted"
FINAL_CONCLUSION=""
SELECTED_FINAL_MODE=""
CLEAN_CONTROLLER_REFUSED="no"
ANY_STEAM_PASS="no"
INPUT_ONLY_SUCCESS_MODE=""

mkdir -p "$RUN_DIR" "$MODES_DIR" "$PERM_DIR"
exec > >(tee -a "$GUIDED_LOG") 2>&1

printf 'kind\tnode\tsyspath\tacl_file\tstat_file\n' >"$MANIFEST"
: >"$DISCOVERED_NODES"
: >"$RESTRICTED_NODES"
: >"$ISOLATION_LOG"
: >"$RESTORE_LOG"
: >"$RUN_DIR/modes_attempted.txt"
printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
printf 'none\n' >"$RUN_DIR/selected_final_mode.txt"
printf 'inconclusive\n' >"$RUN_DIR/final_conclusion.txt"

TARGET_USER="${DS4_TEST_USER:-${SUDO_USER:-}}"

mode_uhid_enabled() {
  case "$1" in
    uinput-only) printf 'no\n' ;;
    *) printf 'yes\n' ;;
  esac
}

mode_uinput_enabled() {
  case "$1" in
    full-uhid-only) printf 'no\n' ;;
    *) printf 'yes\n' ;;
  esac
}

mode_identity_only() {
  case "$1" in
    identity-only-uhid-plus-uinput) printf 'yes\n' ;;
    *) printf 'no\n' ;;
  esac
}

mode_probe_arg() {
  case "$1" in
    full-uhid-only) printf '%s\n' '--uhid-only' ;;
    full-uhid-plus-uinput-hidden) printf '%s\n' '--bridge' ;;
    uinput-only) printf '%s\n' '--uinput-only' ;;
    identity-only-uhid-plus-uinput) printf '%s\n' '--bridge' ;;
  esac
}

mode_description() {
  case "$1" in
    full-uhid-only)
      echo "UHID Sony DS4 only: full translated UHID reports, hard-disabled touchpad, no uinput device."
      ;;
    full-uhid-plus-uinput-hidden)
      echo "Experimental fallback: full UHID DS4 plus uinput gameplay fallback. Physical Bluetooth evdev/js is isolated; uinput is not hidden."
      ;;
    uinput-only)
      echo "Diagnostic input-only mode: no UHID DS4 identity; uinput carries gameplay input and PlayStation glyphs are not expected."
      ;;
    identity-only-uhid-plus-uinput)
      echo "Diagnostic comparison mode: UHID identity-only plus uinput gameplay, known to be duplicate-prone from v0.5.2."
      ;;
  esac
}

status_value() {
  local key="$1"
  [ -n "$STATUS_FILE" ] || return 0
  sed -n "s/^${key}=//p" "$STATUS_FILE" 2>/dev/null | tail -n 1
}

status_number() {
  local value
  value="$(status_value "$1")"
  case "${value:-0}" in
    ''|*[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$value" ;;
  esac
}

mode_status_value() {
  local mode="$1"
  local key="$2"
  local file="$MODES_DIR/$mode/bridge_status.txt"
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | tail -n 1
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
  PROBE_PID=""
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

copy_summaries() {
  mkdir -p "$RUN_DIR/summaries"
  local mode
  for mode in usb bluetooth; do
    if [ -f "$CAPTURE_ROOT/$TIMESTAMP/$mode/identity/summary.txt" ]; then
      cp "$CAPTURE_ROOT/$TIMESTAMP/$mode/identity/summary.txt" "$RUN_DIR/summaries/${mode}_summary.txt" 2>/dev/null || true
    fi
  done
}

write_result_summary() {
  local mode mode_dir status_file final selected modes_attempted
  final="$(cat "$RUN_DIR/final_conclusion.txt" 2>/dev/null || echo "${FINAL_CONCLUSION:-inconclusive}")"
  selected="$(cat "$RUN_DIR/selected_final_mode.txt" 2>/dev/null || echo "${SELECTED_FINAL_MODE:-none}")"
  modes_attempted="$(paste -sd, "$RUN_DIR/modes_attempted.txt" 2>/dev/null || echo none)"
  {
    echo "DS4 v0.6 guided result summary"
    echo "timestamp=$TIMESTAMP"
    echo "target_user=$TARGET_USER"
    echo "guided_mode=$GUIDED_MODE"
    echo "modes_attempted=${modes_attempted:-none}"
    echo "selected_final_mode=${selected:-none}"
    echo "final_conclusion=${final:-inconclusive}"
    echo "valid_diablo_test=$(cat "$RUN_DIR/valid_diablo_test.txt" 2>/dev/null || echo no)"
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
    echo "[physical Bluetooth isolation]"
    echo "manifest=$MANIFEST"
    echo "restore_log=$RESTORE_LOG"
    echo "active_physical_hidraw_restricted_final=$(cat "$RUN_DIR/active_physical_hidraw_restricted.txt" 2>/dev/null || echo no)"
    echo
    for mode in "${MODE_ORDER[@]}"; do
      mode_dir="$MODES_DIR/$mode"
      [ -d "$mode_dir" ] || continue
      status_file="$mode_dir/bridge_status.txt"
      echo "[mode:$mode]"
      echo "description=$(mode_description "$mode")"
      echo "uhid_enabled=$(cat "$mode_dir/uhid_enabled.txt" 2>/dev/null || mode_uhid_enabled "$mode")"
      echo "uhid_identity_only=$(cat "$mode_dir/uhid_identity_only.txt" 2>/dev/null || mode_identity_only "$mode")"
      echo "uinput_enabled=$(cat "$mode_dir/uinput_enabled.txt" 2>/dev/null || mode_uinput_enabled "$mode")"
      echo "physical_bt_evdev_js_isolated=$(cat "$mode_dir/physical_bt_evdev_js_isolated.txt" 2>/dev/null || echo unknown)"
      echo "active_physical_hidraw_restricted=$(cat "$mode_dir/active_physical_hidraw_restricted.txt" 2>/dev/null || echo unknown)"
      echo "uhid_ready=$(sed -n 's/^uhid_ready=//p' "$status_file" 2>/dev/null | tail -n 1 || echo unknown)"
      echo "uinput_ready=$(sed -n 's/^uinput_ready=//p' "$status_file" 2>/dev/null | tail -n 1 || echo unknown)"
      echo "bluetooth_reports_forwarded=$(sed -n 's/^bluetooth_reports_forwarded=//p' "$status_file" 2>/dev/null | tail -n 1 || echo 0)"
      echo "uhid_reports_emitted=$(sed -n 's/^uhid_reports_emitted=//p' "$status_file" 2>/dev/null | tail -n 1 || echo 0)"
      echo "uinput_events_emitted=$(sed -n 's/^uinput_events_emitted=//p' "$status_file" 2>/dev/null | tail -n 1 || echo 0)"
      echo "steam_controller_count=$(cat "$mode_dir/steam_controller_count.txt" 2>/dev/null || echo unanswered)"
      echo "steam_controller_entry_tested=$(cat "$mode_dir/steam_controller_entry_tested.txt" 2>/dev/null || echo unanswered)"
      echo "steam_tester_permanent_touchpad_contact=$(cat "$mode_dir/steam_tester_permanent_touchpad_contact.txt" 2>/dev/null || echo unanswered)"
      echo "steam_tester_buttons_sticks_worked=$(cat "$mode_dir/steam_tester_buttons_sticks_worked.txt" 2>/dev/null || echo unanswered)"
      echo "steam_duplicate_controller_confusion=$(cat "$mode_dir/steam_duplicate_controller_confusion.txt" 2>/dev/null || echo unanswered)"
      echo "steam_gate_passed=$(cat "$mode_dir/steam_gate_passed.txt" 2>/dev/null || echo no)"
      echo "diablo_controller_detected=$(cat "$mode_dir/diablo_controller_detected.txt" 2>/dev/null || echo unanswered)"
      echo "diablo_playstation_glyphs=$(cat "$mode_dir/diablo_playstation_glyphs.txt" 2>/dev/null || echo unanswered)"
      echo "diablo_input_worked=$(cat "$mode_dir/diablo_input_worked.txt" 2>/dev/null || echo unanswered)"
      echo "diablo_duplicate_input=$(cat "$mode_dir/diablo_duplicate_input.txt" 2>/dev/null || echo unanswered)"
      echo "mode_conclusion=$(cat "$mode_dir/mode_conclusion.txt" 2>/dev/null || echo unknown)"
      echo
    done
  } >"$RESULT_SUMMARY"
}

finish_archive() {
  copy_summaries
  write_result_summary
  echo "[guided] Creating results archive"
  (
    cd "$CAPTURE_ROOT" &&
      tar -czf "$ARCHIVE" "$TIMESTAMP"
  )
  echo
  echo "Send this file back: $ARCHIVE"
}

fatal_archive() {
  local reason="$1"
  echo "[guided] ERROR: $reason"
  printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
  printf '%s\n' "$reason" >"$RUN_DIR/fatal_error.txt"
  if [ -z "$FINAL_CONCLUSION" ]; then
    FINAL_CONCLUSION="inconclusive"
    printf '%s\n' "$FINAL_CONCLUSION" >"$RUN_DIR/final_conclusion.txt"
  fi
  restore_permissions || true
  stop_probe
  finish_archive
  exit 1
}

cleanup_on_signal() {
  echo
  echo "[guided] Interrupted; restoring permissions and cleaning up."
  printf 'no\n' >"$RUN_DIR/valid_diablo_test.txt"
  printf 'inconclusive\n' >"$RUN_DIR/final_conclusion.txt"
  restore_permissions || true
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

wait_for_enter_while_probe_alive() {
  local prompt="$1"
  local ignored=""
  echo
  printf '%s' "$prompt"
  while true; do
    if read -r -t 1 ignored; then
      return 0
    fi
    if ! probe_alive_for_mode "$CURRENT_MODE"; then
      echo
      echo "[guided] ERROR: probe or Bluetooth bridge exited during $CURRENT_MODE."
      printf 'probe exited during tester step\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
      return 1
    fi
  done
}

ask_choice() {
  local prompt="$1"
  local output="$2"
  shift 2
  local answer=""
  local allowed=" $* "
  while true; do
    echo
    read -r -p "$prompt ($*): " answer
    answer="${answer,,}"
    if [[ "$allowed" == *" $answer "* ]]; then
      printf '%s\n' "$answer" >"$output"
      return 0
    fi
    echo "Please answer one of: $*"
  done
}

ask_yn_unsure() {
  ask_choice "$1" "$2" yes no unsure
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
  echo "[guided] Checking uinput support"
  if [ ! -e /dev/uinput ] && [ ! -e /dev/input/uinput ] && command -v modprobe >/dev/null 2>&1; then
    echo "[guided] uinput node is absent; trying: modprobe uinput"
    modprobe uinput 2>&1 || true
  fi
  if [ -e /dev/uinput ] || [ -e /dev/input/uinput ]; then
    echo "[guided] uinput device node is available"
  else
    echo "[guided] WARNING: no uinput device node is visible; uinput modes will fail"
  fi
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

node_is_active_physical_hidraw() {
  local node="$1"
  local active_hidraw
  active_hidraw="$(status_value bluetooth_hidraw)"
  [ -n "$active_hidraw" ] && [ "$node" = "$active_hidraw" ]
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

verify_required_virtual_nodes() {
  local mode="$1"
  local uinput_node uhid_hidraw_nodes uhid_input_nodes node found_uhid
  uinput_node="$(status_value uinput_event_node)"
  uhid_hidraw_nodes="$(status_value uhid_hidraw_nodes)"
  uhid_input_nodes="$(status_value uhid_input_nodes)"
  found_uhid=0

  if [ "$(mode_uinput_enabled "$mode")" = "yes" ]; then
    if [ -z "$uinput_node" ] || [ ! -e "$uinput_node" ]; then
      echo "[isolation] virtual uinput node missing: ${uinput_node:-unknown}" | tee -a "$ISOLATION_LOG"
      return 1
    fi
  fi

  if [ "$(mode_uhid_enabled "$mode")" = "yes" ]; then
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
  fi
  return 0
}

restrict_physical_nodes() {
  local mode="$1"
  echo
  echo "[guided] Applying ACL-only physical Bluetooth evdev/js isolation for $mode"
  if ! command -v getfacl >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
    echo "[guided] ERROR: missing getfacl/setfacl/sudo; ACL-only isolation cannot run"
    return 1
  fi

  discover_physical_nodes
  printf 'no\n' >"$RUN_DIR/active_physical_hidraw_restricted.txt"
  printf 'no\n' >"$RUN_DIR/evdev_js_nodes_restricted.txt"
  : >"$RESTRICTED_NODES"

  if [ ! -s "$DISCOVERED_NODES" ]; then
    echo "[isolation] no physical evdev/js nodes to restrict; continuing with active hidraw untouched" | tee -a "$ISOLATION_LOG"
    printf 'yes\n' >"$RUN_DIR/physical_isolation_success.txt"
    return 0
  fi

  local count kind node syspath acl_file stat_file
  count="$(awk 'NR > 1 && NF { count++ } END { print count + 0 }' "$MANIFEST" 2>/dev/null || echo 0)"
  while IFS=$'\t' read -r kind node syspath; do
    [ -n "$node" ] || continue
    count=$((count + 1))
    acl_file="$PERM_DIR/acl-$count-$(basename "$node").txt"
    stat_file="$PERM_DIR/stat-$count-$(basename "$node").txt"

    if ! getfacl -p "$node" >"$acl_file" 2>>"$ISOLATION_LOG"; then
      echo "[guided] ERROR: could not back up ACL for $node"
      return 1
    fi
    stat -Lc 'node=%n owner=%U group=%G mode=%a type=%F major_minor=%t:%T' "$node" >"$stat_file" 2>>"$ISOLATION_LOG" || true
    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$node" "$syspath" "$acl_file" "$stat_file" >>"$MANIFEST"

    echo "[isolation] restricting $node for user $TARGET_USER" | tee -a "$ISOLATION_LOG"
    if ! setfacl -m "u:${TARGET_USER}:---" "$node" >>"$ISOLATION_LOG" 2>&1; then
      echo "[guided] ERROR: setfacl failed for $node"
      return 1
    fi
    if sudo -u "$TARGET_USER" test -r "$node" 2>/dev/null || sudo -u "$TARGET_USER" test -w "$node" 2>/dev/null; then
      echo "[guided] ERROR: target user can still access $node after ACL restriction"
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

  if ! verify_required_virtual_nodes "$mode"; then
    echo "[guided] ERROR: required virtual output nodes are missing after isolation"
    return 1
  fi

  printf 'yes\n' >"$RUN_DIR/physical_isolation_success.txt"
  return 0
}

snapshot_mode_runtime() {
  local mode="$1"
  local mode_dir="$MODES_DIR/$mode"
  mkdir -p "$mode_dir"
  cp "$STATUS_FILE" "$mode_dir/bridge_status_snapshot.txt" 2>/dev/null || true
  cp "$DISCOVERED_NODES" "$mode_dir/discovered_physical_bt_nodes.tsv" 2>/dev/null || true
  cp "$RESTRICTED_NODES" "$mode_dir/restricted_nodes.tsv" 2>/dev/null || true
  printf '%s\n' "$(cat "$RUN_DIR/physical_isolation_success.txt" 2>/dev/null || echo no)" >"$mode_dir/physical_isolation_success.txt"
  printf '%s\n' "$(cat "$RUN_DIR/active_physical_hidraw_restricted.txt" 2>/dev/null || echo no)" >"$mode_dir/active_physical_hidraw_restricted.txt"
  printf '%s\n' "$(cat "$RUN_DIR/evdev_js_nodes_restricted.txt" 2>/dev/null || echo no)" >"$mode_dir/physical_bt_evdev_js_isolated.txt"
}

probe_alive_for_mode() {
  local mode="$1"
  [ -n "$PROBE_PID" ] && kill -0 "$PROBE_PID" >/dev/null 2>&1 || return 1
  [ "$(status_value bluetooth_ready)" = "true" ] || return 1
  [ -n "$(status_value bluetooth_hidraw)" ] || return 1
  [ "$(status_number bluetooth_reports_forwarded)" -gt 0 ] || return 1
  [ "$(cat "$RUN_DIR/active_physical_hidraw_restricted.txt" 2>/dev/null || echo no)" != "yes" ] || return 1
  [ "$(cat "$RUN_DIR/physical_isolation_success.txt" 2>/dev/null || echo no)" = "yes" ] || return 1
  if [ "$(mode_uhid_enabled "$mode")" = "yes" ]; then
    [ "$(status_value uhid_ready)" = "true" ] || return 1
    [ -n "$(status_value uhid_hidraw_nodes)$(status_value uhid_input_nodes)" ] || return 1
  fi
  if [ "$(mode_uinput_enabled "$mode")" = "yes" ]; then
    [ "$(status_value uinput_ready)" = "true" ] || return 1
    [ -n "$(status_value uinput_event_node)" ] || return 1
  fi
  return 0
}

start_probe_for_mode() {
  local mode="$1"
  local probe_arg identity_only

  CURRENT_MODE="$mode"
  CURRENT_MODE_DIR="$MODES_DIR/$mode"
  STATUS_FILE="$CURRENT_MODE_DIR/bridge_status.txt"
  PROBE_LOG="$CURRENT_MODE_DIR/probe.log"
  mkdir -p "$CURRENT_MODE_DIR"
  : >"$STATUS_FILE"
  : >"$PROBE_LOG"
  printf '%s\n' "$mode" >>"$RUN_DIR/modes_attempted.txt"
  printf '%s\n' "$(mode_uhid_enabled "$mode")" >"$CURRENT_MODE_DIR/uhid_enabled.txt"
  printf '%s\n' "$(mode_identity_only "$mode")" >"$CURRENT_MODE_DIR/uhid_identity_only.txt"
  printf '%s\n' "$(mode_uinput_enabled "$mode")" >"$CURRENT_MODE_DIR/uinput_enabled.txt"
  mode_description "$mode" >"$CURRENT_MODE_DIR/description.txt"

  echo
  echo "============================================================"
  echo "[guided] Starting mode: $mode"
  echo "[guided] $(mode_description "$mode")"
  echo "============================================================"

  if [ "$(mode_uhid_enabled "$mode")" = "yes" ]; then
    if [ ! -e /dev/uhid ]; then
      echo "[guided] ERROR: /dev/uhid does not exist. Try: sudo modprobe uhid"
      printf 'startup_failed_no_uhid\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
      return 1
    fi
    if [ ! -w /dev/uhid ]; then
      echo "[guided] ERROR: /dev/uhid is not writable by root."
      printf 'startup_failed_uhid_not_writable\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
      return 1
    fi
  fi

  if [ "$(mode_uinput_enabled "$mode")" = "yes" ]; then
    prepare_uinput
  fi

  probe_arg="$(mode_probe_arg "$mode")"
  identity_only="$(mode_identity_only "$mode")"
  DS4_UHID_IDENTITY_ONLY="$identity_only" \
    DS4_TOUCHPAD_MODE="hard-disabled" \
    DS4_RAW_CAPTURE_DIR="$CURRENT_MODE_DIR/raw_bluetooth_reports" \
    DS4_STATUS_FILE="$STATUS_FILE" \
    "$ROOT_DIR/scripts/run_probe.sh" "$probe_arg" >"$PROBE_LOG" 2>&1 &
  PROBE_PID=$!

  echo "$PROBE_PID" >"$CURRENT_MODE_DIR/probe.pid"
  echo "[guided] Probe PID: $PROBE_PID"
  echo "[guided] Probe output: $PROBE_LOG"

  local attempt uhid_ok uinput_ok uhid_output_ok
  for attempt in $(seq 1 30); do
    if ! kill -0 "$PROBE_PID" >/dev/null 2>&1; then
      echo "[guided] ERROR: probe process exited early in mode $mode"
      printf 'startup_failed_probe_exited\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
      cat "$PROBE_LOG" 2>/dev/null || true
      return 1
    fi

    uhid_ok="yes"
    if [ "$(mode_uhid_enabled "$mode")" = "yes" ]; then
      uhid_ok="no"
      uhid_output_ok="yes"
      if [ "$(mode_identity_only "$mode")" != "yes" ] && [ "$(status_number uhid_reports_emitted)" -eq 0 ]; then
        uhid_output_ok="no"
      fi
      if [ "$(status_value uhid_ready)" = "true" ] &&
        [ -n "$(status_value uhid_hidraw_nodes)$(status_value uhid_input_nodes)" ] &&
        [ "$uhid_output_ok" = "yes" ]; then
        uhid_ok="yes"
      fi
    fi

    uinput_ok="yes"
    if [ "$(mode_uinput_enabled "$mode")" = "yes" ]; then
      uinput_ok="no"
      if [ "$(status_value uinput_ready)" = "true" ] &&
        [ -n "$(status_value uinput_event_node)" ] &&
        [ "$(status_number uinput_events_emitted)" -gt 0 ]; then
        uinput_ok="yes"
      fi
    fi

    if [ "$uhid_ok" = "yes" ] &&
      [ "$uinput_ok" = "yes" ] &&
      [ "$(status_value bluetooth_ready)" = "true" ] &&
      [ -n "$(status_value bluetooth_hidraw)" ] &&
      [ "$(status_number bluetooth_reports_read)" -gt 0 ] &&
      [ "$(status_number bluetooth_reports_forwarded)" -gt 0 ]; then
      echo "[guided] Probe startup confirmed for $mode."
      return 0
    fi
    sleep 1
  done

  echo "[guided] ERROR: startup checks did not pass for $mode"
  printf 'startup_failed_readiness\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
  cat "$PROBE_LOG" 2>/dev/null || true
  return 1
}

monitor_uhid_touchpad_idle_if_present() {
  local mode="$1"
  local event_node probe_bin output_dir status_file clean events samples
  output_dir="$CURRENT_MODE_DIR/uhid_event_touchpad_monitor"
  mkdir -p "$output_dir"
  if [ "$(mode_uhid_enabled "$mode")" != "yes" ]; then
    printf 'not_applicable_uinput_only\n' >"$CURRENT_MODE_DIR/uhid_event_monitor_status.txt"
    return 0
  fi

  event_node="$(mode_status_value "$mode" uhid_input_nodes | awk -F, '{print $1}')"
  if [ -z "$event_node" ] || [ ! -e "$event_node" ]; then
    printf 'missing\n' >"$CURRENT_MODE_DIR/uhid_event_monitor_status.txt"
    printf '0\n' >"$CURRENT_MODE_DIR/uhid_event_touchpad_events_seen.txt"
    return 0
  fi
  probe_bin="$(find_probe_binary || true)"
  if [ -z "$probe_bin" ]; then
    printf 'probe_unavailable\n' >"$CURRENT_MODE_DIR/uhid_event_monitor_status.txt"
    return 0
  fi
  echo "[guided] Optional UHID touchpad idle event monitor for $event_node"
  "$probe_bin" monitor-touchpad-events \
    --event "$event_node" \
    --output-dir "$output_dir" \
    --duration-ms 5000 \
    >"$output_dir/monitor.log" 2>&1 || true
  status_file="$output_dir/status.txt"
  clean="$(sed -n 's/^uhid_event_touchpad_idle_clean=//p' "$status_file" 2>/dev/null | tail -n 1)"
  events="$(sed -n 's/^uhid_event_touchpad_events_seen=//p' "$status_file" 2>/dev/null | tail -n 1)"
  samples="$(sed -n 's/^uhid_event_touchpad_event_samples=//p' "$status_file" 2>/dev/null | tail -n 1)"
  printf '%s\n' "${clean:-unknown}" >"$CURRENT_MODE_DIR/uhid_event_touchpad_idle_clean.txt"
  printf '%s\n' "${events:-0}" >"$CURRENT_MODE_DIR/uhid_event_touchpad_events_seen.txt"
  printf '%s\n' "${samples:-$output_dir/touchpad-events.txt}" >"$CURRENT_MODE_DIR/uhid_event_touchpad_event_samples.txt"
  if [ "${clean:-no}" = "yes" ]; then
    printf 'clean\n' >"$CURRENT_MODE_DIR/uhid_event_monitor_status.txt"
  else
    printf 'dirty_or_unknown\n' >"$CURRENT_MODE_DIR/uhid_event_monitor_status.txt"
  fi
}

ask_steam_tester_for_mode() {
  local mode="$1"
  echo
  echo "[guided] Steam Controller Tester checkpoint for mode: $mode"
  echo "[guided] Open Steam Controller Tester now. Make sure you are testing the controller entry created by this mode."
  echo "[guided] If Steam shows more than one controller, note that clearly below."
  if ! wait_for_enter_while_probe_alive "Press Enter after Steam Controller Tester is open and checked."; then
    return 1
  fi
  ask_choice "How many controllers does Steam show?" "$CURRENT_MODE_DIR/steam_controller_count.txt" 0 1 "2+" unsure
  ask_choice "Which controller entry are you testing?" "$CURRENT_MODE_DIR/steam_controller_entry_tested.txt" first second only unsure
  ask_yn_unsure "Permanent touchpad contact?" "$CURRENT_MODE_DIR/steam_tester_permanent_touchpad_contact.txt"
  ask_yn_unsure "Buttons/sticks worked?" "$CURRENT_MODE_DIR/steam_tester_buttons_sticks_worked.txt"
  ask_yn_unsure "Duplicate controller confusion?" "$CURRENT_MODE_DIR/steam_duplicate_controller_confusion.txt"
}

steam_gate_passed() {
  local mode="$1"
  local count touch buttons confusion
  count="$(cat "$CURRENT_MODE_DIR/steam_controller_count.txt" 2>/dev/null || echo unsure)"
  touch="$(cat "$CURRENT_MODE_DIR/steam_tester_permanent_touchpad_contact.txt" 2>/dev/null || echo unsure)"
  buttons="$(cat "$CURRENT_MODE_DIR/steam_tester_buttons_sticks_worked.txt" 2>/dev/null || echo unsure)"
  confusion="$(cat "$CURRENT_MODE_DIR/steam_duplicate_controller_confusion.txt" 2>/dev/null || echo unsure)"
  [ "$touch" = "no" ] || return 1
  [ "$buttons" = "yes" ] || return 1
  if [ "$mode" = "full-uhid-only" ] && [ "$count" = "2+" ] && [ "$confusion" != "no" ]; then
    return 1
  fi
  return 0
}

ask_diablo_for_mode() {
  local mode="$1"
  echo
  echo "[guided] Diablo IV checkpoint for mode: $mode"
  echo "[guided] Launch Steam if needed, make sure Steam Input is disabled for Diablo IV, launch Diablo IV, and test this same controller entry."
  if ! wait_for_enter_while_probe_alive "Press Enter after you have checked Diablo IV."; then
    return 1
  fi
  printf 'yes\n' >"$RUN_DIR/valid_diablo_test.txt"
  ask_yn_unsure "Did Diablo IV detect a controller?" "$CURRENT_MODE_DIR/diablo_controller_detected.txt"
  ask_yn_unsure "Did PlayStation glyphs appear?" "$CURRENT_MODE_DIR/diablo_playstation_glyphs.txt"
  ask_yn_unsure "Did input work?" "$CURRENT_MODE_DIR/diablo_input_worked.txt"
  ask_yn_unsure "Duplicate input?" "$CURRENT_MODE_DIR/diablo_duplicate_input.txt"
}

evaluate_mode_after_diablo() {
  local mode="$1"
  local detected glyphs input duplicate
  detected="$(cat "$CURRENT_MODE_DIR/diablo_controller_detected.txt" 2>/dev/null || echo unsure)"
  glyphs="$(cat "$CURRENT_MODE_DIR/diablo_playstation_glyphs.txt" 2>/dev/null || echo unsure)"
  input="$(cat "$CURRENT_MODE_DIR/diablo_input_worked.txt" 2>/dev/null || echo unsure)"
  duplicate="$(cat "$CURRENT_MODE_DIR/diablo_duplicate_input.txt" 2>/dev/null || echo unsure)"

  if [ "$detected" = "yes" ] && [ "$input" = "yes" ] && [ "$glyphs" = "yes" ]; then
    printf 'success\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
    FINAL_CONCLUSION="success"
    SELECTED_FINAL_MODE="$mode"
    printf '%s\n' "$FINAL_CONCLUSION" >"$RUN_DIR/final_conclusion.txt"
    printf '%s\n' "$SELECTED_FINAL_MODE" >"$RUN_DIR/selected_final_mode.txt"
    return 0
  fi

  if [ "$detected" = "yes" ] && [ "$input" = "yes" ]; then
    if [ "$mode" = "uinput-only" ]; then
      printf 'input_only_success_no_glyphs\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
      INPUT_ONLY_SUCCESS_MODE="$mode"
    else
      printf 'functional_input_no_glyphs\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
    fi
  elif [ "$mode" = "full-uhid-only" ]; then
    printf 'Diablo/Proton refused clean controller\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
    CLEAN_CONTROLLER_REFUSED="yes"
  elif [ "$duplicate" = "yes" ]; then
    printf 'duplicate_input_reported\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
  else
    printf 'diablo_failed\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
  fi
  return 1
}

try_mode() {
  local mode="$1"
  if ! start_probe_for_mode "$mode"; then
    stop_probe
    restore_permissions || true
    return 1
  fi
  if ! restrict_physical_nodes "$mode"; then
    printf 'isolation_failed\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
    snapshot_mode_runtime "$mode"
    fatal_archive "physical Bluetooth evdev/js isolation failed in mode $mode"
  fi
  snapshot_mode_runtime "$mode"
  monitor_uhid_touchpad_idle_if_present "$mode"

  echo
  echo "[guided] Mode ready: $mode"
  echo "[guided] UHID enabled: $(mode_uhid_enabled "$mode")"
  echo "[guided] uinput enabled: $(mode_uinput_enabled "$mode")"
  echo "[guided] active physical hidraw restricted: $(cat "$RUN_DIR/active_physical_hidraw_restricted.txt" 2>/dev/null || echo no)"
  echo "[guided] Bluetooth reports forwarded: $(status_number bluetooth_reports_forwarded)"

  if ! ask_steam_tester_for_mode "$mode"; then
    printf 'Steam Tester failed\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
    stop_probe
    restore_permissions || true
    return 1
  fi

  if steam_gate_passed "$mode"; then
    printf 'yes\n' >"$CURRENT_MODE_DIR/steam_gate_passed.txt"
    ANY_STEAM_PASS="yes"
  else
    printf 'no\n' >"$CURRENT_MODE_DIR/steam_gate_passed.txt"
    printf 'Steam Tester failed\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
    echo "[guided] Steam Tester gate did not pass for $mode."
    stop_probe
    restore_permissions || true
    return 1
  fi

  if ! ask_diablo_for_mode "$mode"; then
    printf 'diablo_step_interrupted\n' >"$CURRENT_MODE_DIR/mode_conclusion.txt"
    stop_probe
    restore_permissions || true
    return 1
  fi

  if evaluate_mode_after_diablo "$mode"; then
    echo "[guided] Full success in mode $mode."
    stop_probe
    restore_permissions || true
    return 0
  fi

  stop_probe
  restore_permissions || true
  return 1
}

choose_final_conclusion() {
  if [ -n "$FINAL_CONCLUSION" ]; then
    return 0
  fi
  if [ -n "$INPUT_ONLY_SUCCESS_MODE" ]; then
    FINAL_CONCLUSION="input_only_success_no_glyphs"
    SELECTED_FINAL_MODE="$INPUT_ONLY_SUCCESS_MODE"
  elif [ "$CLEAN_CONTROLLER_REFUSED" = "yes" ]; then
    FINAL_CONCLUSION="Diablo/Proton refused clean controller"
    SELECTED_FINAL_MODE="full-uhid-only"
  elif [ "$ANY_STEAM_PASS" != "yes" ]; then
    FINAL_CONCLUSION="Steam Tester failed"
    SELECTED_FINAL_MODE="none"
  else
    FINAL_CONCLUSION="inconclusive"
    SELECTED_FINAL_MODE="none"
  fi
  printf '%s\n' "$FINAL_CONCLUSION" >"$RUN_DIR/final_conclusion.txt"
  printf '%s\n' "$SELECTED_FINAL_MODE" >"$RUN_DIR/selected_final_mode.txt"
}

cat >"$RUN_DIR/expected_virtual_identity.txt" <<'EOF'
Expected virtual Proton-visible identity for UHID modes:
HID_ID=0003:0000054C:000009CC
HID_NAME=Sony Interactive Entertainment Wireless Controller
bus_type=1
input_report=0x01, 64-byte USB-style DS4

Expected uinput fallback identity where enabled:
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
v0.6 is a final convergence attempt. It tries modes in order and prioritizes one usable controller path:
  A. full-uhid-only
  B. full-uhid-plus-uinput-hidden
  C. uinput-only
  D. identity-only-uhid-plus-uinput

The primary target is Mode A: one UHID Sony DS4 with working buttons/sticks and no permanent touchpad contact.
Identity-only UHID plus uinput is diagnostic only because v0.5.2 was duplicate-prone.
EOF

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  fatal_archive "could not determine the normal Steam user; rerun with sudo from the Steam user's terminal or set DS4_TEST_USER=<username>"
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  fatal_archive "target user does not exist: $TARGET_USER"
fi
if ! command -v getfacl >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1 || ! command -v sudo >/dev/null 2>&1; then
  fatal_archive "v0.6 requires getfacl, setfacl, and sudo for temporary ACL isolation"
fi

echo "DS4 Bluetooth/USB Probe Guided Test v0.6"
echo "========================================"
echo
echo "This script collects USB/Bluetooth identity, then tries a clear runtime mode ladder."
echo "Primary mode is full-uhid-only: UHID Sony DS4 input, hard-disabled touchpad, no uinput device."
echo "Fallback modes are diagnostic and are clearly labeled before you test them."
echo
echo "[guided] project root: $ROOT_DIR"
echo "[guided] capture folder: $RUN_DIR"
echo "[guided] target Steam/Proton user: $TARGET_USER"
echo
echo "Important: close Steam completely before continuing. The script will tell you when to launch Steam/Controller Tester again."

if [ ! -e /dev/uhid ] || [ ! -w /dev/uhid ]; then
  echo "[guided] WARNING: /dev/uhid is missing or not writable. Trying: modprobe uhid"
  if command -v modprobe >/dev/null 2>&1; then
    modprobe uhid 2>&1 || true
  fi
  if [ ! -e /dev/uhid ] || [ ! -w /dev/uhid ]; then
    echo "[guided] WARNING: UHID modes will fail, but uinput-only diagnostic mode can still be attempted."
  fi
fi

pause_for_enter "Before Step 1: Close Steam completely, then press Enter."

pause_for_enter "Step 1: Connect the controller by USB, leave it untouched for the idle capture, then press Enter."
run_capture_step usb

pause_for_enter "Step 2: Disconnect USB, connect the controller by Bluetooth, then press Enter."
run_capture_step bluetooth

LAST_MODE="${MODE_ORDER[$((${#MODE_ORDER[@]} - 1))]}"
for mode in "${MODE_ORDER[@]}"; do
  if try_mode "$mode"; then
    break
  fi
  if [ "$mode" != "$LAST_MODE" ]; then
    pause_for_enter "Mode $mode did not produce full success. Press Enter to try the next mode."
  fi
done

choose_final_conclusion
finish_archive

echo "[guided] Final conclusion: $FINAL_CONCLUSION"
echo "[guided] Selected final mode: $SELECTED_FINAL_MODE"
echo "[guided] Done."
