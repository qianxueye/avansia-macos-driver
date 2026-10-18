# Initial native release contract

The runtime remains a per-user installation for one USB Avansia. Printing uses
the existing native job, Core, renderer and private IPP engine. The companion
application consumes the same Core interfaces and does not implement USB itself.

## PDF transport and geometry

The system queue preserves the original PDF through an explicit direct-PDF PPD
route. The private software printer reports its actual pinned CUPS component
version through `cups-version`. This identifies the local software RIP, not
the physical printer firmware. It enables the system IPP backend's standard
option-encoding path rather than its lossy PPD conversion path. The engine
advertises the three implemented scaling modes: none, fit and fill.

The isolated system-queue gate verifies original PDF bytes exactly once,
explicit scaling, copies, duplex and selected-page forwarding before exposing
these choices. CardRaster then applies physical CR80/bleed geometry using the
original document page boxes. No arbitrary mandatory PPD fields or alternate
gzip/filter route is required.

## Status

`AvansiaCore snapshot` performs a cheap status refresh and atomically stores
`state/status.json` under the existing user driver directory. `snapshot
--refresh-details` additionally discovers USER information and ribbon identity
only when idle. The normal poll must not enter the authenticated RFID channel.

The JSON response uses `schema_version: 1`, `updated_at` (ISO 8601),
`observed_at` (last successful hardware observation or null), `connection`
(`ready`, `busy`, `recovery`, `disconnected`, `error`, or `unknown`), and `stale`.
`device` contains known status fields; `ribbon` contains `remaining_percent`,
optional `reference`, `label`, `region` and `identity_observed_at`; `film`
contains `remaining_percent` and an optional type. Unknown percentages are null,
never zero. `accessories` is an array of `id`, `name` and `status` (`connected`,
`disconnected`, or `unknown`). The `queue` object independently reports
`active_job` and `recovery_required`. `error` is an optional human-readable
diagnostic. Cached identity is valid only for its observed printer serial.

Active or uncertain markers prevent new USB reads. A busy common mutex means
deferred refresh, not disconnection. Preserve the last successful observation
time while deferred. The UI may read the cache frequently; the engine refreshes
hardware approximately every 15 seconds without overlapping helpers.

`AvansiaCore ipp-status` uses the same snapshot operation and emits only:

```
AVANSIA_STATUS_V1 ready 90 90
```

The four whitespace-separated tokens are a fixed prefix, a connection state
from the above enumeration, and ribbon/film integer percentages (-1 means
unknown). The private engine's `--status-command PATH` invokes this executable
with the `ipp-status` argument without a shell, bounds execution and output,
and updates only hardware/supply fields while preserving active and stopped
job state. No new control endpoint is exposed.

## Settings

`AvansiaCore settings` returns schema version 1 with `settings` (typed logical
IDs, label, group, numeric current/minimum/maximum, choices when applicable,
and `writable`) and `information` (label/value observations). Discover selectors
from the connected device. Unknown/action descriptors are read-only. The UI
never supplies raw selector or payload bytes.

`AvansiaCore set-setting ID EXPECTED VALUE --device-serial SERIAL` changes one allowlisted USER scalar
or choice setting. Require idle queue and printer, shared mutex, matching fresh
printer serial, descriptor identity/type/range and expected current value;
write once and require exact
fresh readback. An uncertain result requires explicit refresh before another
attempt. Service actions, firmware, movement and unknown fields are not generic
write targets. The verified black-quality choice is exposed as one explicit
typed setting.

## Packaging and licensing

Installation identity is read through `AvansiaSetup queue-info`. The native
bridge sends read-only Get-Printer-Attributes requests over the fixed macOS
Unix socket `/private/var/run/cupsd`, with the logical printer URI
`ipp://localhost:631/printers/Evolis_Avansia`. It validates the exact queue name
and device URI independently of `CUPS_SERVER` or user destination options. Only an explicit IPP not-found response means absence; connection,
authorization and malformed-response failures remain errors. Human-readable
CUPS output is not an identity interface, and command locale settings do not
guarantee the language selected by macOS CUPS. Retained runtime files are
separate from verified queue/service installation state.

All CUPS queue commands and PDF submissions explicitly select the same local
Unix socket. A configured remote scheduler cannot redirect an operation after
local queue ownership has been verified.

The public repository contains owned native sources, synthetic tests, build
scripts, reviewed CUPS patches and required open-source notices. The source is
MIT licensed. Do not include personal card artwork, PDFs, photos, device logs,
serial captures, proprietary SDK binaries or Evolis product artwork.

The application obtains the exact official SDK archive and product image from
their original public distribution endpoints, or imports a user-provided SDK.
Archive integrity pins are download-integrity invariants. No Python runtime is
required to extract the native macOS library. The official image already has
alpha; preserve it when producing local PNG/ICNS resources. A project-owned
fallback icon is used when the external artwork is unavailable.

The installer must unwind only resources created by its failed invocation and
restore the prior runtime when safe. It preserves print jobs, recovery state,
other printers, the default printer and an existing user color profile.

## Acceptance boundaries

Keep source, synthetic tests, installation, printer-reported completion and
physical quality acceptance distinct. Physical duplex workcards were accepted
after source-white corrections and device-specific color/registration work.
That acceptance does not validate unattached encoder/lamination hardware or
make the device-specific calibration universal. The initial
binary target is macOS 14 or newer on Apple Silicon; signing/notarization claims
must match the actual build credentials.
