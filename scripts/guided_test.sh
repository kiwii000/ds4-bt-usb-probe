#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -n "${DISTROBOX_ENTER_PATH:-}" ] || [ -n "${CONTAINER_ID:-}" ] || [ -n "${TOOLBOX_PATH:-}" ]; then
  echo "[guided] ERROR: Do not run this from distrobox/toolbox. Extract the GitHub Actions artifact on the Bazzite host and run it from a normal host terminal." >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "[guided] Re-running with sudo/root."
    exec sudo -E bash "$0" "$@"
  fi
  echo "[guided] ERROR: run this script with sudo/root." >&2
  exit 1
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
CAPTURE_DIR="$ROOT_DIR/captures/$TIMESTAMP"
RUN_DIR="$CAPTURE_DIR/guided"
TRUTH_ROOT="$RUN_DIR/truth"
ACTION_FILE="$TRUTH_ROOT/current_action.txt"
STATUS_FILE="$RUN_DIR/bridge_status.txt"
PROBE_LOG="$RUN_DIR/probe.log"
GUIDED_LOG="$RUN_DIR/guided_test.log"
RESULT_SUMMARY="$RUN_DIR/result_summary.txt"
PERM_DIR="$RUN_DIR/device_permissions"
MANIFEST="$PERM_DIR/manifest.tsv"
RESTORE_LOG="$PERM_DIR/restore.log"
ARCHIVE="$ROOT_DIR/ds4-probe-results-$TIMESTAMP.tar.gz"
TARGET_USER="${DS4_TEST_USER:-${SUDO_USER:-}}"
PROBE_PID=""
ARCHIVED="no"
PERMISSIONS_RESTORED="not_needed"
FINAL_CONCLUSION="inconclusive"
VALID_DIABLO_TEST="no"
FULL_UHID_STEAM_TESTER_PASS="no"
TRUTH_CAPTURE_COMPLETED="no"
REPORT_DIFF_GENERATED="no"
PHYSICAL_BT_HIDE_ATTEMPTED="no"
PHYSICAL_BT_HIDE_SUCCESS="no"
ACTIVE_PHYSICAL_HIDRAW_RESTRICTED="no"
USB_ACTIONS_CAPTURED=0
BT_ACTIONS_CAPTURED=0
VIRTUAL_ACTIONS_CAPTURED=0

ACTIONS=(
  idle
  left_stick_up left_stick_down left_stick_left left_stick_right
  right_stick_up right_stick_down right_stick_left right_stick_right
  dpad_up dpad_down dpad_left dpad_right
  cross circle square triangle
  l1 r1 l2 r2
  share options l3 r3 ps touchpad_idle_confirmation
)

ACTION_PROMPTS=(
  "Do not touch the controller."
  "Hold the left stick up." "Hold the left stick down." "Hold the left stick left." "Hold the left stick right."
  "Hold the right stick up." "Hold the right stick down." "Hold the right stick left." "Hold the right stick right."
  "Hold D-pad up." "Hold D-pad down." "Hold D-pad left." "Hold D-pad right."
  "Hold Cross/X." "Hold Circle." "Hold Square." "Hold Triangle."
  "Hold L1." "Hold R1." "Hold L2 fully." "Hold R2 fully."
  "Hold Share/Create." "Hold Options." "Hold L3." "Hold R3." "Hold PS, or type skip if the desktop intercepts it." "Do not touch the controller or touchpad."
)

mkdir -p "$RUN_DIR" "$TRUTH_ROOT/usb" "$TRUTH_ROOT/bt" "$TRUTH_ROOT/virtual" "$PERM_DIR"
: >"$GUIDED_LOG"
printf 'kind\tnode\tsyspath\tacl_file\tstat_file\n' >"$MANIFEST"
: >"$ACTION_FILE"
exec > >(tee -a "$GUIDED_LOG") 2>&1

status_value() {
  local key="$1"
  awk -F= -v wanted="$key" '$1 == wanted { value=$0; sub(/^[^=]*=/, "", value); print value; exit }' "$STATUS_FILE" 2>/dev/null || true
}

answer_value() {
  cat "$RUN_DIR/$1.txt" 2>/dev/null || echo unanswered
}

pause_for_enter() {
  local message="$1"
  read -r -p "$message " _
}

ask_choice() {
  local prompt="$1"
  local output="$2"
  shift 2
  local answer allowed
  while true; do
    read -r -p "$prompt [$*]: " answer
    answer="${answer,,}"
    for allowed in "$@"; do
      if [ "$answer" = "$allowed" ]; then
        printf '%s\n' "$answer" >"$output"
        return 0
      fi
    done
    echo "[guided] Please answer one of: $*"
  done
}

ask_yn_unsure() {
  ask_choice "$1" "$2" yes no unsure
}

set_truth_action() {
  local action="$1"
  local temporary="$ACTION_FILE.tmp"
  printf '%s\n' "$action" >"$temporary"
  mv -f "$temporary" "$ACTION_FILE"
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
  if [ -n "$PROBE_PID" ] && kill -0 "$PROBE_PID" 2>/dev/null; then
    echo "[guided] Stopping probe PID $PROBE_PID"
    kill -INT "$PROBE_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$PROBE_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$PROBE_PID" 2>/dev/null; then
      kill -TERM "$PROBE_PID" 2>/dev/null || true
    fi
    wait "$PROBE_PID" 2>/dev/null || true
  fi
  PROBE_PID=""
}

restore_permissions() {
  local kind node syspath backup stat_file failures=0 restored=0
  if [ "$(wc -l <"$MANIFEST" 2>/dev/null || echo 0)" -le 1 ]; then
    PERMISSIONS_RESTORED="not_needed"
    return 0
  fi
  echo "[guided] Restoring saved device ACLs" | tee -a "$RESTORE_LOG"
  while IFS=$'\t' read -r kind node syspath backup stat_file; do
    [ "$kind" != "kind" ] || continue
    [ -n "$node" ] || continue
    if [ ! -e "$node" ]; then
      echo "[restore] skipped missing/recreated node: $node" | tee -a "$RESTORE_LOG"
      continue
    fi
    if setfacl --restore="$backup" >>"$RESTORE_LOG" 2>&1; then
      restored=$((restored + 1))
    else
      failures=$((failures + 1))
      echo "[restore] failed: $node" | tee -a "$RESTORE_LOG"
    fi
  done <"$MANIFEST"
  if [ "$failures" -eq 0 ]; then
    PERMISSIONS_RESTORED="yes"
    echo "[guided] Device ACL restore complete; restored=$restored"
    return 0
  fi
  PERMISSIONS_RESTORED="partial_failure"
  return 1
}

write_result_summary() {
  {
    echo "probe_version=0.7.0"
    echo "v0.7_capture_pass_implemented=yes"
    echo "translator_corrected_from_truth=no"
    echo "translator_correction_requires_sonny_archive=yes"
    echo "primary_runtime_mode=full-uhid-only"
    echo "truth_capture_completed=$TRUTH_CAPTURE_COMPLETED"
    echo "usb_actions_captured=$USB_ACTIONS_CAPTURED"
    echo "bt_actions_captured=$BT_ACTIONS_CAPTURED"
    echo "virtual_actions_captured=$VIRTUAL_ACTIONS_CAPTURED"
    echo "report_diff_generated=$REPORT_DIFF_GENERATED"
    echo "physical_bt_evdev_js_hidden=$(answer_value physical_bt_evdev_js_hidden)"
    echo "physical_bt_hide_attempted=$PHYSICAL_BT_HIDE_ATTEMPTED"
    echo "physical_bt_hide_success=$PHYSICAL_BT_HIDE_SUCCESS"
    echo "active_physical_hidraw_restricted=$ACTIVE_PHYSICAL_HIDRAW_RESTRICTED"
    echo "permissions_restored=$PERMISSIONS_RESTORED"
    echo "uhid_ready=$(status_value uhid_ready)"
    echo "bluetooth_hidraw=$(status_value bluetooth_hidraw)"
    echo "bluetooth_reports_read=$(status_value bluetooth_reports_read)"
    echo "bluetooth_reports_forwarded=$(status_value bluetooth_reports_forwarded)"
    echo "truth_pairs_recorded=$(status_value truth_pairs_recorded)"
    echo "usb_idle_template_full_base=$(status_value usb_idle_template_full_base)"
    echo "keepalive_strategy=$(status_value keepalive_strategy)"
    echo "steam_controller_count=$(answer_value steam_controller_count)"
    echo "steam_virtual_ds4_identifiable=$(answer_value steam_virtual_ds4_identifiable)"
    echo "steam_tester_buttons_sticks_worked=$(answer_value steam_tester_buttons_sticks_worked)"
    echo "steam_tester_sticks_stable=$(answer_value steam_tester_sticks_stable)"
    echo "steam_tester_touchpad_clean=$(answer_value steam_tester_touchpad_clean)"
    echo "steam_tester_led_battery_stable=$(answer_value steam_tester_led_battery_stable)"
    echo "steam_duplicate_input=$(answer_value steam_duplicate_input)"
    echo "duplicate_physical_bt_seen=$(answer_value steam_duplicate_input)"
    echo "full_uhid_steam_tester_pass=$FULL_UHID_STEAM_TESTER_PASS"
    echo "steam_gate_passed=$FULL_UHID_STEAM_TESTER_PASS"
    echo "diablo_test_allowed=$VALID_DIABLO_TEST"
    echo "diablo_detected_controller=$(answer_value diablo_detected_controller)"
    echo "diablo_input_worked=$(answer_value diablo_input_worked)"
    echo "diablo_playstation_glyphs=$(answer_value diablo_playstation_glyphs)"
    echo "diablo_duplicate_input=$(answer_value diablo_duplicate_input)"
    echo "final_conclusion=$FINAL_CONCLUSION"
    echo
    echo "v0.7 capture pass implemented; translator correction requires Sonny's truth archive."
  } >"$RESULT_SUMMARY"
}

finish_archive() {
  if [ "$ARCHIVED" = "yes" ]; then
    return
  fi
  stop_probe
  restore_permissions || true
  write_result_summary
  echo "[guided] Creating results archive"
  (
    cd "$ROOT_DIR" &&
      tar -czf "$ARCHIVE" "captures/$TIMESTAMP"
  )
  ARCHIVED="yes"
  echo
  echo "Send this file back: $ARCHIVE"
}

fatal_archive() {
  local reason="$1"
  echo "[guided] ERROR: $reason"
  printf '%s\n' "$reason" >"$RUN_DIR/failure_reason.txt"
  FINAL_CONCLUSION="capture_or_gate_failure"
  finish_archive
  exit 1
}

on_signal() {
  FINAL_CONCLUSION="interrupted"
  printf 'interrupted\n' >"$RUN_DIR/failure_reason.txt"
  finish_archive
  exit 130
}

on_exit() {
  if [ "$ARCHIVED" != "yes" ]; then
    finish_archive
  fi
}

trap on_signal INT TERM
trap on_exit EXIT

run_identity_capture() {
  local mode="$1"
  local log="$RUN_DIR/${mode}_capture_output.log"
  echo "[guided] Capturing $mode identity"
  DS4_CAPTURE_TIMESTAMP="$TIMESTAMP" "$ROOT_DIR/scripts/collect_ds4_identity.sh" "$mode" 2>&1 | tee "$log"
  local result="${PIPESTATUS[0]}"
  printf '%s\n' "$result" >"$RUN_DIR/${mode}_capture_exit_status.txt"
  if [ "$result" -ne 0 ]; then
    fatal_archive "$mode identity capture failed; send the archive for diagnosis"
  fi
}

first_usb_hidraw() {
  awk '{print $1; exit}' "$CAPTURE_DIR/usb/identity/hidraw_matches.txt" 2>/dev/null || true
}

capture_usb_actions() {
  local bin="$1"
  local hidraw="$2"
  local index action prompt response count
  echo
  echo "[guided] USB truth capture: each action records the real working USB report for four seconds."
  echo "[guided] Press Enter, then hold the requested action steadily until capture finishes."
  for index in "${!ACTIONS[@]}"; do
    action="${ACTIONS[$index]}"
    prompt="${ACTION_PROMPTS[$index]}"
    if [ "$action" = "ps" ]; then
      read -r -p "[USB action $((index + 1))/${#ACTIONS[@]}] $prompt Press Enter to capture or type skip: " response
      if [ "${response,,}" = "skip" ]; then
        echo "skipped" >"$TRUTH_ROOT/usb/ps.skipped"
        continue
      fi
    else
      pause_for_enter "[USB action $((index + 1))/${#ACTIONS[@]}] $prompt Press Enter to capture."
    fi
    "$bin" capture-input \
      --hidraw "$hidraw" \
      --action "$action" \
      --output "$TRUTH_ROOT/usb/$action" \
      --duration-ms 4000 \
      --report-id 0x01 \
      --report-size 64 | tee "$TRUTH_ROOT/usb/$action.capture.log"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
      fatal_archive "USB truth capture failed for action $action"
    fi
    count="$(wc -l <"$TRUTH_ROOT/usb/$action.txt" 2>/dev/null || echo 0)"
    if [ "$count" -lt 5 ]; then
      fatal_archive "USB action $action produced only $count valid reports; at least 5 are required"
    fi
    USB_ACTIONS_CAPTURED=$((USB_ACTIONS_CAPTURED + 1))
  done
}

wait_for_bridge_ready() {
  local deadline=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
      cat "$PROBE_LOG" 2>/dev/null || true
      return 1
    fi
    if [ "$(status_value uhid_ready)" = "true" ] &&
       [ "$(status_value bluetooth_ready)" = "true" ] &&
       [ "$(status_value bluetooth_reports_forwarded)" -gt 0 ] 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

start_full_uhid_bridge() {
  echo
  echo "[guided] Step 3: Starting v0.7 full-uhid-only bridge and paired truth recording."
  DS4_STATUS_FILE="$STATUS_FILE" \
    DS4_RAW_CAPTURE_DIR="$RUN_DIR/raw_bluetooth_reports" \
    DS4_TRUTH_CAPTURE_ROOT="$TRUTH_ROOT" \
    DS4_TRUTH_ACTION_FILE="$ACTION_FILE" \
    DS4_TOUCHPAD_MODE="hard-disabled" \
    "$ROOT_DIR/scripts/run_probe.sh" --uhid-only >"$PROBE_LOG" 2>&1 &
  PROBE_PID=$!
  echo "[guided] Probe PID: $PROBE_PID"
  if ! wait_for_bridge_ready; then
    cat "$PROBE_LOG" 2>/dev/null || true
    fatal_archive "full-uhid-only bridge did not become ready and forward Bluetooth reports"
  fi
  echo "[guided] Full-UHID bridge ready and forwarding."
}

capture_bluetooth_actions() {
  local index action prompt response bt_count virtual_count
  echo
  echo "[guided] Bluetooth/virtual truth capture: the bridge records each raw BT report and the exact emitted virtual USB report as a paired sequence."
  for index in "${!ACTIONS[@]}"; do
    action="${ACTIONS[$index]}"
    prompt="${ACTION_PROMPTS[$index]}"
    if [ "$action" = "ps" ]; then
      read -r -p "[BT action $((index + 1))/${#ACTIONS[@]}] $prompt Press Enter to capture or type skip: " response
      if [ "${response,,}" = "skip" ]; then
        echo "skipped" >"$TRUTH_ROOT/bt/ps.skipped"
        echo "skipped" >"$TRUTH_ROOT/virtual/ps.skipped"
        continue
      fi
    else
      pause_for_enter "[BT action $((index + 1))/${#ACTIONS[@]}] $prompt Press Enter to capture."
    fi
    if ! kill -0 "$PROBE_PID" 2>/dev/null; then
      fatal_archive "bridge exited during Bluetooth truth capture for action $action"
    fi
    set_truth_action "$action"
    sleep 4
    set_truth_action ""
    bt_count="$(wc -l <"$TRUTH_ROOT/bt/$action.txt" 2>/dev/null || echo 0)"
    virtual_count="$(wc -l <"$TRUTH_ROOT/virtual/$action.txt" 2>/dev/null || echo 0)"
    echo "[guided] action=$action paired BT=$bt_count virtual=$virtual_count"
    if [ "$bt_count" -lt 5 ] || [ "$virtual_count" -lt 5 ] || [ "$bt_count" -ne "$virtual_count" ]; then
      fatal_archive "action $action did not produce at least 5 matched BT/virtual reports"
    fi
    BT_ACTIONS_CAPTURED=$((BT_ACTIONS_CAPTURED + 1))
    VIRTUAL_ACTIONS_CAPTURED=$((VIRTUAL_ACTIONS_CAPTURED + 1))
  done
  TRUTH_CAPTURE_COMPLETED="yes"
}

generate_truth_diff() {
  local bin="$1"
  echo "[guided] Generating USB vs translated virtual truth comparison."
  if "$bin" compare-truth --truth-root "$TRUTH_ROOT" | tee "$TRUTH_ROOT/compare.log"; then
    REPORT_DIFF_GENERATED="yes"
  else
    fatal_archive "truth comparison failed"
  fi
}

physical_node_matches() {
  local node="$1"
  local properties
  properties="$(udevadm info --query=property --name="$node" 2>/dev/null || true)"
  printf '%s\n' "$properties" | grep -Eiq 'HID_ID=0005:0000054[Cc]:000009[Cc][Cc]|PRODUCT=5/54[cC]/9[cC][cC]/'
}

backup_and_restrict_node() {
  local node="$1"
  local kind syspath stat_file
  local backup="$PERM_DIR/$(printf '%s' "$node" | tr '/' '_').acl"
  case "$node" in
    /dev/hidraw*) kind="hidraw" ;;
    /dev/input/event*) kind="event" ;;
    /dev/input/js*) kind="js" ;;
    *) kind="other" ;;
  esac
  syspath="$(udevadm info --query=path --name="$node" 2>/dev/null || true)"
  if [ -n "$syspath" ]; then
    syspath="/sys$syspath"
  fi
  stat_file="$PERM_DIR/$(printf '%s' "$node" | tr '/' '_').stat"
  getfacl -p "$node" >"$backup" || return 1
  stat -Lc 'node=%n owner=%U group=%G mode=%a type=%F major_minor=%t:%T' "$node" >"$stat_file" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$node" "$syspath" "$backup" "$stat_file" >>"$MANIFEST"
  setfacl -m "u:${TARGET_USER}:---" "$node"
}

restrict_physical_evdev_js() {
  local node restricted=0
  : >"$RUN_DIR/physical_bt_evdev_js_nodes.txt"
  for node in /dev/input/event* /dev/input/js*; do
    [ -e "$node" ] || continue
    if physical_node_matches "$node"; then
      echo "$node" >>"$RUN_DIR/physical_bt_evdev_js_nodes.txt"
      if ! backup_and_restrict_node "$node"; then
        fatal_archive "could not ACL-isolate physical Bluetooth node $node"
      fi
      restricted=$((restricted + 1))
    fi
  done
  echo "$restricted" >"$RUN_DIR/physical_bt_evdev_js_restricted_count.txt"
  printf 'yes\n' >"$RUN_DIR/physical_bt_evdev_js_hidden.txt"
  echo "[guided] Physical Bluetooth evdev/js nodes isolated: $restricted. Active hidraw remains readable by the bridge."
}

restore_one_node() {
  local node="$1"
  local line backup
  line="$(awk -F'\t' -v wanted="$node" '$2 == wanted { print; exit }' "$MANIFEST")"
  backup="$(printf '%s\n' "$line" | awk -F'\t' '{print $4}')"
  [ -n "$line" ] && [ -f "$backup" ] && [ -e "$node" ] && setfacl --restore="$backup"
}

optional_active_hidraw_hide() {
  local answer hidraw before after
  hidraw="$(status_value bluetooth_hidraw)"
  ask_choice "Optional experiment: temporarily hide the active physical Bluetooth hidraw after the bridge owns it?" "$RUN_DIR/active_hidraw_hide_answer.txt" yes no
  answer="$(answer_value active_hidraw_hide_answer)"
  if [ "$answer" != "yes" ]; then
    echo "[guided] Active physical hidraw isolation skipped."
    return
  fi
  PHYSICAL_BT_HIDE_ATTEMPTED="yes"
  if [ -z "$hidraw" ] || [ ! -e "$hidraw" ]; then
    echo "[guided] Active hidraw was not available for optional isolation."
    return
  fi
  before="$(status_value bluetooth_reports_forwarded)"
  if ! backup_and_restrict_node "$hidraw"; then
    echo "[guided] Optional active hidraw isolation failed before health check."
    restore_one_node "$hidraw" || fatal_archive "optional active hidraw isolation failed and its ACL could not be restored"
    return
  fi
  ACTIVE_PHYSICAL_HIDRAW_RESTRICTED="yes"
  echo "[guided] Active hidraw restricted. Health-checking bridge forwarding for five seconds."
  sleep 5
  after="$(status_value bluetooth_reports_forwarded)"
  if kill -0 "$PROBE_PID" 2>/dev/null && [ "${after:-0}" -gt "${before:-0}" ] 2>/dev/null; then
    PHYSICAL_BT_HIDE_SUCCESS="yes"
    echo "[guided] Optional active hidraw isolation health check passed."
  else
    echo "[guided] Optional active hidraw isolation disrupted forwarding; restoring it immediately."
    restore_one_node "$hidraw" || fatal_archive "active hidraw isolation disrupted forwarding and its ACL could not be restored"
    ACTIVE_PHYSICAL_HIDRAW_RESTRICTED="no"
    PHYSICAL_BT_HIDE_SUCCESS="no"
  fi
}

steam_tester_gate() {
  echo
  echo "Before launching Diablo IV, open Steam Controller Tester for this controller."
  echo "Confirm the identifiable virtual Sony/DS4 controller has steady controls, a clean touchpad, stable LED/battery display, and no duplicate input."
  pause_for_enter "Press Enter after checking Steam Controller Tester."
  ask_choice "How many controllers does Steam show?" "$RUN_DIR/steam_controller_count.txt" 0 1 "2+" unsure
  ask_yn_unsure "Can you identify the virtual Sony/DS4 controller?" "$RUN_DIR/steam_virtual_ds4_identifiable.txt"
  ask_yn_unsure "Do buttons and sticks work?" "$RUN_DIR/steam_tester_buttons_sticks_worked.txt"
  ask_yn_unsure "Do held sticks remain steady instead of snapping toward center?" "$RUN_DIR/steam_tester_sticks_stable.txt"
  ask_yn_unsure "Is the touchpad idle and clean with no permanent contact?" "$RUN_DIR/steam_tester_touchpad_clean.txt"
  ask_yn_unsure "Does LED/battery behavior appear stable?" "$RUN_DIR/steam_tester_led_battery_stable.txt"
  ask_yn_unsure "Is there duplicate input/controller confusion?" "$RUN_DIR/steam_duplicate_input.txt"
  if [ "$(answer_value steam_virtual_ds4_identifiable)" = "yes" ] &&
     [ "$(answer_value steam_tester_buttons_sticks_worked)" = "yes" ] &&
     [ "$(answer_value steam_tester_sticks_stable)" = "yes" ] &&
     [ "$(answer_value steam_tester_touchpad_clean)" = "yes" ] &&
     [ "$(answer_value steam_tester_led_battery_stable)" = "yes" ] &&
     [ "$(answer_value steam_duplicate_input)" = "no" ]; then
    FULL_UHID_STEAM_TESTER_PASS="yes"
    return 0
  fi
  return 1
}

run_diablo_test() {
  VALID_DIABLO_TEST="yes"
  echo
  echo "Now launch Diablo IV. Make sure Steam Input is disabled for Diablo IV, then test the same virtual Sony/DS4 controller."
  pause_for_enter "Press Enter after checking Diablo IV."
  ask_yn_unsure "Did Diablo IV detect a controller?" "$RUN_DIR/diablo_detected_controller.txt"
  ask_yn_unsure "Did PlayStation glyphs appear?" "$RUN_DIR/diablo_playstation_glyphs.txt"
  ask_yn_unsure "Did input work?" "$RUN_DIR/diablo_input_worked.txt"
  ask_yn_unsure "Was there duplicate input?" "$RUN_DIR/diablo_duplicate_input.txt"
  if [ "$(answer_value diablo_detected_controller)" = "yes" ] &&
     [ "$(answer_value diablo_input_worked)" = "yes" ] &&
     [ "$(answer_value diablo_playstation_glyphs)" = "yes" ]; then
    FINAL_CONCLUSION="success"
  elif [ "$(answer_value diablo_input_worked)" = "yes" ]; then
    FINAL_CONCLUSION="input_worked_no_playstation_glyphs"
  else
    FINAL_CONCLUSION="Diablo/Proton refused clean controller"
  fi
}

echo "ds4-bt-usb-probe v0.7 truth capture foundation"
echo "This guided run has one gameplay target: full-uhid-only."
echo "It will collect real USB, Bluetooth, and exact emitted virtual reports before the Steam/Diablo gate."
echo "v0.7 capture pass implemented; translator correction requires Sonny's truth archive."
echo "[guided] capture folder: $CAPTURE_DIR"

if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  fatal_archive "could not determine the normal Steam user; run with sudo from that user's host terminal or set DS4_TEST_USER"
fi
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  fatal_archive "target Steam user does not exist: $TARGET_USER"
fi
for command in udevadm getfacl setfacl sudo tar; do
  command -v "$command" >/dev/null 2>&1 || fatal_archive "required command is missing: $command"
done
if [ ! -e /dev/uhid ]; then
  echo "[guided] /dev/uhid is missing; trying: modprobe uhid"
  modprobe uhid 2>/dev/null || true
fi
if [ ! -e /dev/uhid ] || [ ! -w /dev/uhid ]; then
  fatal_archive "/dev/uhid is missing or not writable. Run sudo modprobe uhid, then rerun sudo ./scripts/guided_test.sh"
fi

BIN="$(find_probe_binary || true)"
if [ -z "$BIN" ]; then
  fatal_archive "compiled probe binary is missing. Download the latest green Actions artifact or build on the Bazzite host"
fi

pause_for_enter "Before Step 1: close Steam completely, then press Enter."
pause_for_enter "Step 1: connect the controller by USB and press Enter."
run_identity_capture usb
USB_HIDRAW="$(first_usb_hidraw)"
if [ -z "$USB_HIDRAW" ] || [ ! -e "$USB_HIDRAW" ]; then
  fatal_archive "could not find the captured real USB DS4 hidraw node"
fi
capture_usb_actions "$BIN" "$USB_HIDRAW"

pause_for_enter "Step 2: disconnect USB, connect the controller by Bluetooth, and press Enter."
run_identity_capture bluetooth
start_full_uhid_bridge
capture_bluetooth_actions
generate_truth_diff "$BIN"

echo "[guided] Restricting physical Bluetooth evdev/js nodes while preserving the active bridge hidraw reader."
restrict_physical_evdev_js
optional_active_hidraw_hide

if ! kill -0 "$PROBE_PID" 2>/dev/null ||
   [ "$(status_value uhid_ready)" != "true" ] ||
   [ "$(status_value bluetooth_reports_forwarded)" -le 0 ] 2>/dev/null; then
  fatal_archive "full-UHID bridge was not healthy after truth capture and isolation"
fi

if steam_tester_gate; then
  run_diablo_test
else
  FINAL_CONCLUSION="Steam Tester failed"
  echo "[guided] Steam Controller Tester gate did not pass. Diablo IV will not be launched in this run."
fi

finish_archive
echo "[guided] Final conclusion: $FINAL_CONCLUSION"
echo "[guided] v0.7 capture pass implemented; translator correction requires Sonny's truth archive."
