import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from uci import App, Status
from run_fira_dt import audit_app_config
from sts_readback import verify
from advertise_dltdoa_oob import build


class StsAuditTests(unittest.TestCase):
    def audit(self, returned=None, status=Status.Ok):
        configs = [(App.VendorId, [7, 8]), (App.StaticStsIv, [1, 2, 3, 4, 5, 6])]
        client = Mock()
        client.session_get_app_config.return_value = (status, returned if returned is not None else [(k, 1, v) for k, v in configs])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "readback.json"
            try:
                report = audit_app_config(client, 42, 42, configs, path)
            except RuntimeError:
                import json
                report = json.loads(path.read_text())
            client.session_get_app_config.assert_called_once_with(42, [App.VendorId, App.StaticStsIv])
            return report

    def test_match(self):
        self.assertEqual(verify(self.audit())["VendorId"], bytes([7, 8]))

    def test_mismatch(self):
        with self.assertRaises(ValueError):
            verify(self.audit([(App.VendorId, 1, [8, 7]), (App.StaticStsIv, 1, [1, 2, 3, 4, 5, 6])]))

    def test_missing(self):
        with self.assertRaises(ValueError):
            verify(self.audit([]))

    def test_unsupported(self):
        report = self.audit(status=next(value for value in Status if value != Status.Ok))
        self.assertFalse(report["ok"])
        with self.assertRaises(ValueError):
            verify(report)

    def test_exception(self):
        report = self.audit()
        report["ok"] = False
        report["error"] = "unsupported GET"
        with self.assertRaises(ValueError):
            verify(report)

    def test_advertiser_consistency(self):
        arrays = {"DeviceMacAddress": [161, 0], "VendorId": [7, 8], "StaticStsIv": [1, 2, 3, 4, 5, 6]}
        text = "Initializing session 42...\n"
        text += "\n".join(f"{key} (0x00): {value}" for key, value in arrays.items())
        text += "\nDeviceRole (0x00): 0x07\nStsConfig (0x00): 0x00\n"
        for name in ("ChannelNumber", "PreambleCodeIndex", "SfdId", "SlotDuration", "RangingDuration", "SlotsPerRr", "RframeConfig", "PsduDataRate", "PrfMode", "StsLength"):
            text += f"{name} (0x00): 0x01\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "A.log"
            path.write_text(text)
            data, ad, settings = build(path)
        self.assertEqual(ad[2:], data)
        verify(self.audit(), data)
        corrupt = bytearray(data)
        corrupt[17] ^= 1
        with self.assertRaises(ValueError):
            verify(self.audit(), corrupt)


if __name__ == "__main__":
    unittest.main()
