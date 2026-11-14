# QANI handshake/backend integration scaffold

**Not an operational BLE peripheral. Not an Apple NI firmware implementation.**
`qani_ble_bridge.py` implements the handshake state machine and a subprocess
backend adapter. Its only runnable transport is explicitly diagnostic stdin/stdout.
No radio or hardware access is performed by this scaffold itself.

## Real backend required

A backend executable must implement actual accessory firmware control, produce
valid Apple Nearby Interaction accessory configuration for that device/session,
and apply the opaque shareable configuration returned by iOS. The plain FiRa
`run_fira_dt` commands do not establish that capability. Do not reuse captured
configuration from another device/session or invent configuration bytes.

Launch the diagnostic harness with the backend executable and all its arguments
last (no shell evaluation):

```powershell
.\.venv\Scripts\python.exe scripts\fira\run_fira_dt\qani_ble_bridge.py --stdio --backend-command C:\path\to\real_backend.exe
```

Each diagnostic input line is a complete message encoded as hexadecimal. `0a`
initializes; `0b` followed by nonempty opaque iOS bytes applies configuration;
`0c` stops. Each output is JSON containing `notification_hex`, or `error`.
This is **not** a Bluetooth interface and cannot connect to an iPhone.

### Backend JSON-lines contract

One persistent child process, UTF-8 JSON per line, request/response serialized.
Stdout is exclusively protocol data; diagnostics go to stderr. Requests:

```json
{"id":1,"operation":"initialize","payload_hex":""}
{"id":2,"operation":"apply","payload_hex":"<opaque iOS bytes in hex>"}
{"id":3,"operation":"stop","payload_hex":""}
```

Responses echo `id`, require Boolean `ok: true`, and contain `payload_hex`.
`initialize` must return real, nonempty accessory configuration. `apply` and
`stop` must return an empty payload **only after hardware acknowledges success**.
For failure return `ok: false`; no success notification is generated. The bridge
returns `01 + configuration`, `02`, and `03` respectively after those responses.
Timeout, malformed response, backend rejection, or cancellation faults the session;
restart the backend and reinitialize rather than retrying uncertain operations.
The backend must stop ranging on pipe EOF/process exit and have its own hardware
watchdog: the host cannot guarantee cleanup after a crash or transport failure.
Payloads are capped at 65536 bytes; this cap is not a BLE MTU.

## BLE transport blocker / remaining integration

The supplied Windows venv has WinRT 3.2.1 GATT-provider bindings; importing
`GattServiceProvider` succeeds. This verifies API availability only, not local
adapter peripheral support, OS permissions, advertising, or client interoperability.
No GATT service is created by this scaffold and no hardware was exercised.

A production transport still needs verified Qorvo service/RX/TX UUIDs and profile,
client subscription before initialization replies, OS error/status handling,
per-connection ownership, actual MTU-aware delivery/reassembly per the agreed
profile (never arbitrarily chunk opaque NI bytes), serialized writes, unsubscribe
and disconnect stop, and deterministic cleanup. Do not advertise a fabricated
security characteristic or claim an unsecured custom GATT service implements the
Apple Nearby Interaction accessory security profile.

## Tests (no hardware, fake backend only)

From this directory, using the repository venv Python:

```powershell
..\..\..\..\.venv\Scripts\python.exe -m unittest -v test_qani_ble_bridge.py
```

The test marker bytes `TEST` / `TEST-ONLY` are intentionally invalid as NI
configuration and are never available as a production default.
