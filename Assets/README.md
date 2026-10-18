# Icon assets

No official Evolis product photograph or photograph-derived PNG/ICNS belongs in this repository. Public redistribution permission has not been established. The installer can download the original image into the user's private cache and call the native converter there. Do not commit that cache or its outputs.

Official source URL:

https://us.evolis.com/wp-content/uploads/2023/03/avansia-card-printer-evolis-940x0-c-default.png

The inspected original is a transparent 940 × 940 PNG. `BuildIcons` verifies real transparent and visible pixels before conversion; an opaque, completely transparent, invalid, or non-PNG input fails. It does not remove backgrounds, invent cutouts, redraw product details, or change the brand. Resizing retains aspect ratio and centers the image in transparent square canvases. Color encoding is sRGB.

## Native build and CLI

Compile the standalone tool into the package next to Setup:

```sh
swiftc -O Tools/BuildIcons.swift -o /path/to/package/BuildIcons
```

Convert the privately downloaded original:

```sh
/path/to/package/BuildIcons /path/to/private-cache/avansia-official.png /path/to/private-cache/icons
```

Create the public application's project-owned fallback until the private download succeeds:

```sh
/path/to/package/BuildIcons --fallback /path/to/build/fallback-icons
```

The fallback is original CoreGraphics geometric artwork, not an Apple SF Symbol or a rendering of the manufacturer's product. The tool never downloads, installs, changes queues, or communicates with printers. Queue integration can use the privately generated official PNG after a successful download/conversion.

Both modes create:

| File | Pixels / purpose |
| --- | --- |
| `Avansia-48.png` | 48 × 48 |
| `Avansia-128.png` | 128 × 128 |
| `Avansia-512.png` | 512 × 512 |
| `Avansia.png` | 512 × 512 alias |
| `Avansia.icns` | 16, 32, 128, 256 and 512 logical pixels at 1× and 2×; maximum 1024 pixels |

Successful stdout is JSON with source/output dimensions and counts of fully transparent, partially transparent, and opaque pixels. Errors go to stderr with a nonzero exit status. ICNS construction uses macOS `/usr/bin/iconutil`; intermediate iconsets are temporary and removed.

## Synthetic boundary checks

No official artwork is used by public tests:

```sh
swiftc -O Tools/BuildIcons.swift -o /private/tmp/BuildIcons
swiftc -O Tests/IconTests.swift -o /private/tmp/IconTests
/private/tmp/IconTests /private/tmp/BuildIcons
```

These tests verify transparent source pixels and resized outputs, known opaque center color, required PNG dimensions, ICNS structure/retina size, project-owned fallback, and rejection of opaque/invalid inputs.
