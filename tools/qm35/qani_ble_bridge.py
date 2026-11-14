"""QANI handshake, Windows NUS BLE peripheral, and real-backend JSON-lines adapter.

Never synthesizes NI accessory configuration or maps NI data to FiRa parameters.
"""
import argparse
import asyncio
import json
import sys

MAX_MESSAGE = 65536


class ProtocolError(ValueError):
    pass


class JsonLinesBackend:
    """One subprocess, ordered request/response, stdout reserved for JSON."""
    def __init__(self, command, timeout=10):
        if not command:
            raise ValueError("A real backend command is required")
        self.command = command
        self.timeout = timeout
        self.process = None
        self.sequence = 0
        self.lock = asyncio.Lock()
        self.failed = False

    async def __aenter__(self):
        self.process = await asyncio.create_subprocess_exec(
            *self.command, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=None, limit=MAX_MESSAGE)
        return self

    async def __aexit__(self, *args):
        if self.process is not None:
            try:
                self.process.stdin.close()
                await asyncio.wait_for(self.process.stdin.wait_closed(), 2)
            except (BrokenPipeError, ConnectionResetError, asyncio.TimeoutError):
                pass
            if self.process.returncode is None:
                self.process.terminate()
            try:
                await asyncio.wait_for(self.process.wait(), 3)
            except asyncio.TimeoutError:
                self.process.kill()
                await self.process.wait()

    async def request(self, operation, payload=b""):
        async with self.lock:
            if self.failed or self.process is None or self.process.returncode is not None:
                raise ProtocolError("Backend unavailable; restart required")
            self.sequence += 1
            request = {"id": self.sequence, "operation": operation,
                       "payload_hex": payload.hex()}
            try:
                self.process.stdin.write((json.dumps(request) + "\n").encode())
                await asyncio.wait_for(self.process.stdin.drain(), self.timeout)
                line = await asyncio.wait_for(self.process.stdout.readline(), self.timeout)
                if not line or len(line) >= MAX_MESSAGE:
                    raise ProtocolError("Backend closed or oversized response")
                response = json.loads(line)
                if response.get("id") != self.sequence or response.get("ok") is not True:
                    raise ProtocolError("Backend did not acknowledge request")
                data = bytes.fromhex(response.get("payload_hex", ""))
                if len(data) > MAX_MESSAGE - 1:
                    raise ProtocolError("Backend payload too large")
                return data
            except Exception:
                # A timed-out request may still have changed hardware state. Never
                # consume a late response as acknowledgment of the next request.
                self.failed = True
                raise


class Handshake:
    """Per-connection state; notifications returned only after backend ack.

    Transport must serialize writes and deliver each returned message atomically.
    Any uncertain backend result faults this connection until backend restart.
    """
    def __init__(self, backend):
        self.backend = backend
        self.state = "idle"
        self.lock = asyncio.Lock()

    async def receive(self, message):
        async with self.lock:
            if not message or len(message) > MAX_MESSAGE:
                raise ProtocolError("Empty or oversized message")
            opcode, payload = message[0], message[1:]
            if self.state == "faulted":
                raise ProtocolError("Connection faulted; restart backend")
            if opcode == 0x0A and not payload and self.state == "idle":
                operation, next_state, reply = "initialize", "configured", b"\x01"
            elif opcode == 0x0B and payload and self.state == "configured":
                operation, next_state, reply = "apply", "running", b"\x02"
            elif opcode == 0x0C and not payload and self.state in ("configured", "running"):
                operation, next_state, reply = "stop", "idle", b"\x03"
            else:
                raise ProtocolError("Invalid opcode, payload, or handshake order")
            try:
                result = await self.backend.request(operation, payload)
                if operation == "initialize":
                    if not result or len(result) > MAX_MESSAGE - 1:
                        raise ProtocolError("Backend supplied no usable accessory configuration")
                    reply += result
                elif result:
                    raise ProtocolError("Unexpected backend acknowledgment payload")
            except BaseException:
                self.state = "faulted"
                raise
            self.state = next_state
            return reply


async def run_stdio(command, timeout):
    """Diagnostic harness only. Not a BLE peripheral or an NI backend."""
    async with JsonLinesBackend(command, timeout) as backend:
        handshake = Handshake(backend)
        while True:
            line = await asyncio.to_thread(sys.stdin.readline)
            if not line:
                break
            try:
                reply = await handshake.receive(bytes.fromhex(line.strip()))
                print(json.dumps({"notification_hex": reply.hex()}), flush=True)
            except Exception as exc:
                print(json.dumps({"error": str(exc)}), flush=True)
                if handshake.state == "faulted":
                    break
        # EOF/disconnection must stop real ranging, never silently abandon it.
        if handshake.state in ("configured", "running"):
            await handshake.receive(b"\x0c")


async def run_selected(args):
    if args.stdio:
        await run_stdio(args.backend_command, args.timeout)
    else:
        from qani_winrt import advertise
        async with JsonLinesBackend(args.backend_command, args.timeout) as backend:
            await advertise(backend)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--advertise", action="store_true", help="Windows WinRT NUS BLE peripheral")
    modes.add_argument("--stdio", action="store_true",
                        help="Diagnostic hex-line transport, NOT Bluetooth")
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--backend-command", nargs=argparse.REMAINDER, required=True,
                        help="Executable and arguments; must be last; no shell")
    args = parser.parse_args()
    if args.timeout <= 0 or not args.backend_command:
        parser.error("positive timeout and nonempty backend command required")
    try:
        asyncio.run(run_selected(args))
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        parser.exit(1, "Bridge failed: " + str(exc) + "\n")


if __name__ == "__main__":
    main()
