# ds4-bt-usb-probe

`ds4-bt-usb-probe` v0.7.0 is a truth-capture foundation for a Bluetooth DS4 / PS4-compatible controller compatibility investigation on Linux.

**v0.7 capture pass implemented; translator correction requires Sonny's truth archive.**

This is still a remote-test prototype. It does not claim Diablo IV compatibility, and it does not implement a final daemon/service, autostart, rumble, real touchpad forwarding, remapping, macros, profiles, Xbox/XInput, or permanent duplicate-input suppression.

## v0.7 Goal

The working real USB controller and the current Bluetooth-to-virtual translator must be compared from evidence, not guessed layouts. v0.7 records:

- real USB `0x01` / 64-byte input reports for controlled actions
- raw Bluetooth reports accepted by the bridge
- the exact virtual USB `0x01` / 64-byte reports successfully emitted through UHID
- paired Bluetooth/virtual timestamps and sequence numbers
- dominant byte values, byte variance, changed-byte sets, missing changes, unexpected changes, and value mismatches

The generated `truth/report_diff.md` and `truth/summary.json` do **not** auto-apply guessed mappings. Sonny's returned results archive is required before an honest truth-based translator correction can be made.

## Proton Identity Target

Friend-provided Proton logs show the working USB mode as:

```text
HID_ID=0003:0000054C:000009CC
HID_NAME=Sony Interactive Entertainment Wireless Controller
PRODUCT=54c/9cc/100
bus_type=1
USB-style input report 0x01
```

The rejected physical Bluetooth mode appears as `HID_ID=0005:0000054C:000009CC`, `bus_type=2`, with full `0x11` / 78-byte Bluetooth reports.

The v0.7 primary runtime remains `full-uhid-only`:

- UHID BUS_USB / `0x0003`
- VID/PID `054c:09cc`
- name `Sony Interactive Entertainment Wireless Controller`
- captured real USB descriptor, feature reports, version, and idle report when available
- translated basic controls through USB-style report `0x01`
- no uinput device in the default guided gameplay test

Manual uinput and identity-only modes remain available for diagnostics, but the guided flow no longer runs a mode ladder.

## Safe Translator Foundation

Until the truth archive is returned:

- the full captured real USB idle report is used as the 64-byte virtual output template
- only the currently known basic-control bytes are overlaid
- unconfirmed status, battery, gyro, and touchpad fields remain frozen to captured USB idle truth
- hard touchpad disable and inactive-contact encoding remain enabled
- keepalives resend the last successfully translated UHID report instead of snapping held controls toward neutral
- `translator_corrected_from_truth=no` remains explicit in status and results

## Recommended Guided Test

Download the latest green GitHub Actions artifact named `ds4-bt-usb-probe-linux-x86_64`, extract it directly on the Bazzite host, and run from a normal host terminal:

```bash
chmod +x scripts/*.sh
sudo ./scripts/guided_test.sh
```

Do not run the guided test or probe inside distrobox/toolbox. A container may have Cargo while lacking reliable access to the real host HID devices.

The one-command flow:

1. Captures USB identity, descriptor, feature reports, and idle template.
2. Guides 27 controlled real USB action captures. PS may be skipped.
3. Switches to Bluetooth and starts `full-uhid-only`.
4. Guides the same actions while recording paired raw BT and exact emitted virtual USB reports.
5. Generates `truth/report_diff.md` and `truth/summary.json`.
6. Temporarily ACL-isolates physical Bluetooth evdev/js nodes while preserving the active hidraw bridge reader.
7. Offers one optional active-hidraw isolation experiment with an immediate forwarding health check and restore on failure.
8. Runs the full-UHID Steam Controller Tester gate.
9. Proceeds to Diablo IV only if the Steam gate reports an identifiable virtual DS4, steady controls, clean touchpad, stable LED/battery behavior, and no duplicate input.
10. Restores ACLs and creates one archive on success, failure, or interruption.

The guided capture takes several minutes because each controlled action is recorded in both USB and Bluetooth modes. Follow each prompt and hold the requested action steadily until its four-second capture completes.

Send back:

```text
ds4-probe-results-<timestamp>.tar.gz
```

That archive is the required truth source for the next translator-correction pass.

## Recovery

If `/dev/uhid` is missing or inaccessible:

```bash
sudo modprobe uhid
sudo ./scripts/guided_test.sh
```

Emergency ACL restore:

```bash
sudo ./scripts/restore_device_permissions.sh
```

## Manual Diagnostics

Run the full-UHID bridge manually:

```bash
sudo ./scripts/run_probe.sh --uhid-only
```

Capture one real USB action:

```bash
sudo ./ds4-bt-usb-probe capture-input \
  --hidraw /dev/hidrawX \
  --action cross \
  --output captures/manual/truth/usb/cross \
  --duration-ms 4000 \
  --report-id 0x01 \
  --report-size 64
```

Generate a comparison:

```bash
sudo ./ds4-bt-usb-probe compare-truth --truth-root captures/manual/truth
```

The existing `--bridge`, `--uinput-only`, and identity-only options remain diagnostic paths only.

## Build And CI

Build on the Bazzite host:

```bash
./scripts/build_release.sh
```

GitHub Actions keeps these blocking gates:

```text
cargo fmt --all
cargo build --release
cargo test --all-targets
bash -n scripts/*.sh
artifact staging/upload
```

Clippy remains absent from the blocking artifact path for this temporary prototype.

## Decision Boundary

v0.7 is a capture and comparison pass. Diablo IV compatibility remains unconfirmed. The translator must not be described as truth-corrected until Sonny returns the generated archive and the mappings are updated from that evidence.
