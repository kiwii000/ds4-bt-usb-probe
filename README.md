# ds4-bt-usb-probe

`ds4-bt-usb-probe` v0.5.1 is an unconfirmed functional Linux attempt to make a Bluetooth DS4-compatible controller usable by Diablo IV as a USB-style PlayStation controller.

> Will Diablo IV / Proton select the preserved virtual USB-style DS4/uinput outputs if the active Bluetooth hidraw reader is kept stable and the virtual UHID DS4 event node is externally verified clean for touchpad idle events?

It preserves the Sony-identifying UHID path, keeps the required uinput evdev gamepad fallback, keeps ACL-only evdev/js isolation for the physical Bluetooth controller during the guided test, neutralizes UHID DS4 touch contacts at idle, and validates the UHID event node externally before Diablo. It does **not** implement the final daemon/service, rumble, real touchpad forwarding, remapping, macros, profiles, Xbox/XInput, duplicate suppression, or autostart.

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

The rejected Bluetooth mode appears as `HID_ID=0005:0000054C:000009CC`, `bus_type=2`, with full `0x11` / 78-byte Bluetooth reports. v0.5.1 keeps the working USB-visible UHID identity, keeps the BUS_USB uinput event device, avoids restricting the active Bluetooth hidraw reader by default, can restrict physical evdev/js nodes, and externally monitors the UHID virtual event node for touchpad events before Diablo.

UHID cannot create a real physical USB topology. This test still determines whether its USB bus identity and HID behavior are sufficient for Proton/Diablo IV.

## What The Probe Does

- Opens `/dev/uhid`.
- Creates a virtual HID device with:
  - bus `BUS_USB` / `0x0003`
  - vendor `0x054c`
  - product `0x09cc`
  - captured USB version when available
  - name `Sony Interactive Entertainment Wireless Controller`
  - the captured USB report descriptor when available
- Falls back to a clearly warned DS4-like USB descriptor if no captured descriptor exists.
- Falls back to name `Sony Interactive Entertainment Wireless Controller` and version `0x0100` when captured USB identity values are unavailable.
- Sends neutral USB-style DS4 input reports repeatedly:
  - report id `0x01`
  - 64 bytes total
  - centered sticks
  - neutral triggers
  - no buttons pressed
  - no active touchpad contacts
- Runs until Ctrl+C.
- Answers known DS4 feature reports `0x02`, `0x12`, `0x81`, and `0xa3`, plus safe descriptor-declared feature fallbacks.
- Rewrites the virtual pairing MAC in bridge mode to avoid duplicating the physical controller identity.
- In guided bridge mode, forwards basic controls from full `0x11` / 78-byte and minimal `0x01` / 10-byte Bluetooth reports.
- Emits the same basic controls to a uinput evdev gamepad with normal axes, hats, buttons, and `EV_SYN`.
- Uses captured USB and input-event versions when available; otherwise UHID falls back to `0x0100` and uinput to `0x8111`.
- In the default guided test, keeps the active physical Bluetooth hidraw node untouched, and may use ACL-only isolation for physical evdev/js nodes while leaving virtual UHID/uinput nodes alone.
- In v0.5.1, does not forward real touchpad data. It intentionally freezes the DS4 touchpad block from a captured USB idle report when available, otherwise from a conservative no-touch fallback.
- Treats the UHID virtual DS4 event node as the source of truth for the touchpad idle gate; the internal byte decoder is diagnostic only.

The fallback descriptor is only a backup. Because the controller may be PS4-compatible rather than original Sony, the USB descriptor captured from the real working USB mode is the preferred test input.

## Build

On the Linux test machine:

```bash
chmod +x scripts/*.sh
./scripts/build_release.sh
```

The release binary will be:

```text
target/release/ds4-bt-usb-probe
```

## Recommended guided test

This is the easiest path for a remote tester. The script asks when to plug in USB, when to switch to Bluetooth, when to launch Steam/Diablo IV, and then creates one results archive to send back.

Download the latest green Actions artifact, extract it on the Bazzite host, not distrobox/toolbox, then run `sudo ./scripts/guided_test.sh`.

**Do not run the guided test or UHID probe from distrobox/toolbox.** A container may have Cargo available while still being unable to access the real host `/dev/uhid`.

From the extracted artifact folder on the Bazzite host:

```bash
chmod +x scripts/*.sh
sudo ./scripts/guided_test.sh
```

Close Steam before starting. The guided script will tell the tester when to launch Steam again after the bridge and physical Bluetooth isolation are confirmed.

If the script reports that `/dev/uhid` is missing or inaccessible, try:

```bash
sudo modprobe uhid
sudo ./scripts/guided_test.sh
```

The guided script attempts `modprobe uinput` automatically when the required uinput node is absent. It also requires `getfacl` and `setfacl`; v0.5.1 does not use a chmod fallback for physical-device isolation.

The script creates:

```text
ds4-probe-results-<timestamp>.tar.gz
```

Send that archive back after the test.

The guided test will stop and create a diagnostic archive instead of asking for a Diablo IV test unless UHID initializes, a uinput event node is created, Bluetooth reports are read and forwarded, the bridge is stable, the active physical Bluetooth hidraw is not restricted, and the UHID virtual event node has no touchpad events during the idle monitor.

If the external UHID event touchpad idle check fails, v0.5.1 tries identity-only UHID plus uinput input. If that is still dirty, it stops before Diablo IV and records `valid_diablo_test=no` in the archive.

Emergency permission restore:

```bash
sudo ./scripts/restore_device_permissions.sh
```

Optional KDE/Bazzite desktop launcher:

```text
Run DS4 Probe Test.desktop
```

If the desktop launcher does not open correctly, use the terminal commands above.

## Friend test instructions

This probe is implemented for remote testing only. It does not prove Diablo IV compatibility until the tester runs it on the target machine and reports the result.

Run these commands from a normal Bazzite host terminal, not distrobox/toolbox:

```bash
chmod +x scripts/*.sh
sudo ./scripts/guided_test.sh
```

The guided script handles USB capture, Bluetooth capture, bridge startup, ACL isolation, Diablo prompts, permission restore, and archive creation.

## Remote Tester Instructions

Use the recommended guided test above. The script will prompt for USB connection, Bluetooth connection, Steam launch, Diablo IV testing, and result answers. Send back the generated archive:

```text
ds4-probe-results-<timestamp>.tar.gz
```

## Capture Output

Each collection run writes:

```text
captures/<timestamp>/<mode>/
```

where `<mode>` is `usb` or `bluetooth`.

Important files include:

- `collect.log`
- `identity/summary.txt`
- `identity/name.txt`
- `identity/version.txt`
- `report_descriptor.bin`
- `report_descriptor.hex`
- `hidraw/report_descriptor.bin`
- `hidraw/report-descriptors/*`
- `input/proc-bus-input-devices.txt`
- `input/event-udev/*`
- `input/event-sysfs/*`
- `hidraw/hidraw-udev/*`
- `logs/dmesg-matches.txt`
- `logs/journal-matches.txt`
- `evtest/*`
- `usb/feature_reports/0x02.bin`
- `usb/feature_reports/0x12.bin`
- `usb/feature_reports/0xa3.bin`
- `usb/feature_reports/0x81.bin`
- `guided/raw_bluetooth_reports/*`
- `guided/expected_virtual_identity.txt`
- `guided/bridge_status.txt`
- `guided/result_summary.txt`
- `guided/proton_visibility_notes.txt`
- `guided/device_permissions/manifest.tsv`
- `guided/device_permissions/discovered_physical_bt_nodes.tsv`
- `guided/device_permissions/restricted_nodes.tsv`
- `guided/device_permissions/isolation.log`
- `guided/device_permissions/restore.log`

If `report_descriptor.bin` exists under the USB capture, `run_probe.sh` will use it automatically. If not, the probe will print a warning and use the built-in fallback descriptor.

## Manual Probe Options

```bash
sudo target/release/ds4-bt-usb-probe \
  --descriptor captures/<timestamp>/usb/report_descriptor.bin \
  --capture-root captures
```

Useful options:

```text
--descriptor <path>     HID report descriptor binary to use
--name <string>         Virtual HID device name
--version <hex|dec>     Virtual HID version
--vid <hex|dec>         Vendor ID, default 0x054c
--pid <hex|dec>         Product ID, default 0x09cc
--interval-ms <n>       Neutral input report interval, default 8
--capture-root <path>   Capture root, default captures
```

Functional and capture subcommands:

```text
bridge --feature-root <path> --raw-capture-dir <path>
capture-features --hidraw <path> --output-dir <path>
```

Advanced host-terminal troubleshooting modes:

```bash
sudo ./scripts/run_probe.sh --uhid-only
sudo ./scripts/run_probe.sh --probe-only
```

The default guided test never uses UHID-only mode.

## Expected Probe Logs

The probe should print lines like:

```text
[probe] /dev/uhid opened
[probe] descriptor source: latest USB capture ...
[probe] virtual identity: bus=USB/0x0003 vid=0x054c pid=0x09cc ...
[probe] UHID_CREATE2 sent
[uhid] event UHID_START ...
[uhid] GET_REPORT ... rnum=0x12 ... reply=success ...
[probe] READY: virtual DS4 initialized
[uinput] READY: fallback gamepad created ...
[bridge] READY: Bluetooth input stream opened
[bridge] forwarded ... Bluetooth input reports
[touchpad] sample=... active_contacts=0 ...
[event-monitor] uhid_event_touchpad_idle_clean=yes events=0
```

It will also print matching `/dev/hidraw*` and `/dev/input/event*` devices when they are discoverable through sysfs.

## Verification Checklist

During the Diablo IV test, record:

- Did Steam detect the controller?
- In Steam controller tester, is there still a permanent touchpad contact?
- Does the script say UHID event touchpad idle clean?
- Did Diablo IV detect a controller with Steam Input disabled?
- Did Diablo IV show PlayStation glyphs?
- Did input work?
- Did duplicate inputs happen?
- Did the probe log UHID errors, GET_REPORT/SET_REPORT requests, or output reports?

## Decision Rule

If Diablo IV detects the v0.5.1 bridge and shows PlayStation glyphs:

- Treat the v0.5.1 externally validated touchpad/stability attempt as a successful gate result.
- Then add duplicate input suppression.
- Then add service/autostart.

If Diablo IV does not show PlayStation glyphs:

- Stop.
- Report that the v0.5.1 externally validated UHID + uinput attempt was insufficient.
- Investigate whether Proton/SDL/Diablo is checking deeper sysfs USB topology, SDL mappings, hidraw path, Wine device exposure, or another layer.

Do not claim Diablo IV compatibility until the remote tester confirms the result on the actual target machine.
