# Avansia macOS Driver

A third-party native macOS compatibility driver and companion utility for Evolis Avansia. This project is independent of Evolis.

The companion application has a Simplified Chinese interface. It installs a per-user printer named `Evolis_Avansia`, available in the normal macOS print dialog, and monitors the USB-connected printer without replacing the system printing service.

## Supported system

- Apple Silicon Mac, macOS 14 or newer.
- One USB-connected Evolis Avansia. Ethernet transport is not implemented.
- Standard CR80 cards, 53.98 × 85.60 mm, with 600 dpi rendering.
- Single-sided and duplex PDF jobs, including artwork with bleed.

The initial application is ad-hoc signed and is not notarized. See [installation and recovery](Docs/Installation.md) before installing. Intel builds are not supplied in this release.

## Install

1. Download the macOS arm64 application archive from [Releases](https://github.com/qianxueye/avansia-macos-driver/releases).
2. Extract the application into a folder you can keep, such as `~/Applications`, and open it.
3. In the installation page, choose Install. The application obtains the pinned native SDK and the transparent product image from their original distribution endpoints. An existing supported SDK archive or library can also be imported.
4. Connect and power on the Avansia, then refresh detailed status. Use the PDF printing page or the standard macOS print dialog.

The SDK archive is a distribution container. No Python interpreter, Python driver, virtual machine or Windows installation is required.

## Printing and monitoring

The renderer preserves physical artwork size and page boxes, supports edge bleed, and generates a separate binary K layer for fine black artwork. Duplex jobs use an explicit back-face orientation. Pure-white pixels remain zero ink in all color and K planes.

The utility shows printer connection and recovery state, ribbon and transfer-film percentages, ribbon identity, firmware, and reported accessory presence. Detailed identity/settings reads happen only while idle. It exposes discovered, typed settings with fresh-value validation and exact readback. Unknown values remain unknown.

After a failed or uncertain card operation, the driver retains the task and blocks another card. Inspect the physical printer/card before acknowledging recovery. It never automatically retries a card that may already have been printed.

See the [feature and validation matrix](Docs/Support.md) for the distinction between implemented features, synthetic checks, physical acceptance and unsupported official-driver functions. Printer calibration and color matching remain device-, ribbon- and card-specific; this repository does not include a user's workcard, color profile or hardware calibration values.

## Build and test

Install Apple's Command Line Tools, then run:

```sh
Scripts/build.sh
Scripts/test-core.sh
Scripts/test-print-safety.sh
Scripts/test-setup.sh
Scripts/test-assets.sh
Scripts/test-icons.sh
Scripts/test-job-lock.sh
Scripts/test-app.sh
Tests/IPPStatus.sh
Tests/IPPStatusIntegration.sh
Scripts/test-raster.sh
```

The build downloads integrity-pinned CUPS and libusb source archives. Public tests use synthetic artwork and mock device responses. The raster integration test creates and removes a uniquely named local test queue and uses a separate local IPP server; it does not send data to a USB printer.

The built application is `build/application/Avansia Utility.app`. A clean release build additionally requires `RELEASE_BUILD=1`. [Architecture](Docs/Architecture.md) describes the runtime contracts and recovery boundaries.

## Licenses

Official Evolis SDK binaries and product artwork are external dependencies and are not redistributed in this repository.

Original source is MIT licensed. CUPS, libusb, the proprietary SDK and artwork retain their respective terms. Read [third-party notices](Docs/ThirdPartyNotices.md).
