# Installation and recovery

## Application and external components

The release targets Apple Silicon and macOS 14 or newer. It is ad-hoc signed,
not Developer ID signed or notarized. macOS may require the standard Open Anyway
approval in System Settings, Privacy & Security, after the first launch attempt.
Only approve an application you obtained from this project's release page.

Keep the application in a stable, user-writable location. The utility installs
the runtime under `~/Library/Application Support/AvansiaDriver` and a login
service under `~/Library/LaunchAgents`. The printer queue is `Evolis_Avansia`.
The local IPP endpoint is `ipp://localhost:18631/ipp/print` and is not shared on
the network. Logs are under `~/Library/Logs/AvansiaDriver`.

The installer fetches the supported Evolis SDK archive from its original
publisher endpoint and extracts the native macOS library. It verifies the
archive and staged library against the supported integrity pins. A supported
official archive or macOS library can instead be imported from the installation
page. The proprietary library is not included in the public application.

The product photograph is fetched from Evolis for the local installation.
Transparent PNG and ICNS icons are produced locally. A project-owned generic
printer icon remains available if the external image cannot be obtained.

## Update and uninstall

Finish or explicitly resolve pending, stopped and uncertain Avansia jobs before
updating or removing the driver. Update stages the replacement runtime before
changing the existing installation. Recovery retains the prior runtime when it
cannot safely finish restoring the previous service and queue.

An existing user color profile and recovery records are retained. Other printer
queues and the default printer are not changed. Uninstall removes the Avansia
queue and its login service, retaining runtime and recovery records for manual
inspection.

## An uncertain card is not a retry request

Heating, printing and retransfer can take several minutes. A processing task
does not itself imply a printer failure. Wait for device completion and inspect
the actual output.

If the driver cannot establish the outcome after sending card data, it retains
an uncertainty marker. Do not resubmit the card automatically. Inspect the
printer and output card, resolve local queued jobs in Print Center, and use the
utility's recovery page to acknowledge that inspection. Cancelling a retained
stopped native job and acknowledging an uncertain physical card are separate
operations.

## Color and card handling

Use the correct card material/thickness and consumables. Keep physical color
calibration separate from artwork colors: an intended white element must be
white in the source document. A light-gray design element is intentionally
printed. White in a raster means no dye; it does not define a general transfer-
film exclusion area.

Contact-chip orientation follows the printer's selected Standard/Reverse card
setting and the feeder diagram. Chip writing requires separate supported
encoder hardware/software. Neither printing a PDF nor changing a printed
barcode programs the chip. No generic inhibitor, encoding, maintenance-movement
or firmware action is exposed by this release.
