#!/usr/bin/env bash
set -uo pipefail

if [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -n "${DISTROBOX_ENTER_PATH:-}" ] || [ -n "${CONTAINER_ID:-}" ] || [ -n "${TOOLBOX_PATH:-}" ]; then
  echo "[collect] ERROR: Do not run this from distrobox/toolbox. Extract the GitHub Actions artifact on the Bazzite host and run it from a normal host terminal." >&2
  exit 1
fi

MODE="${1:-}"
case "$MODE" in
  usb|bluetooth) ;;
  *)
    echo "usage: sudo ./scripts/collect_ds4_identity.sh <usb|bluetooth>" >&2
    exit 2
    ;;
esac

if [ "$(id -u)" -ne 0 ]; then
  echo "[collect] ERROR: this script must be run with sudo/root so it can read hidraw, input, and kernel diagnostics." >&2
  echo "[collect] Try: sudo ./scripts/collect_ds4_identity.sh $MODE" >&2
  exit 1
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TIMESTAMP="${DS4_CAPTURE_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
BASE_DIR="$ROOT_DIR/captures/$TIMESTAMP/$MODE"

mkdir -p \
  "$BASE_DIR/system" \
  "$BASE_DIR/usb" \
  "$BASE_DIR/input/event-udev" \
  "$BASE_DIR/input/event-sysfs" \
  "$BASE_DIR/hidraw/hidraw-udev" \
  "$BASE_DIR/hidraw/report-descriptors" \
  "$BASE_DIR/feature_reports" \
  "$BASE_DIR/identity" \
  "$BASE_DIR/logs" \
  "$BASE_DIR/evtest"

LOG_FILE="$BASE_DIR/collect.log"
exec > >(tee -a "$LOG_FILE") 2>&1

EXPECTED_BUS="0003"
EXPECTED_PRODUCT_BUS="3"
if [ "$MODE" = "bluetooth" ]; then
  EXPECTED_BUS="0005"
  EXPECTED_PRODUCT_BUS="5"
fi
MATCH_FOUND=0

echo "[collect] mode=$MODE"
echo "[collect] output=$BASE_DIR"
echo "[collect] started=$(date -Is)"

run_to_file() {
  local output="$1"
  shift
  echo "[collect] running: $*"
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n\n'
    "$@"
  } >"$output" 2>&1
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "[collect] command exited $status: $*" | tee -a "$output"
  fi
}

run_shell_to_file() {
  local output="$1"
  local command="$2"
  echo "[collect] running shell: $command"
  {
    printf '$ %s\n\n' "$command"
    bash -c "$command"
  } >"$output" 2>&1
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "[collect] shell command exited $status" | tee -a "$output"
  fi
}

have() {
  command -v "$1" >/dev/null 2>&1
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

hex_to_prefixed() {
  local raw
  raw="$(printf '%s' "$1" | tr -cd '[:xdigit:]' | tr '[:lower:]' '[:upper:]')"
  if [ -z "$raw" ]; then
    return 1
  fi
  printf '0x%04x\n' "$((16#$raw))"
}

dump_input_sysfs() {
  local sys="$1"
  echo "sysfs=$sys"
  if have readlink; then
    readlink -f "$sys" 2>/dev/null || true
  fi
  echo

  local file
  for file in name phys uniq properties modalias uevent id/bustype id/vendor id/product id/version; do
    if [ -e "$sys/$file" ]; then
      echo "## $file"
      cat "$sys/$file" 2>&1 || true
      echo
    fi
  done

  if [ -d "$sys/capabilities" ]; then
    for file in "$sys"/capabilities/*; do
      [ -e "$file" ] || continue
      echo "## capabilities/$(basename "$file")"
      cat "$file" 2>&1 || true
      echo
    done
  fi
}

dump_hidraw_sysfs() {
  local sys="$1"
  echo "sysfs=$sys"
  if have readlink; then
    readlink -f "$sys" 2>/dev/null || true
  fi
  echo

  local file
  for file in uevent modalias report_descriptor; do
    if [ -e "$sys/$file" ]; then
      echo "## $file"
      if [ "$file" = "report_descriptor" ]; then
        od -An -tx1 -v "$sys/$file" 2>&1 || true
      else
        cat "$sys/$file" 2>&1 || true
      fi
      echo
    fi
  done
}

is_matching_hidraw() {
  local sys="$1"
  local uevent="$sys/uevent"
  [ -r "$uevent" ] || return 1
  grep -Eiq "HID_ID=${EXPECTED_BUS}:0000054C:000009CC" "$uevent"
}

record_identity_from_hidraw() {
  local sys="$1"
  local uevent="$sys/uevent"
  [ -r "$uevent" ] || return 0

  local hid_id hid_name bus vendor product vendor_product
  hid_id="$(sed -n 's/^HID_ID=//p' "$uevent" | head -n 1)"
  hid_name="$(sed -n 's/^HID_NAME=//p' "$uevent" | head -n 1)"

  if [ -n "$hid_id" ]; then
    bus="${hid_id%%:*}"
    vendor_product="${hid_id#*:}"
    vendor="${vendor_product%%:*}"
    product="${vendor_product##*:}"
    hex_to_prefixed "$bus" >"$BASE_DIR/identity/bus.txt" 2>/dev/null || true
    hex_to_prefixed "$vendor" >"$BASE_DIR/identity/vendor.txt" 2>/dev/null || true
    hex_to_prefixed "$product" >"$BASE_DIR/identity/product.txt" 2>/dev/null || true
  fi

  if [ -n "$hid_name" ] && [ ! -s "$BASE_DIR/identity/name.txt" ]; then
    printf '%s\n' "$hid_name" >"$BASE_DIR/identity/name.txt"
  fi
}

record_identity_from_event_udev() {
  local file="$1"
  local product_line name_line bus vendor product version
  product_line="$(sed -n 's/^E: PRODUCT=//p' "$file" | head -n 1)"
  [ -n "$product_line" ] || return 0

  IFS='/' read -r bus vendor product version _rest <<<"$product_line"
  [ -n "$bus" ] && [ -n "$vendor" ] && [ -n "$product" ] || return 0

  local vendor_lc product_lc
  vendor_lc="$(printf '%s' "$vendor" | tr '[:upper:]' '[:lower:]')"
  product_lc="$(printf '%s' "$product" | tr '[:upper:]' '[:lower:]')"
  [ "$bus" = "$EXPECTED_PRODUCT_BUS" ] || return 0
  [ "$vendor_lc" = "54c" ] || [ "$vendor_lc" = "054c" ] || return 0
  [ "$product_lc" = "9cc" ] || [ "$product_lc" = "09cc" ] || return 0
  MATCH_FOUND=1

  hex_to_prefixed "$bus" >"$BASE_DIR/identity/bus.txt" 2>/dev/null || true
  hex_to_prefixed "$vendor" >"$BASE_DIR/identity/vendor.txt" 2>/dev/null || true
  hex_to_prefixed "$product" >"$BASE_DIR/identity/product.txt" 2>/dev/null || true
  if [ -n "${version:-}" ]; then
    hex_to_prefixed "$version" >"$BASE_DIR/identity/version.txt" 2>/dev/null || true
    hex_to_prefixed "$version" >"$BASE_DIR/identity/input_version.txt" 2>/dev/null || true
  fi

  name_line="$(sed -n 's/^E: NAME=//p' "$file" | head -n 1 | sed 's/^"//; s/"$//')"
  if [ -n "$name_line" ] && [ ! -s "$BASE_DIR/identity/name.txt" ]; then
    printf '%s\n' "$name_line" >"$BASE_DIR/identity/name.txt"
  fi
}

run_to_file "$BASE_DIR/system/uname.txt" uname -a
if have rpm-ostree; then
  run_to_file "$BASE_DIR/system/rpm-ostree-status.txt" rpm-ostree status
else
  echo "rpm-ostree not found" >"$BASE_DIR/system/rpm-ostree-status.txt"
fi

if have lsusb; then
  run_to_file "$BASE_DIR/usb/lsusb-054c-09cc-v.txt" lsusb -d 054c:09cc -v
  if [ "$MODE" = "usb" ] && lsusb -d 054c:09cc >/dev/null 2>&1; then
    MATCH_FOUND=1
    bcd_device="$(awk '$1 == "bcdDevice" { print $2; exit }' "$BASE_DIR/usb/lsusb-054c-09cc-v.txt" | tr -cd '[:xdigit:].' || true)"
    bcd_digits="$(printf '%s' "$bcd_device" | tr -d '.')"
    if [ -n "$bcd_digits" ]; then
      printf '0x%04s\n' "$bcd_digits" | tr ' ' '0' >"$BASE_DIR/identity/usb_version.txt"
    fi
  fi
else
  echo "lsusb not found" >"$BASE_DIR/usb/lsusb-054c-09cc-v.txt"
fi

if [ -r /proc/bus/input/devices ]; then
  run_to_file "$BASE_DIR/input/proc-bus-input-devices.txt" cat /proc/bus/input/devices
else
  echo "/proc/bus/input/devices is not readable" >"$BASE_DIR/input/proc-bus-input-devices.txt"
fi

echo "[collect] collecting /dev/input/event* udev and sysfs"
: >"$BASE_DIR/input/event-syspaths.txt"
for event_dev in /dev/input/event*; do
  [ -e "$event_dev" ] || continue
  event_base="$(basename "$event_dev")"
  sys="/sys/class/input/$event_base/device"
  echo "$event_dev -> $sys" >>"$BASE_DIR/input/event-syspaths.txt"

  if have udevadm; then
    run_to_file "$BASE_DIR/input/event-udev/$event_base.txt" udevadm info --query=all --name="$event_dev"
    record_identity_from_event_udev "$BASE_DIR/input/event-udev/$event_base.txt"
  else
    echo "udevadm not found" >"$BASE_DIR/input/event-udev/$event_base.txt"
  fi

  dump_input_sysfs "$sys" >"$BASE_DIR/input/event-sysfs/$event_base.txt" 2>&1
done

echo "[collect] collecting /dev/hidraw* udev, sysfs, and matching report descriptors"
: >"$BASE_DIR/hidraw/hidraw-syspaths.txt"
: >"$BASE_DIR/identity/hidraw_matches.txt"
first_descriptor=""
for hidraw_dev in /dev/hidraw*; do
  [ -e "$hidraw_dev" ] || continue
  hidraw_base="$(basename "$hidraw_dev")"
  sys="/sys/class/hidraw/$hidraw_base/device"
  echo "$hidraw_dev -> $sys" >>"$BASE_DIR/hidraw/hidraw-syspaths.txt"

  if have udevadm; then
    run_to_file "$BASE_DIR/hidraw/hidraw-udev/$hidraw_base.txt" udevadm info --query=all --name="$hidraw_dev"
  else
    echo "udevadm not found" >"$BASE_DIR/hidraw/hidraw-udev/$hidraw_base.txt"
  fi

  dump_hidraw_sysfs "$sys" >"$BASE_DIR/hidraw/$hidraw_base-sysfs.txt" 2>&1

  if is_matching_hidraw "$sys"; then
    MATCH_FOUND=1
    echo "$hidraw_dev -> $sys" | tee -a "$BASE_DIR/identity/hidraw_matches.txt"
    record_identity_from_hidraw "$sys"

    if [ "$MODE" = "usb" ]; then
      probe_bin="$(find_probe_binary || true)"
      if [ -n "$probe_bin" ]; then
        echo "[collect] capturing USB DS4 feature reports from $hidraw_dev"
        "$probe_bin" capture-features \
          --hidraw "$hidraw_dev" \
          --output-dir "$BASE_DIR/feature_reports" \
          >"$BASE_DIR/feature_reports/$hidraw_base-capture.log" 2>&1 || {
            echo "[collect] WARNING: feature report capture failed for $hidraw_dev"
            cat "$BASE_DIR/feature_reports/$hidraw_base-capture.log" || true
          }
        echo "[collect] capturing USB DS4 idle input reports from $hidraw_dev; do not touch the controller"
        mkdir -p "$BASE_DIR/idle_input"
        "$probe_bin" capture-idle-input \
          --hidraw "$hidraw_dev" \
          --output-dir "$BASE_DIR/idle_input" \
          --duration-ms 5000 \
          >"$BASE_DIR/idle_input/$hidraw_base-idle-capture.log" 2>&1 || {
            echo "[collect] WARNING: idle input capture failed for $hidraw_dev"
            cat "$BASE_DIR/idle_input/$hidraw_base-idle-capture.log" || true
          }
      else
        echo "[collect] WARNING: probe binary unavailable; USB feature reports and idle input template were not captured"
      fi
    fi

    if [ -r "$sys/report_descriptor" ]; then
      desc_bin="$BASE_DIR/hidraw/report-descriptors/$hidraw_base-report_descriptor.bin"
      desc_hex="$BASE_DIR/hidraw/report-descriptors/$hidraw_base-report_descriptor.hex"
      if cp "$sys/report_descriptor" "$desc_bin" 2>"$desc_bin.copy-error.txt"; then
        od -An -tx1 -v "$desc_bin" >"$desc_hex" 2>&1 || true
        echo "[collect] saved descriptor: $desc_bin"

        if [ -z "$first_descriptor" ]; then
          first_descriptor="$desc_bin"
          cp "$desc_bin" "$BASE_DIR/hidraw/report_descriptor.bin" 2>/dev/null || true
          cp "$desc_hex" "$BASE_DIR/hidraw/report_descriptor.hex" 2>/dev/null || true
          cp "$desc_bin" "$BASE_DIR/report_descriptor.bin" 2>/dev/null || true
          cp "$desc_hex" "$BASE_DIR/report_descriptor.hex" 2>/dev/null || true
        fi
      else
        echo "[collect] could not copy descriptor for $hidraw_dev"
      fi
    else
      echo "[collect] report descriptor is not readable for $hidraw_dev"
    fi
  fi
done

{
  echo "mode=$MODE"
  echo "timestamp=$TIMESTAMP"
  for file in bus vendor product usb_version input_version version name; do
    if [ -s "$BASE_DIR/identity/$file.txt" ]; then
      printf '%s=' "$file"
      cat "$BASE_DIR/identity/$file.txt"
    fi
  done
  if [ -n "$first_descriptor" ]; then
    echo "descriptor=$first_descriptor"
  else
    echo "descriptor=not captured"
  fi
  if [ "$MODE" = "usb" ]; then
    for report_id in 0x02 0x12 0x81 0xa3; do
      if [ -s "$BASE_DIR/feature_reports/$report_id.bin" ]; then
        echo "feature_$report_id=captured"
      else
        echo "feature_$report_id=not captured"
      fi
    done
  fi
} >"$BASE_DIR/identity/summary.txt"

MATCH_PATTERN='sony|playstation|dualshock|054C|054c|09CC|09cc|hidraw|uhid|uinput|evdev'
if have dmesg; then
  run_shell_to_file "$BASE_DIR/logs/dmesg-matches.txt" "dmesg --ctime --color=never 2>&1 | grep -Ei '$MATCH_PATTERN' || true"
else
  echo "dmesg not found" >"$BASE_DIR/logs/dmesg-matches.txt"
fi

if have journalctl; then
  run_shell_to_file "$BASE_DIR/logs/journal-matches.txt" "journalctl -k -b --no-pager 2>&1 | grep -Ei '$MATCH_PATTERN' || true"
else
  echo "journalctl not found" >"$BASE_DIR/logs/journal-matches.txt"
fi

if have evtest; then
  for event_dev in /dev/input/event*; do
    [ -e "$event_dev" ] || continue
    event_base="$(basename "$event_dev")"
    if have timeout; then
      run_to_file "$BASE_DIR/evtest/$event_base-info.txt" timeout 5s evtest --info "$event_dev"
    else
      run_to_file "$BASE_DIR/evtest/$event_base-info.txt" evtest --info "$event_dev"
    fi
  done
else
  echo "evtest not found; see input/event-sysfs/* for capability files" >"$BASE_DIR/evtest/README.txt"
fi

echo "[collect] finished=$(date -Is)"
echo "[collect] capture folder: $BASE_DIR"
echo "[collect] identity summary:"
sed 's/^/[collect]   /' "$BASE_DIR/identity/summary.txt" || true
if [ -z "$first_descriptor" ]; then
  echo "[collect] WARNING: no matching report_descriptor.bin captured for mode=$MODE"
fi
if [ "$MATCH_FOUND" -ne 1 ]; then
  echo "[collect] ERROR: no matching 054c:09cc device was detected for mode=$MODE"
  echo "[collect] The capture folder was still written for diagnosis: $BASE_DIR"
  exit 1
fi
