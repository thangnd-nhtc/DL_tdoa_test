#!/usr/bin/env python3
"""
Non-interactive 4-anchor DL-TDoA launcher for QM35 DK-05 kits.
- Identifies each kit by SoC ID before assigning MAC/role/coordinates.
- Launches anchors sequentially (waiting for 'Starting ranging...') to avoid FT4222 open races.
- Uses --session 42 by default to match DLTDOAReceiver (networkIdentifier = 42).
"""

import argparse
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

UQT_ROOT = Path(__file__).resolve().parents[3]
VENV_PYTHON = UQT_ROOT / ".venv" / "Scripts" / "python.exe"
GET_DEVICE_INFO = UQT_ROOT / "scripts" / "device" / "get_device_info" / "get_device_info.py"
RUN_FIRA_DT = Path(__file__).resolve().parent / "run_fira_dt.py"
LOG_DIR = UQT_ROOT / "anchor_test_logs"

# Known physical kits mapped by SoC ID
# Relative coordinates in --dl-tdoa-anchor-location=1,1,x,y,z are encoded by Qorvo UQT
# as 28-bit/24-bit signed integers in MILLIMETERS (mm).
# Measured via pairwise TWR on 2026-11-14 (all 4 kits at same height z=0):
#   d_AB=0.79m, d_AC=0.76m, d_AD=0.46m, d_BC=0.39m, d_BD=0.77m, d_CD=0.69m
KITS = {
    "A": {
        "soc_id": "ce7740285be6bfdd0073d80cb012a208",
        "mac": "00:a1",
        "role_per_round": "[(0,init)]",
        "dest_per_round": "[(0,[(0xa2,),(0xa3,),(0xa4,)])]",
        "is_time_ref": True,
        "location": "1,1,0,0,0",        # (0.000m, 0.000m, 0.000m) -> 0, 0, 0 mm
    },
    "B": {
        "soc_id": "3b9d9e377a67cc11e3853d079199e8fd",
        "mac": "00:a2",
        "role_per_round": "[(0,resp)]",
        "dest_per_round": None,
        "is_time_ref": False,
        "location": "1,1,790,0,0",      # (0.790m, 0.000m, 0.000m) -> 790, 0, 0 mm
    },
    "C": {
        "soc_id": "e44abf0e89e3ace5b7dc32f548d995c9",
        "mac": "00:a3",
        "role_per_round": "[(0,resp)]",
        "dest_per_round": None,
        "is_time_ref": False,
        "location": "1,1,664,369,0",    # (0.664m, 0.369m, 0.000m) -> 664, 369, 0 mm
    },
    "D": {
        "soc_id": "f94c7c6bf3269b7c7c5632d72389371",
        "mac": "00:a4",
        "role_per_round": "[(0,resp)]",
        "dest_per_round": None,
        "is_time_ref": False,
        "location": "1,1,154,434,0",    # (0.154m, 0.434m, 0.000m) -> 154, 434, 0 mm
    },
}

DEFAULT_TRANSPORTS = [
    "ftdi://FT4222/V262301094A",
    "ftdi://FT4222/V262301202A",
    "COM408",
    "COM409",
]


def discover_transports(python_exe: str, extra_ports: list[str]) -> dict[str, str]:
    """Probe candidate transports sequentially and map SoC ID -> transport."""
    candidates = list(dict.fromkeys(DEFAULT_TRANSPORTS + extra_ports))
    try:
        import serial.tools.list_ports

        for p in serial.tools.list_ports.comports():
            if p.vid == 0x2DE0 and p.pid == 0x1337 and p.device not in candidates:
                candidates.append(p.device)
    except Exception:
        pass

    soc_to_transport: dict[str, str] = {}
    for transport in candidates:
        print(f"Probing {transport}...", flush=True)
        try:
            res = subprocess.run(
                [python_exe, str(GET_DEVICE_INFO), "-p", transport],
                capture_output=True,
                text=True,
                timeout=15,
            )
            output = res.stdout + "\n" + res.stderr
            m = re.search(r"soc[\s_]+id\s*:\s*([0-9a-fA-F]+)", output, re.IGNORECASE)
            if m and res.returncode == 0:
                soc_id = m.group(1).lower()
                soc_to_transport[soc_id] = transport
                print(f"  -> Found SoC ID {soc_id} on {transport}", flush=True)
        except Exception as exc:
            print(f"  -> Probe failed on {transport}: {exc}", flush=True)
    return soc_to_transport


def main() -> int:
    parser = argparse.ArgumentParser(description="Launch 4 QM35 DK-05 DL-TDoA anchors sequentially.")
    parser.add_argument("-s", "--session", type=str, default="42", help="Session ID / Network ID (default: 42)")
    parser.add_argument("-t", "--time", type=int, default=-1, help="Duration in seconds, -1 for until Ctrl+C (default: -1)")
    parser.add_argument("--extra-ports", nargs="*", default=[], help="Additional COM/FTDI ports to probe")
    parser.add_argument('--ble-oob', action='store_true', help='Publish experimental FFF3 BLE OOB')
    parser.add_argument('--timing-profile', choices=['qm35', 'android-oob'], default='qm35',
                        help='qm35: 200ms/25 slots (unchanged); android-oob: experimental AOSP defaults 250ms/10 slots, NOT verified Apple defaults')
    for kit in KITS:
        parser.add_argument(f"--location-{kit.lower()}", help="Measured relative coordinates x,y,z in metres; enables location presence in UWB DTM")
    args = parser.parse_args()
    for kit, cfg in KITS.items():
        value = getattr(args, f"location_{kit.lower()}")
        if value is not None:
            import math
            try:
                coordinates = [float(v) for v in value.split(",")]
                if len(coordinates) != 3 or not all(math.isfinite(v) for v in coordinates):
                    raise ValueError()
            except ValueError:
                parser.error(f"--location-{kit.lower()} requires three finite numbers in metres: x,y,z")
            # Qorvo UQT encodes relative coordinates as integer millimetres
            cfg["location"] = "1,1," + ",".join(str(round(v * 1000.0)) for v in coordinates)
        elif args.ble_oob and cfg["location"].startswith("0,"):
            parser.error(f"--ble-oob requires --location-{kit.lower()} with measured coordinates; absent anchor locations were reported by nearbyd")

    # AOSP android17-release DlTdoaRangingParams.Builder defaults when OOB omits timing:
    # https://android.googlesource.com/platform/packages/modules/Uwb/+/refs/heads/android17-release/ranging/framework/java/android/ranging/uwb/DlTdoaRangingParams.java
    # This is a controlled interoperability experiment, not a claim about Apple defaults.
    interval_ms, slots = (250, 10) if args.timing_profile == "android-oob" else (200, 25)
    print(f"Timing profile={args.timing_profile}: interval={interval_ms} ms, slots/round={slots}, slot=2400 RSTU", flush=True)
    if args.timing_profile == "android-oob":
        print("EXPERIMENTAL: AOSP OOB defaults; Apple defaults remain unverified. BLE bytes unchanged.", flush=True)

    python_exe = str(VENV_PYTHON) if VENV_PYTHON.exists() else sys.executable
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    soc_map = discover_transports(python_exe, args.extra_ports)
    missing = [name for name, cfg in KITS.items() if cfg["soc_id"] not in soc_map]
    if missing:
        print(f"ERROR: Missing kits {missing}. Make sure Qorvo Explorer is closed and all 4 kits are connected.")
        return 1

    # Launch responders (D, B, C) first, then initiator/time-ref (A) last
    launch_order = ["D", "B", "C", "A"]
    procs: list[tuple[str, subprocess.Popen, object, object]] = []

    ble_proc = None

    def cleanup():
        if ble_proc is not None and ble_proc.poll() is None:
            ble_proc.terminate()
            ble_proc.wait(timeout=5)

        for name, proc, out_f, err_f in procs:
            if proc.poll() is None:
                print(f"Stopping Kit {name} (PID {proc.pid})...", flush=True)
                proc.terminate()
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
            out_f.close()
            err_f.close()

    def handle_sig(signum, frame):
        print("\nInterrupted, stopping all anchors...", flush=True)
        cleanup()
        sys.exit(0)

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    try:
        for name in launch_order:
            cfg = KITS[name]
            transport = soc_map[cfg["soc_id"]]
            stdout_path = LOG_DIR / f"{name}.stdout.log"
            stderr_path = LOG_DIR / f"{name}.stderr.log"

            cmd = [
                python_exe,
                "-u",
                str(RUN_FIRA_DT),
                "-p",
                transport,
                "-s",
                args.session,
                "-t",
                str(args.time),
                "--role=dt-anchor",
                f"--ranging-span={interval_ms}",
                f"--slots-per-rr={slots}",
                "--slot-span=2400",
                f"--mac={cfg['mac']}",
                f"--role-per-round={cfg['role_per_round']}",
                f"--dl-tdoa-anchor-location={cfg['location']}",
            ]
            if cfg["dest_per_round"]:
                cmd.append(f"--dest-per-round={cfg['dest_per_round']}")
            if cfg["is_time_ref"]:
                cmd.append("--is-time-ref")

            out_f = open(stdout_path, "w", encoding="utf-8", buffering=1)
            err_f = open(stderr_path, "w", encoding="utf-8", buffering=1)

            print(f"Launching Kit {name} on {transport} (mac={cfg['mac']}, session={args.session})...", flush=True)
            proc = subprocess.Popen(
                cmd,
                stdout=out_f,
                stderr=err_f,
                stdin=subprocess.PIPE,
                cwd=str(UQT_ROOT),
            )
            procs.append((name, proc, out_f, err_f))

            # Wait up to 15s for "Starting ranging..." so FT4222 / COM opens don't race
            deadline = time.time() + 15.0
            ready = False
            while time.time() < deadline:
                if proc.poll() is not None:
                    print(f"ERROR: Kit {name} exited early with code {proc.returncode}. Check {stderr_path}", flush=True)
                    cleanup()
                    return 1
                try:
                    content = stdout_path.read_text(encoding="utf-8", errors="ignore")
                    if "Starting ranging..." in content:
                        ready = True
                        break
                except Exception:
                    pass
                time.sleep(0.3)

            if ready:
                print(f"  -> Kit {name} is ranging!", flush=True)
            else:
                print(f"  -> Warning: Kit {name} did not log 'Starting ranging...' within 15s, continuing...", flush=True)

        if args.ble_oob:
            from advertise_dltdoa_oob import build
            _, _, settings = build(LOG_DIR / "A.stdout.log")
            if settings["session_id"] != int(args.session):
                raise ValueError("BLE and anchor session mismatch")
            ble_proc = subprocess.Popen([
                python_exe, "-u", str(Path(__file__).with_name("advertise_dltdoa_oob.py")),
                "--log", str(LOG_DIR / "A.stdout.log"), "--advertise",
                "--seconds", str(args.time if args.time > 0 else 31536000),
            ], cwd=str(UQT_ROOT))
        print("\nAll 4 anchors launched. Ctrl+C stops anchors and BLE.", flush=True)
        while any(p.poll() is None for _, p, _, _ in procs):
            time.sleep(1.0)
    finally:
        cleanup()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
