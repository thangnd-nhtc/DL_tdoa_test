"""Protocol tests only: fake bytes are NOT Apple accessory configurations."""
import asyncio
import sys
import unittest
from qani_ble_bridge import Handshake, JsonLinesBackend, ProtocolError


class FakeBackend:
    def __init__(self):
        self.calls = []
        self.fail = False

    async def request(self, operation, payload):
        self.calls.append((operation, payload))
        if self.fail:
            raise ProtocolError("test hardware rejected operation")
        return b"TEST-ONLY" if operation == "initialize" else b""


class HandshakeTests(unittest.IsolatedAsyncioTestCase):
    async def test_full_flow(self):
        backend = FakeBackend()
        session = Handshake(backend)
        self.assertEqual(await session.receive(b"\x0a"), b"\x01TEST-ONLY")
        self.assertEqual(await session.receive(b"\x0b\x00\xff"), b"\x02")
        self.assertEqual(await session.receive(b"\x0c"), b"\x03")
        self.assertEqual(backend.calls, [("initialize", b""), ("apply", b"\x00\xff"), ("stop", b"")])
        self.assertEqual(session.state, "idle")

    async def test_bad_inputs_do_not_touch_backend(self):
        backend = FakeBackend()
        session = Handshake(backend)
        for data in (b"", b"\x0babc", b"\x0c", b"\x0aextra", b"\xff"):
            with self.assertRaises(ProtocolError):
                await session.receive(data)
        self.assertEqual(backend.calls, [])

    async def test_failed_apply_never_reports_started(self):
        backend = FakeBackend()
        session = Handshake(backend)
        await session.receive(b"\x0a")
        backend.fail = True
        with self.assertRaises(ProtocolError):
            await session.receive(b"\x0bconfig")
        self.assertEqual(session.state, "faulted")
        with self.assertRaises(ProtocolError):
            await session.receive(b"\x0a")

    async def test_empty_configuration_fails(self):
        class Empty(FakeBackend):
            async def request(self, *args):
                return b""
        with self.assertRaises(ProtocolError):
            await Handshake(Empty()).receive(b"\x0a")

    async def test_subprocess_contract(self):
        # Deliberately fake backend, exercising pipes without radio/hardware.
        code = 'import sys,json; r=json.loads(sys.stdin.readline()); print(json.dumps({"id":r["id"],"ok":True,"payload_hex":"54455354"}),flush=True); sys.stdin.read()'
        async with JsonLinesBackend([sys.executable, "-u", "-c", code]) as backend:
            self.assertEqual(await backend.request("initialize"), b"TEST")

    async def test_wrong_ack_faults_backend(self):
        code = 'import sys,json; sys.stdin.readline(); print(json.dumps({"id":999,"ok":True}),flush=True); sys.stdin.read()'
        async with JsonLinesBackend([sys.executable, "-u", "-c", code]) as backend:
            with self.assertRaises(ProtocolError):
                await backend.request("stop")
            self.assertTrue(backend.failed)




class WinrtTransportTests(unittest.IsolatedAsyncioTestCase):
    async def test_subscription_gate_and_deferral(self):
        from types import SimpleNamespace as NS
        from qani_winrt import WindowsNusPeripheral
        backend = FakeBackend()
        peripheral = WindowsNusPeripheral(backend, NS())
        peripheral.tx = NS(subscribed_clients=[])
        class Request:
            offset = 0
            value = b'\x0a'
            error = None
            def respond_with_protocol_error(self, error): self.error = error
        request = Request()
        class Args:
            session = NS(device_id=NS(id='central'), add_session_status_changed=lambda handler: 1, remove_session_status_changed=lambda token: None)
            async def get_request_async(self): return request
        class Deferral:
            completed = False
            def complete(self): self.completed = True
        deferral = Deferral()
        await peripheral.write(Args(), deferral)
        self.assertTrue(deferral.completed)
        self.assertEqual(request.error, 0x0E)
        self.assertEqual(backend.calls, [])

    async def test_oversize_is_not_fragmented_and_stops(self):
        from types import SimpleNamespace as NS
        from qani_winrt import WindowsNusPeripheral
        backend = FakeBackend()
        peripheral = WindowsNusPeripheral(backend, NS())
        session = NS(device_id=NS(id='central'), add_session_status_changed=lambda handler: 1, remove_session_status_changed=lambda token: None)
        peripheral.tx = NS(subscribed_clients=[NS(session=session, max_notification_size=2)])
        class Request:
            offset = 0
            value = b'\x0a'
            def respond_with_protocol_error(self, error): pass
        class Args:
            async def get_request_async(self): return Request()
        args = Args()
        args.session = session
        class Deferral:
            def complete(self): pass
        await peripheral.write(args, Deferral())
        self.assertTrue(peripheral.done.is_set())
        await peripheral.close()
        self.assertEqual(backend.calls[-1], ('stop', b''))

if __name__ == "__main__":
    unittest.main()
