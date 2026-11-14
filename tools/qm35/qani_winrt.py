"""Windows WinRT Nordic UART peripheral. No fabricated NI configuration."""
import asyncio
import sys
from uuid import UUID

from qani_ble_bridge import Handshake, ProtocolError

SERVICE = UUID("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
RX = UUID("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
TX = UUID("6e400003-b5a3-f393-e0a9-e50e24dcca9e")


class WindowsNusPeripheral:
    def __init__(self, backend, api=None):
        if api is None:
            try:
                import winrt.windows.devices.bluetooth.genericattributeprofile as api
            except ImportError as exc:
                raise RuntimeError("Windows WinRT GATT-provider bindings are required") from exc
        self.api = api
        self.backend = backend
        self.handshake = Handshake(backend)
        self.loop = asyncio.get_running_loop()
        self.lock = asyncio.Lock()
        self.tasks = set()
        self.provider = self.rx = self.tx = None
        self.tokens = []
        self.owner = None
        self.session_hook = None
        self.closed = False
        self.done = asyncio.Event()
        self.error = None

    @staticmethod
    def identity(session):
        return session.device_id.id

    def spawn(self, coroutine):
        task = self.loop.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    def fail(self, exc):
        self.error = exc
        print("BLE bridge error: " + str(exc), file=sys.stderr, flush=True)
        self.done.set()

    async def start(self):
        a = self.api
        result = await a.GattServiceProvider.create_async(SERVICE)
        if int(result.error) != 0 or result.service_provider is None:
            raise RuntimeError("Cannot create GATT provider: " + str(result.error))
        self.provider = result.service_provider
        for uuid, properties, name in (
                (RX, a.GattCharacteristicProperties.WRITE, "rx"),
                (TX, a.GattCharacteristicProperties.NOTIFY, "tx")):
            params = a.GattLocalCharacteristicParameters()
            params.characteristic_properties = properties
            params.write_protection_level = a.GattProtectionLevel.PLAIN
            params.read_protection_level = a.GattProtectionLevel.PLAIN
            result = await self.provider.service.create_characteristic_async(uuid, params)
            if int(result.error) != 0 or result.characteristic is None:
                raise RuntimeError("Cannot create " + name + ": " + str(result.error))
            setattr(self, name, result.characteristic)
        self.tokens.append((self.rx.remove_write_requested,
                            self.rx.add_write_requested(self.on_write)))
        self.tokens.append((self.tx.remove_subscribed_clients_changed,
                            self.tx.add_subscribed_clients_changed(self.on_subscriptions)))
        self.tokens.append((self.provider.remove_advertisement_status_changed,
                            self.provider.add_advertisement_status_changed(self.on_advertising)))
        params = a.GattServiceProviderAdvertisingParameters()
        params.is_connectable = True
        params.is_discoverable = True
        self.provider.start_advertising_with_parameters(params)
        print("NUS advertising requested; awaiting Windows status. Ctrl+C stops.", flush=True)

    def on_advertising(self, sender, args):
        if int(args.error) != 0:
            self.loop.call_soon_threadsafe(self.fail, RuntimeError("Advertising failed: " + str(args.error)))
        else:
            print("GATT advertising status: " + str(args.status), flush=True)

    def on_write(self, sender, args):
        # Deferral must be obtained synchronously before returning to WinRT.
        deferral = args.get_deferral()
        self.loop.call_soon_threadsafe(self.spawn, self.write(args, deferral))

    def on_subscriptions(self, sender, args):
        self.loop.call_soon_threadsafe(self.spawn, self.check_subscription())

    def client(self, identity):
        return next((c for c in self.tx.subscribed_clients
                     if self.identity(c.session) == identity), None)

    async def check_subscription(self):
        async with self.lock:
            if self.owner is not None and self.client(self.owner) is None:
                # End this process after losing owner: never reuse uncertain hardware state.
                await self.stop_backend()
                self.done.set()

    def on_session_status(self, sender, args):
        if args.status == self.api.GattSessionStatus.CLOSED:
            self.loop.call_soon_threadsafe(self.spawn, self.disconnected())

    async def disconnected(self):
        async with self.lock:
            await self.stop_backend()
            self.done.set()

    async def stop_backend(self):
        if self.handshake.state in ("configured", "running"):
            try:
                await self.handshake.receive(b"\x0c")
            except Exception as exc:
                self.fail(exc)

    async def write(self, args, deferral):
        request = None
        try:
            async with self.lock:
                request = await args.get_request_async()
                if request is None:
                    return
                if self.closed or self.done.is_set() or request.offset != 0:
                    raise ProtocolError("Closed session or unsupported offset")
                identity = self.identity(args.session)
                client = self.client(identity)
                if client is None:
                    raise ProtocolError("Subscribe to TX before initializing")
                if self.owner is not None and self.owner != identity:
                    raise ProtocolError("Another central owns this accessory session")
                message = bytes(request.value)
                if self.owner is None:
                    session = args.session
                    token = session.add_session_status_changed(self.on_session_status)
                    self.session_hook = (session, token)
                self.owner = identity
                reply = await self.handshake.receive(message)
                # Each QANI message is one notification. No invented fragmentation.
                client = self.client(identity)
                if client is None or len(reply) > client.max_notification_size:
                    raise ProtocolError("Reply exceeds negotiated notification size or client unsubscribed")
                from winrt.windows.storage.streams import DataWriter
                writer = DataWriter()
                writer.write_bytes(reply)
                result = await self.tx.notify_value_for_subscribed_client_async(writer.detach_buffer(), client)
                if result.status != self.api.GattCommunicationStatus.SUCCESS or result.bytes_sent != len(reply):
                    raise ProtocolError("Notification failed: " + str(result.status))
                request.respond()
        except Exception as exc:
            if request is not None:
                try:
                    request.respond_with_protocol_error(0x0E)  # ATT unlikely error
                except Exception:
                    pass
            print("Rejected BLE write: " + str(exc), file=sys.stderr, flush=True)
            if self.handshake.state != "idle":
                self.fail(exc)
        finally:
            deferral.complete()

    async def close(self):
        self.closed = True
        if self.provider:
            self.provider.stop_advertising()
        for remove, token in reversed(self.tokens):
            remove(token)
        self.tokens.clear()
        if self.session_hook:
            session, token = self.session_hook
            session.remove_session_status_changed(token)
            self.session_hook = None
        if self.tasks:
            await asyncio.gather(*list(self.tasks), return_exceptions=True)
        async with self.lock:
            await self.stop_backend()


async def advertise(backend):
    peripheral = WindowsNusPeripheral(backend)
    try:
        await peripheral.start()
        await peripheral.done.wait()
        if peripheral.error:
            raise peripheral.error
    finally:
        await peripheral.close()
