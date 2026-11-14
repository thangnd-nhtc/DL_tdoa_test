# QANI Windows BLE bridge

`qani_ble_bridge.py --advertise` now creates a real Windows WinRT GATT peripheral,
using Nordic UART service `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`, RX `...0002`
(Write with response) and TX `...0003` (Notify). It is not an Apple NI firmware
implementation and does not provide or impersonate the NI security profile.

From `Samples/Python/UWB-Qorvo-Tools`:

```powershell
.\.venv\Scripts\python.exe scripts\fira\run_fira_dt\qani_ble_bridge.py --advertise --backend-command C:\path\to\real_backend.exe
```

**A real NI-capable backend is still missing from this repository.** Replace the
placeholder with an actual executable implementing the contract below. Omitting
it is a CLI error. There is no synthetic configuration fallback. Windows Bluetooth
adapter peripheral support and permissions are required; creation/advertising
failures are reported. No advertising or hardware test was performed during development.

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

## BLE transport behavior

The central must subscribe before sending `0a`. One subscribed central owns the
session; other centrals cannot write to that session. WinRT event deferrals cover
asynchronous handling; writes and subscription-loss cleanup are serialized.
Every request must have offset zero and contain a complete QANI message. Every
response is one notification: oversized replies are rejected, never fragmented
with an invented protocol. Negotiate enough ATT MTU for accessory configuration
before initialization. NUS is only a data transport, not proof of NI compatibility.

Unsubscribe/disconnect ends the bridge session and stops an acknowledged active
backend session. Notification/backend errors end advertising and close the backend.
Ctrl+C also stops advertising, removes event handlers, stops known active ranging,
and terminates the persistent backend. Uncertain/faulted hardware state requires
the backend's EOF/exit watchdog; no host can guarantee cleanup after a crash.

## Tests (no hardware, fake backend only)

From this directory, using the repository venv Python:

```powershell
..\..\..\.venv\Scripts\python.exe -m unittest -v test_qani_ble_bridge.py
```

The test marker bytes `TEST` / `TEST-ONLY` are intentionally invalid as NI
configuration and are never available as a production default.
