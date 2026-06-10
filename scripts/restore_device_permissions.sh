#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MANIFEST="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "[restore] ERROR: this script must be run with sudo/root." >&2
  echo "[restore] Try: sudo ./scripts/restore_device_permissions.sh" >&2
  exit 1
fi

if ! command -v getfacl >/dev/null 2>&1 || ! command -v setfacl >/dev/null 2>&1; then
  echo "[restore] ERROR: getfacl and setfacl are required to restore saved ACLs." >&2
  exit 1
fi

if [ -z "$MANIFEST" ]; then
  while IFS= read -r candidate; do
    entries="$(awk 'NR > 1 && NF { count++ } END { print count + 0 }' "$candidate" 2>/dev/null || echo 0)"
    if [ "$entries" -gt 0 ]; then
      MANIFEST="$candidate"
      break
    fi
  done < <(
    find "$ROOT_DIR/captures" -path '*/guided/device_permissions/manifest.tsv' -type f -printf '%T@ %p\n' 2>/dev/null |
      sort -nr |
      awk '{ sub(/^[^ ]+ /, ""); print }'
  )
fi

if [ -z "$MANIFEST" ] || [ ! -f "$MANIFEST" ]; then
  echo "[restore] ERROR: no saved device-permission manifest was found." >&2
  echo "[restore] Expected latest: captures/<timestamp>/guided/device_permissions/manifest.tsv" >&2
  exit 1
fi

LOG_DIR="$(dirname "$MANIFEST")"
LOG_FILE="$LOG_DIR/emergency-restore.log"
echo "[restore] manifest=$MANIFEST" | tee -a "$LOG_FILE"

failures=0
restored=0
entries="$(awk 'NR > 1 && NF { count++ } END { print count + 0 }' "$MANIFEST" 2>/dev/null || echo 0)"
if [ "$entries" -eq 0 ]; then
  echo "[restore] nothing to restore in manifest" | tee -a "$LOG_FILE"
  exit 0
fi
kind=""
node=""
syspath=""
acl_file=""
stat_file=""

while IFS=$'\t' read -r kind node syspath acl_file stat_file; do
  [ "$kind" != "kind" ] || continue
  [ -n "${acl_file:-}" ] || continue
  if [ ! -f "$acl_file" ]; then
    echo "[restore] missing ACL backup for $node: $acl_file" | tee -a "$LOG_FILE"
    failures=$((failures + 1))
    continue
  fi
  if setfacl --restore="$acl_file" >>"$LOG_FILE" 2>&1; then
    echo "[restore] restored $node" | tee -a "$LOG_FILE"
    restored=$((restored + 1))
  else
    echo "[restore] FAILED $node" | tee -a "$LOG_FILE"
    failures=$((failures + 1))
  fi
done <"$MANIFEST"

echo "[restore] restored=$restored failures=$failures" | tee -a "$LOG_FILE"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
