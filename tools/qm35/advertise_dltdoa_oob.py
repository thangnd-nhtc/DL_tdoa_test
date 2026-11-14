"""Experimental Android-documented DL-TDoA BLE OOB advertisement.
Source: https://developer.android.com/develop/connectivity/ranging
Uses captured Qorvo initiator log values, NOT live hardware interrogation.
No claim of Apple discovery compatibility or implicit PHY/timing defaults.
"""
import argparse
import asyncio
import ast
import json
import re
from pathlib import Path


def build(log):
    text = log.read_text(encoding="utf-8")
    def array(name):
        match = re.search(r"\b" + name + r"\s*\([^\n]*?\):\s*(\[[^\n]+\])", text)
        if not match:
            raise ValueError(f"Missing {name}")
        return bytes(ast.literal_eval(match.group(1)))
    def integer(name):
        match = re.search(r"\b" + name + r"\s*\([^\n]*?\):\s*(0x[0-9a-fA-F]+)", text)
        if not match:
            raise ValueError(f"Missing {name}")
        return int(match.group(1), 16)
    sid = int(re.search(r"Initializing session (\d+)", text).group(1))
    mac, vendor, iv = array("DeviceMacAddress"), array("VendorId"), array("StaticStsIv")
    if (len(mac), len(vendor), len(iv)) != (2, 2, 6) or integer("StsConfig") != 0:
        raise ValueError("This documented example requires short MAC and static STS")
    if integer("DeviceRole") != 7:
        raise ValueError("Supply initiator dt-anchor log, not tag/responder")
    # Preserve the documented fragment/profile/config bytes exactly.
    # 0x5F 0x09 is from Google's example; do not reinterpret as generic TLV length.
    body = bytes.fromhex("f0 5f 09 02 00 06 02") + mac
    body += bytes.fromhex("27 02") + vendor + bytes.fromhex("28 06") + iv
    body += bytes.fromhex("9f 04") + sid.to_bytes(4, "little")
    service_data = bytes.fromhex("f3 ff") + body
    ad = bytes([len(service_data) + 1, 0x16]) + service_data
    settings = {"session_id": sid, "mac_bytes": mac.hex(" "), "vendor_bytes": vendor.hex(" "), "sts_iv": iv.hex(" ")}
    for name in ("ChannelNumber", "PreambleCodeIndex", "SfdId", "SlotDuration", "RangingDuration", "SlotsPerRr", "RframeConfig", "PsduDataRate", "PrfMode", "StsLength"):
        settings[name] = integer(name)
    return service_data, ad, settings


async def publish(data, seconds):
    from winrt.windows.devices.bluetooth.advertisement import BluetoothLEAdvertisementPublisher, BluetoothLEAdvertisementDataSection
    from winrt.windows.storage.streams import DataWriter
    writer = DataWriter()
    writer.write_bytes(data)
    section = BluetoothLEAdvertisementDataSection()
    section.data_type = 0x16
    section.data = writer.detach_buffer()
    publisher = BluetoothLEAdvertisementPublisher()
    publisher.advertisement.data_sections.append(section)
    def changed(sender, args):
        print(f"Publisher status={args.status}; error={args.error}", flush=True)
    token = publisher.add_status_changed(changed)
    try:
        publisher.start()
        await asyncio.sleep(seconds)
    finally:
        publisher.stop()
        publisher.remove_status_changed(token)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True, help="Captured initiator anchor configuration log")
    parser.add_argument("--advertise", action="store_true", help="Actually broadcast; default only prints bytes")
    parser.add_argument("--seconds", type=float, default=120)
    args = parser.parse_args()
    data, ad, settings = build(args.log)
    print(json.dumps(settings, indent=2))
    print("Expected AD structure:", ad.hex(" "))
    print("Service data excluding UUID:", data[2:].hex(" "))
    print("WARNING: minimal BLE example omits PHY/timing; verify receiver defaults and Apple compatibility.")
    print("Scanner: look for Service Data UUID 0000fff3-0000-1000-8000-00805f9b34fb and compare bytes above.")
    if args.advertise:
        asyncio.run(publish(data, args.seconds))


if __name__ == "__main__":
    main()
