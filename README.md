# ds4-bt-usb-probe

`ds4-bt-usb-probe` v0.6.0 is the final remote functional attempt for testing whether a Bluetooth DS4/PS4-compatible controller can be presented to Steam/Proton/Diablo IV as a usable PlayStation controller.

This is still a prototype test artifact. It does **not** implement the final daemon/service, autostart, rumble, real touchpad forwarding, remapping, macros, profiles, Xbox/XInput, or permanent duplicate-input suppression. Do not claim Diablo IV compatibility until the remote tester confirms it.

Target test machine:

- Bazzite / Fedora Atomic
- KDE
- Nvidia-open drivers 595.x
- Steam
- Diablo IV as a Steam game
- GE-Proton latest, currently 10-34
- PS4-compatible controller VID/PID `054c:09cc`

## Proton Identity Target

Friend-provided Proton logs show the working USB mode as:

```text
HID_ID=0003:0000054C:000009CC
HID_NAME=Sony Interactive Entertainment Wireless Controller
PRODUCT=54c/9cc/100
bus_type=1
USB-style input report 0x01
```

The rejected Bluetooth mode appears as `HID_ID=0005:0000054C:000009CC`, `bus_type=2`, with full `0x11` / 78-byte Bluetooth reports. UHID cannot create a real physical USB parent, so v0.6 tests multiple visible-controller strategies and records which one, if any, Steam Tester and Diablo IV accept.

## What v0.6 Does

- Captures the real USB identity, descriptor, feature reports, and idle input template when available.
- Opens the physical Bluetooth DS4 hidraw for reading and translates basic controls from Bluetooth `0x11` / 78-byte or minimal `0x01` reports.
- Preserves the Sony DS4 UHID identity in UHID modes:
  - BUS_USB / `0x0003`
  - VID `0x054c`
  - PID `0x09cc`
  - name `Sony Interactive Entertainment Wireless Controller`
  - captured USB descriptor when available
- Answers known DS4 feature reports `0x02`, `0x12`, `0x81`, and `0xa3`, with safe descriptor-declared fallbacks.
- Keeps the v0.5 hard touchpad disable: no real touchpad forwarding, frozen touchpad block from captured USB idle template when available, otherwise a conservative no-touch block.
- Temporarily isolates physical Bluetooth evdev/js nodes with ACLs during mode tests while leaving the active Bluetooth hidraw reader untouched in default `stable-default` mode.
- Restores ACLs on normal completion, failure, or Ctrl+C, and includes an emergency restore script.

## Recommended Guided Test

Download the latest green GitHub Actions artifact, extract it on the Bazzite host, not distrobox/toolbox, then run:

```bash
chmod +x scripts/*.sh
sudo ./scripts/guided_test.sh
```

The script asks when to connect USB, switch to Bluetooth, open Steam Controller Tester, and launch Diablo IV. It creates one archive:

```text
ds4-probe-results-<timestamp>.tar.gz
```

Send that archive back after the test.

**Do not run the guided test or UHID probe from distrobox/toolbox.** A container may have Cargo available while still being unable to access the real host devices.

If `/dev/uhid` is missing or inaccessible, the script tries `modprobe uhid`. You can also run:

```bash
sudo modprobe uhid
sudo ./scripts/guided_test.sh
```

The script attempts `modprobe uinput` automatically for modes that need uinput. It requires `getfacl`, `setfacl`, and `sudo` for temporary ACL isolation.

Emergency permission restore:

```bash
sudo ./scripts/restore_device_permissions.sh
```

## v0.6 Mode Ladder

The guided test tries modes in this order:

1. `full-uhid-only`
   - Primary/default target.
   - UHID Sony DS4 identity plus full translated input reports.
   - No uinput device is created.
   - Goal: Steam and Diablo see one usable Sony DS4 controller.

2. `full-uhid-plus-uinput-hidden`
   - Experimental fallback only if Mode A fails Steam Tester buttons/sticks.
   - UHID full DS4 plus uinput gameplay fallback.
   - Physical Bluetooth evdev/js nodes are isolated; the active Bluetooth hidraw reader is not restricted.
   - If duplicate entries appear, the script records them instead of hiding the tested uinput path.

3. `uinput-only`
   - Diagnostic input-only mode.
   - No UHID DS4 identity.
   - Expected to provide input at best, not PlayStation glyphs.

4. `identity-only-uhid-plus-uinput`
   - Last-resort diagnostic comparison for the v0.5.2 behavior.
   - Known to be duplicate-prone and not the default final behavior.

For each mode, the script asks:

- How many controllers Steam shows: `0`, `1`, `2+`, or `unsure`
- Which controller entry was tested: `first`, `second`, `only`, or `unsure`
- Whether Steam Controller Tester shows a permanent touchpad contact
- Whether buttons/sticks work
- Whether there is duplicate controller confusion

Only a mode with no permanent touchpad contact and working buttons/sticks proceeds to Diablo IV questions.

## Success Criteria

A mode counts as functional success only if:

- Steam Tester buttons/sticks work.
- Steam Tester does not show a permanent touchpad contact.
- Diablo IV detects a controller.
- Diablo IV input works.

PlayStation glyph success additionally requires Diablo IV to show PlayStation glyphs.

`result_summary.txt` records:

- `modes_attempted`
- `selected_final_mode`
- per-mode UHID/uinput/isolation flags
- per-mode Steam Tester answers
- per-mode Diablo answers
- `final_conclusion`

Possible final conclusions:

- `success`
- `input_only_success_no_glyphs`
- `Steam Tester failed`
- `Diablo/Proton refused clean controller`
- `inconclusive`

## Capture Output

The archive contains:

- `usb/` and `bluetooth/` identity captures
- `guided/proton_visibility_notes.txt`
- `guided/result_summary.txt`
- `guided/modes/<mode>/probe.log`
- `guided/modes/<mode>/bridge_status.txt`
- `guided/modes/<mode>/steam_*.txt`
- `guided/modes/<mode>/diablo_*.txt`
- `guided/device_permissions/manifest.tsv`
- `guided/device_permissions/isolation.log`
- `guided/device_permissions/restore.log`

If `report_descriptor.bin` exists under the USB capture, `run_probe.sh` uses it automatically. If not, the probe prints a warning and uses the built-in fallback descriptor.

## Manual Probe Options

Build from source on the Linux host if the Actions artifact is unavailable:

```bash
chmod +x scripts/*.sh
./scripts/build_release.sh
```

Manual troubleshooting modes:

```bash
sudo ./scripts/run_probe.sh --uhid-only
sudo ./scripts/run_probe.sh --bridge
sudo ./scripts/run_probe.sh --uinput-only
sudo ./scripts/run_probe.sh --probe-only
```

Direct binary options:

```text
bridge --output-mode <both|uhid|uinput> --status-file <path>
capture-features --hidraw <path> --output-dir <path>
capture-idle-input --hidraw <path> --output-dir <path>
monitor-touchpad-events --event <path> --output-dir <path>
monitor-input-events --event <path> --output-dir <path>
```

## Decision Rule

If `full-uhid-only` succeeds fully, it is the preferred final approach for any later daemon/service work.

If `full-uhid-only` has clean Steam Tester input but Diablo IV fails, report that the bridge path is clean and the remaining problem is likely Diablo/Proton device selection.

If only `uinput-only` works, the project can provide input but the PlayStation glyph goal is not solved.

If all modes fail, stop remote functional build attempts and document the current limitations.
