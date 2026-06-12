# Release Package

## Preferred: GitHub Actions Artifact

Download the latest successful GitHub Actions artifact named:

```text
ds4-bt-usb-probe-linux-x86_64
```

Send the extracted `ds4-bt-usb-probe-linux-x86_64` folder to the remote tester. It contains:

- compiled `ds4-bt-usb-probe` binary
- `scripts/`
- `README.md`
- `RELEASE_PACKAGE.md`
- optional KDE launcher `Run DS4 Probe Test.desktop`

Extract it directly on the Bazzite host, not inside distrobox/toolbox. From a normal Bazzite host terminal, run:

```bash
chmod +x scripts/*.sh
sudo ./scripts/guided_test.sh
```

v0.7 uses `full-uhid-only` as the sole guided gameplay target. The guided script captures real USB, raw Bluetooth, and exact emitted virtual USB reports, then generates a comparison before the Steam/Diablo gate.

The preferred and required file to send back is:

```text
ds4-probe-results-<timestamp>.tar.gz
```

That archive contains `truth/report_diff.md`, `truth/summary.json`, the framed report captures, bridge status/logs, tester answers, and permission restore diagnostics.

**v0.7 capture pass implemented; translator correction requires Sonny's truth archive.**

Emergency ACL restore:

```bash
sudo ./scripts/restore_device_permissions.sh
```

## Fallback: Build From Source

If the Actions artifact is unavailable, send these source files:

- `Cargo.toml`
- `src/`
- `scripts/`
- `README.md`
- `RELEASE_PACKAGE.md`
- `Run DS4 Probe Test.desktop`
- `.github/workflows/ci.yml`
- `captures/.gitkeep`

Do not include `target/`, previous real captures unless intentionally sharing them, or unrelated local files.

Example source package:

```bash
tar --exclude='./target' --exclude='./.git' \
  -czf ds4-bt-usb-probe-source.tar.gz \
  Cargo.toml src scripts README.md RELEASE_PACKAGE.md "Run DS4 Probe Test.desktop" .github captures/.gitkeep
```

Build and run on the Bazzite host:

```bash
chmod +x scripts/*.sh
./scripts/build_release.sh
sudo ./scripts/guided_test.sh
```

Diablo IV compatibility remains unconfirmed.
