# Changelog

## 0.1.0

Initial independent native macOS release for one USB-connected Evolis Avansia.

- Standard macOS printer queue with CR80, 600 dpi, PDF bleed handling and duplex
  orientation, plus actual-size, fit and fill option forwarding.
- Separate binary K artwork, retained manufacturer covering and zero-ink pure
  white pixels, with no automatic physical-card retries.
- Simplified Chinese utility for supplies, ribbon identity, reported accessory
  presence, typed settings, PDF submission, installation and recovery.
- Periodic bounded supply updates in the local IPP printer, separate from
  explicit idle-only identity and menu reads.
- Transactional installation/update with verified runtime, service and queue
  restoration; retained uncertainty state when recovery cannot be established.
- Locally generated transparent product icons and a project-owned public
  fallback. Proprietary SDK binaries and product artwork are not redistributed.

The first binary targets Apple Silicon and macOS 14 or newer. It is ad-hoc
signed and not notarized. See `Docs/Support.md` for unsupported official-driver
features and hardware validation limits.
