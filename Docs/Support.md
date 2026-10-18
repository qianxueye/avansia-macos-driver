# Feature and validation matrix

This is an independent compatibility implementation, not a claim of complete
feature parity with the official Windows driver. Software checks, installation,
device completion and physical quality acceptance are different evidence.

| Capability | Initial release scope | Validation boundary |
| --- | --- | --- |
| Normal macOS printer queue | Per-user private IPP bridge to USB Avansia | Real system queue and printer completion |
| CR80, 600 dpi, edge bleed | Physical page/TrimBox geometry and vector-derived raster | Synthetic geometry cases and accepted physical duplex workcards |
| Single-sided and duplex | Long-edge and short-edge orientation handling | Synthetic orientation checks; physical long-edge duplex accepted |
| Actual size, fit and fill | Native renderer and queue option forwarding | Nine geometry cases and four isolated system-queue jobs; original PDF bytes and options verified |
| Fine black artwork | Separate binary K mask; manufacturer covering under K retained | Protocol/mask tests and owner-accepted physical text/barcodes |
| White artwork | Zero C/M/Y/K at pure-white raster pixels | Final print-stream checks and physical acceptance |
| Printer icon | Locally obtained transparent product photo, generic bundled fallback | Native alpha/icon tests; local queue integration |
| Ribbon and transfer film | Reported percentages; unknown is distinct from zero | Synthetic boundary tests and live device readback |
| Ribbon model | Explicit idle-only authenticated identity refresh | Live ribbon identification; no periodic authentication loop |
| Accessories | Reported magnetic encoder, chip ports and external box presence | Discovery/readback only; absent hardware functionality unverified |
| Printer/image/card/heater settings | Discovered allowlisted typed values and verified black-quality choice | Fresh descriptor/expected-value validation, one write, exact readback |
| Recovery | Retained stopped task, uncertain-card inspection and setting-write reconciliation | Failure-injection tests; no automatic physical retry |
| Chinese utility | Overview, supplies, accessories, settings, PDF printing, installation and recovery | Resource/model checks and release UI inspection |

## Not implemented or not verified

- Ethernet/USB printer selection and multiple simultaneous Avansia devices.
- Firmware updates, factory resets, cleaning or motor/maintenance actions.
- Chip or magnetic-stripe encoding, encoder SDK integration, or a lamination
  workflow. Presence reporting is not operational validation of an accessory.
- YMCKI inhibitor/no-transfer regions, UV or holographic-panel workflows.
- A measured ICC output profile, spectrophotometer calibration or guaranteed
  screen-to-card color matching. Per-device owner adjustments are not universal
  release defaults.
- Intel binaries, Developer ID signing and notarization.

Physical acceptance used CR80 PVC cards, YMCK consumables, duplex output,
separate K fine artwork, true-white elements and a reverse-polarity PDF417.
An owner accepted a printed dual-interface chip card. The repository contains
none of that owner's artwork, payloads, images, serial captures or calibration
values. It does not assert that all contact-card materials behave identically
at the chip surface.
