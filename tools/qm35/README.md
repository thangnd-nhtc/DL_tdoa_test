# QM35 host tools

These files are a snapshot of tools from the QM35 SDK's `Samples/Python/UWB-Qorvo-Tools/scripts/fira/run_fira_dt` directory. Copy them back to that directory in an installed SDK before use. The launcher depends on the SDK tree and its Python environment; it is not standalone in this repository.

The QANI bridge is a tested protocol/backend scaffold only: no BLE GATT publishing and no real QM35 Apple NI backend are included. See QANI_BRIDGE.md. The iOS accessory mode requires genuine compatible accessory firmware. This is accessory ranging, not a fix for DL-TDoA callback reception.

The iOS changes have not been built with Xcode on this Windows machine.

## Firmware GET / static STS audit

`launch_4_anchors.py --audit-readback` now requests `App.VendorId` (0x27) and
`App.StaticStsIv` (0x28) through the existing SDK `session_get_app_config` API,
before START, alongside the other audited fields. GET bytes must match SET
wire bytes for every kit and all four kits must share A's STS. Unsupported,
missing, malformed or mismatched GET evidence fails; there is no SET fallback.
The existing schema-version-1 per-kit JSON fields retain requested/returned
raw hex and differences. Treat these diagnostic files as sensitive.

The launcher checks the exact A FFF3 service data layout against GET STS bytes;
when `--ble-oob` is also enabled, the advertiser independently verifies the exact
bytes passed to its publisher using `--readback-json`. This is not on-air or
receiver verification, nor proof of Apple compatibility. No radio defaults change.

The included `run_fira_dt.py` is SDK-dependent: install/copy into the SDK script
directory with its `uci`, `uqt_utils`, drivers and Python environment. Snapshots
are not standalone. Hardware-free regression tests from the SDK root:

```powershell
Samples/Python/UWB-Qorvo-Tools/.venv/Scripts/python.exe -m unittest discover -s Samples/Python/UWB-Qorvo-Tools/scripts/fira/run_fira_dt -p test_sts_readback.py -v
```
