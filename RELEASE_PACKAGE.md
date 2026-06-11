# Release Package

## Path A: GitHub Actions Artifact Preferred

Download the latest green GitHub Actions artifact named:

```text
ds4-bt-usb-probe-linux-x86_64
```

Send that extracted folder to the remote tester. It contains:

- compiled `ds4-bt-usb-probe` binary
- `scripts/`, including `scripts/restore_device_permissions.sh`
- `README.md`
- `RELEASE_PACKAGE.md`
- optional KDE launcher `Run DS4 Probe Test.desktop`

Extract the artifact directly on the Bazzite host. Run the test from a normal Bazzite host terminal.

**Do not run this from distrobox/toolbox.** Cargo inside distrobox may build the project, but the UHID probe needs the real host `/dev/uhid`.

From inside the extracted artifact folder:

```bash
chmod +x scripts/*.sh
sudo ./scripts/guided_test.sh
```

If `/dev/uhid` is missing or inaccessible:

```bash
sudo modprobe uhid
sudo ./scripts/guided_test.sh
```

The guided script also attempts `modprobe uinput` when the required uinput fallback node is absent. v0.5.2 requires `getfacl` and `setfacl` for ACL-only physical Bluetooth evdev/js isolation; it does not use chmod fallback and does not restrict the active Bluetooth hidraw reader in the default mode. It validates uinput button/stick events before Steam Tester/Diablo and packages failures for diagnosis.

Emergency permission restore:

```bash
sudo ./scripts/restore_device_permissions.sh
```

The preferred file to send back is:

```text
ds4-probe-results-<timestamp>.tar.gz
```

Version 0.5.2 preserves the UHID Sony identity and required uinput evdev fallback, keeps the active Bluetooth hidraw reader stable, and validates the selected input path before Diablo. Identity-only mode permits a missing UHID input event node but requires a passing uinput button/stick event monitor. It is not confirmed compatible with Diablo IV until the remote tester reports the result.

The tester may also try the optional KDE/Bazzite desktop launcher:

```text
Run DS4 Probe Test.desktop
```

If the desktop launcher does not work, run `sudo ./scripts/guided_test.sh` from a terminal.

## Path B: Build From Source Fallback

If the GitHub Actions artifact is not available, send this project folder to the remote tester with these files included. Build and run it on the Bazzite host, not inside distrobox/toolbox:

- `Cargo.toml`
- `src/`
- `scripts/`
- `README.md`
- `RELEASE_PACKAGE.md`
- `Run DS4 Probe Test.desktop`
- `.github/workflows/ci.yml`
- `captures/.gitkeep`

Do not include:

- `target/`
- old real capture folders unless you intentionally want to share them
- unrelated local files

Example package command from the project root:

```bash
tar --exclude='./target' --exclude='./.git' \
  -czf ds4-bt-usb-probe.tar.gz \
  Cargo.toml src scripts README.md RELEASE_PACKAGE.md "Run DS4 Probe Test.desktop" .github captures/.gitkeep
```

The remote tester should unpack the source package on the Linux target machine, run `chmod +x scripts/*.sh`, build with `./scripts/build_release.sh`, then run `sudo ./scripts/guided_test.sh`.
