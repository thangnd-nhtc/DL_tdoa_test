#!/usr/bin/env python3

# SPDX-FileCopyrightText: Copyright (c) 2024 Qorvo US, Inc.
# SPDX-License-Identifier: LicenseRef-QORVO-2

import argparse
import json
import tempfile
from pathlib import Path
from uci.core import tvs_to_bytes
import logging
import os
import sys
import time

from uci import (
    App,
    Client,
    Gid,
    NotImplementedData,
    OidQorvo,
    OidRanging,
    RangingData,
    RangingDiagData,
    RangingPSDUSReport,
    SessionType,
    Status,
    UciComError,
)
from uqt_utils.utils import compute_dl_tdoa_anchor_location_value, str2bytes, uqt_errno

# Below hack sometimes required when operating on windows git-bash/msys2
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")

epilog = """
Example of use:
    - Minimum use-case: forever ranging between 1 initiator anchor,
        1 receiver anchor, and 1 tag on the same round (0):
        - sh1: run_fira_dt -t -1 --role=dt-anchor --mac="00:a1" --role-per-round='[(0, init)]'\
            --dest-per-round='[ (0, [(0xa2,)]) ]' --is-time-ref
        - sh2: run_fira_dt -t -1 --role dt-anchor --mac="00:a2" --role-per-round '[(0,resp)]
        - sh3: run_fira_dt -t -1 --role dt-tag    --mac="00:b1" --activity='[0]'

    - 4 DUT use-case: forever ranging between 1 initiator anchor,
        2 receiver anchor, and 1 tag on 2 different rounds:
        - sh1: run_fira_dt -t -1 --role=dt-anchor --mac="00:a1" --role-per-round='[(0, init), (1, init)]' \
            --dest-per-round='[ (0, [(0xa2,)]), (1, [(0xa3,)]) ]' --is-time-ref
        - sh2: run_fira_dt -t -1 --role dt-anchor --mac="00:a2" --role-per-round '[(0,resp)]
        - sh3: run_fira_dt -t -1 --role dt-anchor --mac="00:a3" --role-per-round '[(0,resp)]
        - sh4: run_fira_dt -t -1 --role dt-tag    --mac="00:b1" --activity='[0, 1]'
"""


# Only audit relevant App IDs already SET here; never guess vendor IDs.
READBACK_NAMES = frozenset("""DeviceRole MultiNodeMode RangingRoundUsage DeviceMacAddress
ChannelNumber ScheduleMode StsConfig VendorId StaticStsIv RframeConfig PreambleCodeIndex SfdId
SlotDuration RangingDuration SlotsPerRr DlTdoaRangingMethod DlTdoaTxTimestampConf
DlTdoaTxActiveRangingRounds PsduDataRate PrfMode StsLength PreambleDuration
NumberOfStsSegments DlTdoaAnchorLocation DlTdoaAnchorLocationV2
DlTdoaTimeReferenceAnchor""".split())


def audit_app_config(client, session_id, session_handle, app_configs, output):
    """GET returns (Status, [(App ID, element length, integer/list)]).

    Compare SET wire bytes with GET bytes, independently of async stdout.
    This is a configuration diagnostic, not proof of radio interoperability.
    """
    requested = [(k, v) for k, v in app_configs if k.name in READBACK_NAMES]
    report = {"schema_version": 1, "session_id": session_id,
              "session_handle": session_handle, "fields": [], "ok": False}
    error = None
    try:
        status, returned = client.session_get_app_config(session_handle, [k for k, _ in requested])
        report["status"] = {"name": status.name, "value": int(status)}
        values = {}
        for key, length, value in returned:
            if int(key) in values:
                raise ValueError(f"Duplicate returned App ID {int(key)}")
            items = value if isinstance(value, list) else [value]
            values[int(key)] = b"".join(item.to_bytes(length, "little") for item in items)
        for key, value in requested:
            expected = tvs_to_bytes(App.defs, [(key, value)])[3:]
            actual = values.get(int(key))
            report["fields"].append({"id": int(key), "name": key.name,
                "requested_raw_hex": expected.hex(),
                "returned_raw_hex": actual.hex() if actual is not None else None,
                "difference": "missing" if actual is None else ("mismatch" if expected != actual else None)})
        if status != Status.Ok:
            raise ValueError(f"GET_APP_CONFIG rejected/unsupported: {status.name}")
        differences = [f["name"] + ":" + f["difference"] for f in report["fields"] if f["difference"]]
        if differences:
            raise ValueError("GET_APP_CONFIG differences: " + ", ".join(differences))
        report["ok"] = True
    except Exception as exc:
        error = exc
        report["error"] = str(exc)
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=destination.parent,
                prefix=destination.name + ".", delete=False) as stream:
            temporary = stream.name
            stream.write(json.dumps(report, separators=(",", ":")) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    if error is not None:
        raise RuntimeError(f"App-config audit failed; see {destination}: {error}") from error
    return report


def verify_dl_tdoa_anchor_location_params(location, mode_v2_enabled):
    length = len(location)
    type = int(location[1])
    if mode_v2_enabled:
        if type not in (0, 1, 2, 3, 4, 5):
            raise ValueError("Location supported types (v2): 0,1,2,3,4,5")
    else:
        if type not in (0, 1):
            raise ValueError("Location supported types (v1): 0 or 1")
    if type in (0, 1, 4) and length != 5:
        raise ValueError(
            f"For type {type} please write 5 fields separated by a comma for dl_tdoa_anchor_location_params value"
        )
    if type in (2, 3, 5) and length != 9:
        raise ValueError(
            f"For type {type} please write 9 fields separated by a comma for dl_tdoa_anchor_location_params with Z-element value"
        )


def main():
    default_port = os.getenv("UQT_PORT", "/dev/ttyUSB0")
    parser = argparse.ArgumentParser(
        description="Fira One Way Ranging for DL TDoA measurements.",
        formatter_class=argparse.RawTextHelpFormatter,
        epilog=epilog,
    )
    parser.add_argument("--readback-json", help="Audit GET_APP_CONFIG after SET, before START; atomic JSON output path")
    parser.add_argument(
        "--description",
        action="store_true",
        help="show short description of the script",
        default=False,
    )
    parser.add_argument(
        "-p",
        "--port",
        type=str,
        default=default_port,
        help="communication port to use. (default: %(default)s)",
    )
    parser.add_argument(
        "-t",
        "--time",
        type=int,
        default=10,
        help="duration of the ranging session. -1: forever. (default: %(default)s)",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        default=False,
        help="use logging.DEBUG level. (default: %(default)s)",
    )
    parser.add_argument(
        "-s",
        "--session",
        type=str,
        default="42",
        help="set the session id to use. (default: %(default)s)",
    )
    parser.add_argument(
        "-c",
        "--channel",
        type=int,
        default=9,
        help="set the CHANNEL_NUMBER value. (default: %(default)s)",
    )
    parser.add_argument(
        "--preamble-idx",
        type=int,
        default=10,
        help="preamble value. (default: %(default)s)",
    )
    parser.add_argument(
        "--preamble-duration",
        type=int,
        choices=[0, 1],
        default=1,
        help="Preamble duration. 0 = 32 symbols; 1 = 64 symbols. (default: %(default)s)",
    )
    parser.add_argument(
        "--nb-sts-segments",
        type=int,
        choices=[1, 2, 3, 4],
        default=1,
        help="Number of STS segments in the frame. (default: %(default)s)",
    )
    parser.add_argument(
        "--sfd", type=int, default=2, help="sfd value. (default: %(default)s)"
    )
    parser.add_argument(
        "--sts-length",
        type=int,
        choices=[0, 1, 2],
        default=1,
        help="Number of symbols in a STS segment. 0 = 32 symbols; 1 = 64 symbols; 2 = 128 symbols. (default: %(default)s)",
    )
    parser.add_argument(
        "--role",
        choices=["dt-anchor", "dt-tag"],
        default="dt_anchor",
        help="set the DEVICE_ROLE value. (default: %(default)s)",
    )
    parser.add_argument(
        "--en-dt-hop-count", action="store_true", help="set DL_TDOA_HOP_COUNT to 1.)"
    )
    parser.add_argument(
        "--en-dt-tof",
        action="store_true",
        help="set DL_TDOA_RESPONDER_TOF to 1. (default: %(default)s)",
    )
    parser.add_argument(
        "--is-time-ref",
        action="store_true",
        help="set DL_TDOA_TIME_REFERENCE_ANCHOR to 1. (default: %(default)s)\n"
        "(Warning: this setting is applicable ONLY for dt_anchor \n"
        "playing as initiator on any round of the block)",
    )
    parser.add_argument(
        "--slot-span",
        type=int,
        default=2400,
        help="set the SLOT_DURATION value. (default: %(default)s)",
    )
    parser.add_argument(
        "--ranging-span",
        type=int,
        default=200,
        help="set the RANGING_DURATION param. (default: %(default)s)\n"
        "(previously RANGING_INTERVAL)",
    )
    parser.add_argument(
        "--slots-per-rr",
        type=int,
        default=25,
        help="Number of slots in a ranging round. (default: %(default)s)",
    )
    parser.add_argument(
        "--en-diag",
        action="store_true",
        default=False,
        help="set the Qorvo ENABLE_DIAGNOSTIC parameter to 1.",
    )
    parser.add_argument(
        "--diag-fields",
        type=str,
        default="metrics|aoa|cfo",
        help="set the Qorvo DIAGNOSTIC_FRAME_REPORTS_FIELD value.\n"
        "OR flags: metrics, aoa, cir, cfo. (default: %(default)s)",
    )
    parser.add_argument(
        "--meas-max",
        type=int,
        default=0,
        help="set the MAX_NUMBER_OF_MEASUREMENTS value.\n" "(default: %(default)s)",
    )
    parser.add_argument(
        "--en-psdu-dump",
        action="store_true",
        default=False,
        help="set the Qorvo PSDU_DUMP value to 1. (default: %(default)s)",
    )
    parser.add_argument(
        "--mac",
        type=str,
        help="set the DEVICE_MAC_ADDRESS value.\n"
        'default: "00:a1" if dt-anchor else "00:b1".',
    )
    parser.add_argument(
        "--en-rssi",
        action="store_true",
        default=False,
        help="set the RSSI_REPORTING value to 1. (default: %(default)s)",
    )
    parser.add_argument(
        "--dis-encryption",
        action="store_true",
        help="set MAC_PAYLOAD_ENCRYPTION to 0. (default: %(default)s) \n"
        "(Warning: supported only on specific firmware.)",
    )
    parser.add_argument(
        "--role-per-round",
        type=str,
        help="As an anchor, sets the role per round using below format:\n"
        "    [(<round_idx_1>,<role_1>), ..,(<round_idx_1>,<role_1>)]\n"
        "    with <role_i> == init or resp. (default: %(default)s)\n"
        "This is a spec for the SESSION_UPDATE_ACTIVE_ROUNDS_ANCHOR cmd.\n"
        "Example: --role-per-round='[(0, init), (1, init), (2, resp)]'",
    )
    parser.add_argument(
        "--dest-per-round",
        type=str,
        help="As an initiator anchor, sets the destination MAC add list\n"
        "for each round using below format:\n"
        "    [ ( round_idx_1, [(mac_1_1, slots_1_1), ... (mac_1_n, slots_1_n)] ),\n"
        "    ...\n"
        "    ( round_idx_m, [(mac_m_1, slots_m_1), ... (mac_m_n, slots_m_n)] ) ]\n"
        "    For a given i, slots_i_j may be all empty.\n"
        "This is a spec for the SESSION_SET_INITIATOR_DT_ANCHOR_RR_RDM_LIST cmd.\n"
        "Example: --dest-per-round='[ (0, [(0x0a,), (0x0b,)]), (1, [(0x0a,2), (0x0a,3)]) ]'",
    )
    parser.add_argument(
        "--activity",
        type=str,
        help="As a tag, defines the list of round index when the tag are required\n"
        "to listen to anchor. Format: [round_idx1, round_idx2, ...]\n"
        "This is a spec for the SESSION_UPDATE_ACTIVE_ROUNDS_DT_TAG cmd.\n"
        "Example: --activity=[0, 1, 2]",
    )
    parser.add_argument(
        "--dl_tdoa_tx_timestamp_conf",
        type=lambda x: int(x, 0),
        default=0b00000011,
        help="DlTdoaTxTimestampConf value. Default: 0b00000011\n"
        "b0: TX timestamp type\n"
        "  0: Local time base\n"
        "  1: Common time base of init DT anchor\n"
        "b1: TX timestamp length for DTM msg\n"
        "  0: 40-bit TX timestamp\n"
        "  1: 64-bit TX timestamp\n",
    )
    parser.add_argument(
        "--dl-tdoa-anchor-location",
        type=str,
        default="0,0,0,0,0",
        help="DlTdoaAnchorLocation value. Default: 0,0,0,0,0. \n"
        "The option has two flavors, depending on whether --mode-v2 is enabled or disabled:\n"
        "  --mode-v2 is disabled (v1):\n"
        "    Format - 5 fields separated by comma: <presence>,<type>,<x>,<y>,<z>.\n"
        "      presence: Presence of DT-Anchor location\n"
        "        0: DT-Anchor location not present\n"
        "        1: DT-Anchor location present\n"
        "      type: Type of coordinates system\n"
        "        0: WGS-84 coordinates system\n"
        "        1: Relative coordinates system\n"
        "      x,y,z: coordinates\n"
        "    Examples: 0,0,0,0,0 or 1,0,2,3,4 or 1,1,5,6,7\n"
        "  --mode-v2 is enabled (v2):\n"
        "    Format\n"
        "    - types 0, 1, 4 - 5 fields separated by comma: <presence>,<type>,<x>,<y>,<z>\n"
        "    - types 2, 3, 5 - 9 fields separated by comma: <presence>,<type>,<x>,<y>,<z>,\n"
        "    <floor>,<moved>,<height>,<uncertainty>.\n"
        "      presence: Presence of DT-Anchor location\n"
        "        0: DT-Anchor location not present\n"
        "        1: DT-Anchor location present\n"
        "      type: Type of coordinates system\n"
        "        0: WGS-84 coordinates system\n"
        "        1: Relative coordinates system\n"
        "        2: WSG-84 coordinates system with Z-element\n"
        "        3: Relative coordinates system with Z-element\n"
        "        4: Relative Gravity Aligned coordinates system\n"
        "        5: Relative Gravity Aligned coordinates system with Z-element\n"
        "      x,y,z: coordinates\n"
        "      floor: floor number (Z-element)\n"
        "      moved: planned to be moved (Z-element)\n"
        "      height: height above floor [m] (Z-element)\n"
        "      uncertainty: height above floor uncertainty (Z-element)\n"
        "    Examples: 1,1,5,6,7 or 1,5,7,8,9,10,1,12,13",
    )
    parser.add_argument(
        "--mode-v2",
        action="store_true",
        default=False,
        help="Enable location v2 mode.\n"
        "When enabled and role is dt-anchor, the script will set DL_TDOA_ANCHOR_LOCATION_V2 parameter.\n"
        "When enabled and role is dt-tag, the script will set DL_TDOA_MEASUREMENT_NTF_V2 to 1.",
    )
    parser.add_argument(
        "--dl-tdoa-tx-active-ranging-rounds",
        action="store_true",
        default=False,
        help="set the DL_TDOA_TX_ACTIVE_RANGING_ROUNDS value to 1. (default: %(default)s)",
    )
    parser.add_argument(
        "--psdu-data-rate",
        type=int,
        choices=[0, 1, 2, 3, 4],
        default=0,
        help="This value configures the data rate for PHY service Data Unit (PSDU):"
        " 0 6.81Mbps / 1 7.80Mbps / 2 27.2Mbps / 3 31.2Mbps / 4 850Kbps, (default: %(default)s)",
    )
    parser.add_argument(
        "--prf-mode",
        type=int,
        choices=[0, 1, 2],
        default=0,
        help="This parameter is used to configure the mean Pulse Repetition Frequency (PRF):"
        " 0 BPRF / 1 HPRF / 2 HPRF High Rate, (default: %(default)s)",
    )
    parser.add_argument(
        "--qtraces-logfile",
        type=str,
        metavar="LOG_PATH",
        help="Specifies a directory or file to save raw, undecoded Qtraces, applicable only in ft4222 mode."
        "If a directory is provided, logs will be saved in it with a timestamped filename"
        "If a full file path is provided, the file will be overwritten."
        "If no '.bin' extension is present, it will be automatically appended.",
    )

    opts = parser.parse_args()

    if opts.description:
        print(parser.description)
        sys.exit(0)

    if opts.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    log = logging.getLogger()

    default_config = dict(
        # Fira Mandatory:
        round="dt",  # RANGING_ROUND_USAGE
        mac=("00:a1" if opts.role == "dt-anchor" else "00:b1"),  # DEVICE_MAC_ADDRESS
        node="onetomany",  # MULTI_NODE_MODE
        # Other:
        report="tof|azimuth|elevation|fom",  # RESULT_REPORT_CONFIG
        vendor=[0x07, 0x08],  # VENDOR_ID
        sts="static",  # STS_CONFIG
        static_sts=[0x01, 0x02, 0x03, 0x04, 0x05, 0x06],  # STATIC_STS_IV
        aoa_report=1,  # AOA_RESULT_REQ
        init_time=0,  # UWB_INITIATION_TIME
        preamble_idx=10,  # PREAMBLE_CODE_INDEX
        sfd=2,  # SFD_ID
        slots_per_rr=25,  # SLOTS_PER_RR
        dt_mode="ds-twr",  # DL_TDOA_RANGING_ METHOD
    )

    args = type("args", (), {})()
    args.__dict__.update(default_config)
    args.__dict__.update({k: v for k, v in vars(opts).items() if v is not None})

    dl_tdoa_anchor_location_params = args.dl_tdoa_anchor_location.split(",")
    verify_dl_tdoa_anchor_location_params(dl_tdoa_anchor_location_params, args.mode_v2)
    dl_tdoa_anchor_location = compute_dl_tdoa_anchor_location_value(
        presence=int(dl_tdoa_anchor_location_params[0]),
        coord_type=int(dl_tdoa_anchor_location_params[1]),
        coord_x=float(dl_tdoa_anchor_location_params[2]),
        coord_y=float(dl_tdoa_anchor_location_params[3]),
        coord_z=float(dl_tdoa_anchor_location_params[4]),
        z_element_f=(
            int(dl_tdoa_anchor_location_params[5])
            if len(dl_tdoa_anchor_location_params) > 5
            else 0
        ),
        z_element_m=(
            int(dl_tdoa_anchor_location_params[6])
            if len(dl_tdoa_anchor_location_params) > 5
            else 0
        ),
        z_element_h=(
            int(dl_tdoa_anchor_location_params[7])
            if len(dl_tdoa_anchor_location_params) > 5
            else 0
        ),
        z_element_u=(
            int(dl_tdoa_anchor_location_params[8])
            if len(dl_tdoa_anchor_location_params) > 5
            else 0
        ),
    )

    # Handle user inputs & conversions
    try:
        user_mapping = dict(
            onetomany=1,
            dt_anchor=7,
            dt_tag=8,  # role
            resp=0,
            init=1,  # role-per-round
            aoa=0x2,
            cfo=0x8,
            metrics=0x20,
            cir=0x40,  # diag_fields
            dt=5,
            rrrm=1,
            cm=2,
            rcp=4,
            mrp=64,
            mrm=128,  # round_ctrl
            tof=1,
            azimuth=2,
            elevation=4,
            fom=8,  # report
            static=0,
            ss_twr=0,
            ds_twr=1,  # dt_mode
        )

        args.mac = list(str2bytes(args.mac, "little"))
        for p in (
            "session",
            "cap_range",
            "diag_fields",
            "round",
            "report",
            "sts",
            "role",
            "node",
            "round_ctrl",
            "dt_mode",
            "role_per_round",
            "dest_per_round",
            "activity",
        ):
            if hasattr(args, p):
                setattr(args, p, eval(getattr(args, p).replace("-", "_"), user_mapping))
    except Exception as e:
        print(f'Error while handling user input "{p}":\n{e}')
        sys.exit(uqt_errno(2))

    notif_handlers = {
        (Gid.Ranging, OidRanging.Start): lambda x: print(RangingData(x)),
        (Gid.Qorvo, OidQorvo.TestDiag): lambda x: print(RangingDiagData(x)),
        (Gid.Qorvo, OidQorvo.PSDUSReport): lambda x: print(RangingPSDUSReport(x)),
        ("default", "default"): lambda gid, oid, x: print(
            NotImplementedData(gid, oid, x)
        ),
    }

    while True:
        try:

            client = None
            client = Client(
                port=args.port,
                notif_handlers=notif_handlers,
                qtraces_logfile=opts.qtraces_logfile,
            )
            print(f"Initializing session {args.session}...")
            rts, session_handle = client.session_init(args.session, SessionType.Ranging)
            if rts != Status.Ok:
                print(f"session_init failed: {rts.name} ({rts})")
                break

            if session_handle is None:
                print(
                    f"Using Fira 1.3 (session handle == session ID) is : {args.session}"
                )
                session_handle = args.session
            else:
                print(f"Using Fira 2.0 session handle is : {session_handle}")

            print(f"Setting session {session_handle} config ...")

            # Fira Mandatory/minimal session config:
            # From Fira std p54 Table 23: Mandatory APP configurations for UWB Session
            # & From Fira std p49 Table 22: Relevant APP configuration parameters per session modes
            app_configs = [
                (App.DeviceRole, args.role),
                # No App.DeviceType
                (App.MultiNodeMode, args.node),
                (App.RangingRoundUsage, args.round),
                (App.DeviceMacAddress, args.mac),
                # Additional config:
                (App.ChannelNumber, args.channel),
                (App.ScheduleMode, 0x01),
                (App.StsConfig, args.sts),
                (App.RframeConfig, 0x01),
                (App.ResultReportConfig, args.report),
                (App.VendorId, args.vendor),
                (App.StaticStsIv, args.static_sts),
                (App.AoaResultReq, args.aoa_report),
                (App.UwbInitiationTime, args.init_time),
                (App.PreambleCodeIndex, args.preamble_idx),
                (App.SfdId, args.sfd),
                (App.SlotDuration, args.slot_span),
                (App.RangingDuration, args.ranging_span),
                (App.SlotsPerRr, args.slots_per_rr),
                (App.MaxNumberOfMeasurements, args.meas_max),
                (App.DlTdoaRangingMethod, args.dt_mode),
                (App.DlTdoaTxTimestampConf, args.dl_tdoa_tx_timestamp_conf),
                (
                    App.DlTdoaTxActiveRangingRounds,
                    1 if args.dl_tdoa_tx_active_ranging_rounds else 0,
                ),
                (App.RssiReporting, 1 if args.en_rssi else 0),
                (App.PsduDataRate, args.psdu_data_rate),
                (App.PrfMode, args.prf_mode),
                (App.StsLength, args.sts_length),
                (App.PreambleDuration, args.preamble_duration),
                (App.NumberOfStsSegments, args.nb_sts_segments),
                # Possibly Other:
                # ~ (App.MacFcsType, 0),
                # ~ (App.SessionPriority, 50),
                # ~ (App.MacAddressMode, 0),
            ]
            if args.role == user_mapping["dt_anchor"]:
                if args.mode_v2:
                    app_configs.append(
                        (App.DlTdoaAnchorLocationV2, dl_tdoa_anchor_location)
                    )
                else:
                    app_configs.append(
                        (App.DlTdoaAnchorLocation, dl_tdoa_anchor_location)
                    )
            elif args.role == user_mapping["dt_tag"]:
                if args.mode_v2:
                    app_configs.append((App.DlTdoaMeasurementNtfV2, 1))
            if args.en_dt_hop_count:
                app_configs.append((App.DlTdoaHopCount, 1))
            if args.en_dt_tof:
                app_configs.append((App.DlTdoaResponderTof, 1))
            if args.is_time_ref:
                # Check that the device doesn't play as responder ONLY
                if "role_per_round" in vars(args):
                    roles = (role for _, role in args.role_per_round)
                    if not any(role == 1 for role in roles):
                        client.session_deinit(session_handle)
                        raise AssertionError(
                            "Device is asked to play as responder only, you can't set it as DL_TDOA_TIME_REFERENCE_ANCHOR"
                        )
                    app_configs.append((App.DlTdoaTimeReferenceAnchor, 1))
                else:
                    client.session_deinit(session_handle)
                    raise AssertionError(
                        "DL_TDOA_TIME_REFERENCE_ANCHOR setting is only applicable for Anchor, not for Tag"
                    )
            if args.en_diag:
                app_configs.extend(
                    [
                        (App.EnableDiagnostics, 1),
                        (App.DiagsFrameReportsFields, args.diag_fields),
                    ]
                )
            if args.en_psdu_dump:
                app_configs.append((App.EnablePSDUDump, 1))
            if args.dis_encryption:
                app_configs.append((App.MacPayloadEncryption, 0))

            for i in app_configs:
                p = f"{i[0].name} ({hex(i[0])}):"

                try:
                    v = hex(i[1])
                except Exception:
                    try:
                        v = i[1].hex(".")
                    except Exception:
                        v = repr(i[1])
                print(f"    {p:<35} {v}")

            rts, rtv = client.session_set_app_config(session_handle, app_configs)
            if rts != Status.Ok:
                print(f"session_set_app_config failed: {rts.name} ({rts}).")
                print(f"{rtv}")
                client.session_deinit(session_handle)
                break

            if args.readback_json:
                try:
                    audit_app_config(client, args.session, session_handle, app_configs, args.readback_json)
                except Exception:
                    client.session_deinit(session_handle)
                    raise

            if "role_per_round" in vars(args):
                print("Setting dt anchor role per rounds...")
                for item in args.role_per_round:
                    round_idx, role = item
                    print(
                        f'    round {round_idx:<2}: {"initiator" if role == 1 else "responder"}'
                    )
                round_list = []
                for i, role in args.role_per_round:
                    dest_per_round = []
                    if "dest_per_round" in vars(args):
                        print("Setting dt anchor receiver mac per slot...")
                        for round_idx, slot_spec in args.dest_per_round:
                            if round_idx == i:
                                for mac_slot in slot_spec:
                                    mac, *slot = mac_slot
                                    slot = "NA" if slot == [] else slot[0]
                                    print(
                                        f"    round={round_idx:<2}, slot={slot:<3} : {hex(mac)}"
                                    )
                                dest_per_round = slot_spec
                                break
                        round_list.append((i, role, dest_per_round))
                    else:
                        round_list.append((i, role))

                rts, rtv = client.session_update_dt_anchor_ranging_rounds(
                    session_handle, round_list
                )
                if rts != Status.Ok:
                    print(
                        f"session_update_dt_anchor_ranging_rounds failed: {rts.name} ({rts}). message: {rtv}"
                    )
                    if rts != Status.ErrorRoundIndexNotActivated:
                        client.session_deinit(session_handle)
                        break

            if "activity" in vars(args):
                print("Setting dt tag activity...")
                print(f"    tag listening rounds: {args.activity}")
                rts, rtv = client.session_set_dt_tag_activity(
                    session_handle, args.activity
                )
                if rts != Status.Ok:
                    print(
                        f"session_set_dt_tag_activity failed: {rts.name} ({rts}). message: {rtv}"
                    )
                    if rts != Status.ErrorRoundIndexNotActivated:
                        client.session_deinit(session_handle)
                        break

            print("Starting ranging...")
            rts = client.ranging_start(session_handle)
            if rts != Status.Ok:
                print(f"ranging_start failed: {rts.name} ({rts})")
                client.session_deinit(session_handle)
                break

            if args.time == -1:
                input("Press <RETURN> to stop\n")
            else:
                time.sleep(args.time)

            print("Stopping ranging...")
            rts = client.ranging_stop(session_handle)
            if rts != Status.Ok:
                print(f"ranging_stop failed: {rts.name} ({rts})")
                client.session_deinit(session_handle)
                break

            print("Deinitializing session...")
            rts = client.session_deinit(session_handle)
            if rts != Status.Ok:
                print(f"session_deinit failed: {rts.name} ({rts})")
                break

            break

        except UciComError as e:
            rts = e.n
            log.critical(f"{e}")
            break

    if client:
        client.close()
    if rts == Status.Ok:
        print("Ok")
    sys.exit(uqt_errno(rts))


if __name__ == "__main__":
    main()
