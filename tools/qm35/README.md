# QM35 host tools

These files are a snapshot of tools from the QM35 SDK's `Samples/Python/UWB-Qorvo-Tools/scripts/fira/run_fira_dt` directory. Copy them back to that directory in an installed SDK before use. The launcher depends on the SDK tree and its Python environment; it is not standalone in this repository.

The QANI bridge is a tested protocol/backend scaffold only: no BLE GATT publishing and no real QM35 Apple NI backend are included. See QANI_BRIDGE.md. The iOS accessory mode requires genuine compatible accessory firmware. This is accessory ranging, not a fix for DL-TDoA callback reception.

The iOS changes have not been built with Xcode on this Windows machine.
