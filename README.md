# ds4-bt-usb-probe

`ds4-bt-usb-probe` is a Linux Rust prototype for one compatibility gate:

> Will Diablo IV / Proton recognize a UHID-created USB-style DS4 device as a PlayStation controller?

It does **not** implement the final daemon/service, Bluetooth report translation, remapping, macros, profiles, Xbox/XInput, duplicate suppression, or autostart.

Target test machine:

- Bazzite / Fedora Atomic
- KDE
- Nvidia-open drivers 595.x
- Steam
- Diablo IV as a Steam game
- GE-Proton latest, currently 10-34
- PS4-compatible controller VID/PID `054c:09cc`

## What The Probe Does

- Opens `/dev/uhid`.
- Creates a virtual HID device with:
  - bus `BUS_USB` / `0x0003`
  - vendor `0x054c`
  - product `0x09cc`
  - version/name from the captured USB device when available
  - the captured USB report descriptor when available
- Falls back to a clearly warned DS4-like USB descriptor if no captured descriptor exists.
- Sends neutral USB-style DS4 input reports repeatedly:
  - report id `0x01`
  - 64 bytes total
  - centered sticks
  - neutral triggers
  - no buttons pressed
- Runs until Ctrl+C.

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

Prefer the compiled GitHub Actions artifact. Extract it directly on the Bazzite host and run it from a normal host terminal.

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

The script creates:

```text
ds4-probe-results-<timestamp>.tar.gz
```

Send that archive back after the test.

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
sudo ./scripts/run_probe.sh
```

Then:

- Launch Steam.
- Make sure Steam Input is disabled for Diablo IV.
- Launch Diablo IV.
- Check whether PlayStation glyphs appear.
- Send back the full `captures/` folder and terminal output.

Keep `sudo ./scripts/run_probe.sh` running while testing Diablo IV. Press Ctrl+C after the test.

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
   sudo ./scripts/run_probe.sh
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

Keep `sudo ./scripts/run_probe.sh` running while testing Diablo IV. Press Ctrl+C after the test.

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

## Expected Probe Logs

The probe should print lines like:

```text
[probe] /dev/uhid opened
[probe] descriptor source: latest USB capture ...
[probe] virtual identity: bus=USB/0x0003 vid=0x054c pid=0x09cc ...
[probe] UHID_CREATE2 sent
[uhid] event UHID_START ...
[probe] sending neutral USB-style DS4 input reports ...
[probe] sent ... neutral reports
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

If Diablo IV shows PlayStation glyphs from the UHID virtual USB-style device:

- Continue later to Pass 2: Bluetooth hidraw reader plus Bluetooth report `0x11` / 78-byte to USB report `0x01` / 64-byte translator.
- Then add duplicate input suppression.
- Then add service/autostart.

If Diablo IV does not show PlayStation glyphs:

- Stop.
- Report that UHID USB identity alone is insufficient.
- Investigate whether Proton/SDL/Diablo is checking deeper sysfs USB topology, SDL mappings, hidraw path, Wine device exposure, or another layer.

Do not claim Diablo IV compatibility until the remote tester confirms the result on the actual target machine.
