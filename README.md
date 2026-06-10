# ds4-bt-usb-probe

`ds4-bt-usb-probe` v0.3 is an unconfirmed functional Linux attempt to make a Bluetooth DS4-compatible controller usable by Diablo IV as a USB-style PlayStation controller.

> Will Diablo IV / Proton accept the preserved UHID Sony identity plus a USB-identified uinput gamepad path?

It preserves the Sony-identifying UHID path used by Steam and adds a required uinput evdev gamepad fallback for Diablo IV. It does **not** implement the final daemon/service, rumble, gyro/touchpad forwarding, remapping, macros, profiles, Xbox/XInput, duplicate suppression, or autostart.

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

The rejected Bluetooth mode appears as `HID_ID=0005:0000054C:000009CC`, `bus_type=2`, with full `0x11` / 78-byte Bluetooth reports. v0.3 keeps the working USB-visible UHID identity and adds a BUS_USB uinput event device because Proton previously marked the UHID hidraw path as `input=-1` / `is_gamepad=0`.

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
- Runs until Ctrl+C.
- Answers known DS4 feature reports `0x02`, `0x12`, `0x81`, and `0xa3`, plus safe descriptor-declared feature fallbacks.
- Rewrites the virtual pairing MAC in bridge mode to avoid duplicating the physical controller identity.
- In guided bridge mode, forwards basic controls from full `0x11` / 78-byte and minimal `0x01` / 10-byte Bluetooth reports.
- Emits the same basic controls to a uinput evdev gamepad with normal axes, hats, buttons, and `EV_SYN`.
- Uses captured USB and input-event versions when available; otherwise UHID falls back to `0x0100` and uinput to `0x8111`.

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

This is the easiest path for a remote tester. The script asks when to plug in USB, when to switch to Bluetooth, when to test Diablo IV, and then creates one results archive to send back.

Download the latest green Actions artifact, extract it on the Bazzite host, not distrobox/toolbox, then run `sudo ./scripts/guided_test.sh`.

**Do not run the guided test or UHID probe from distrobox/toolbox.** A container may have Cargo available while still being unable to access the real host `/dev/uhid`.

From the extracted artifact folder on the Bazzite host:

```bash
chmod +x scripts/*.sh
sudo ./scripts/guided_test.sh
```

If the script reports that `/dev/uhid` is missing or inaccessible, try:

```bash
sudo modprobe uhid
sudo ./scripts/guided_test.sh
```

The guided script attempts `modprobe uinput` automatically when the required uinput node is absent.

The script creates:

```text
ds4-probe-results-<timestamp>.tar.gz
```

Send that archive back after the test.

The guided test will stop and create a diagnostic archive instead of asking for a Diablo IV test unless UHID initializes, a uinput event node is created, and Bluetooth reports are read and forwarded to both outputs.

If uinput fails, the script prints:

```text
uinput fallback failed, so this v0.3 Diablo test is not valid yet. Send back the archive.
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
sudo ./scripts/collect_ds4_identity.sh usb
sudo ./scripts/collect_ds4_identity.sh bluetooth
sudo ./scripts/run_probe.sh --bridge
```

Then:

- Launch Steam.
- Make sure Steam Input is disabled for Diablo IV.
- Launch Diablo IV.
- Check whether PlayStation glyphs appear.
- Send back the full `captures/` folder and terminal output.

Keep `sudo ./scripts/run_probe.sh --bridge` running while testing Diablo IV. Press Ctrl+C after the test.

## Remote Tester Instructions

1. Connect the controller by USB.

2. Run:

   ```bash
   sudo ./scripts/collect_ds4_identity.sh usb
   ```

3. Disconnect USB.

4. Connect the controller by Bluetooth.

5. Run:

   ```bash
   sudo ./scripts/collect_ds4_identity.sh bluetooth
   ```

6. Run:

   ```bash
   sudo ./scripts/run_probe.sh --bridge
   ```

7. Launch Steam.

8. Make sure Steam Input is disabled for Diablo IV.

9. Launch Diablo IV.

10. Check whether PlayStation glyphs appear.

11. Send back:

   - the full `captures/` folder
   - the terminal output from all commands
   - whether Diablo IV showed PlayStation glyphs
   - whether duplicate inputs happened
   - whether the real Bluetooth controller was also seen by the game

Keep `sudo ./scripts/run_probe.sh --bridge` running while testing Diablo IV. Press Ctrl+C after the test.

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
```

It will also print matching `/dev/hidraw*` and `/dev/input/event*` devices when they are discoverable through sysfs.

## Verification Checklist

During the Diablo IV test, record:

- Did Diablo IV recognize a controller with Steam Input disabled?
- Did Diablo IV show PlayStation glyphs?
- Did duplicate inputs happen?
- Was the real Bluetooth controller also seen by the game?
- Did the probe log UHID errors, GET_REPORT/SET_REPORT requests, or output reports?

## Decision Rule

If Diablo IV detects the v0.3 bridge and shows PlayStation glyphs:

- Treat the v0.3 UHID + uinput functional attempt as a successful gate result.
- Then add duplicate input suppression.
- Then add service/autostart.

If Diablo IV does not show PlayStation glyphs:

- Stop.
- Report that the v0.3 UHID + uinput attempt was insufficient.
- Investigate whether Proton/SDL/Diablo is checking deeper sysfs USB topology, SDL mappings, hidraw path, Wine device exposure, or another layer.

Do not claim Diablo IV compatibility until the remote tester confirms the result on the actual target machine.
