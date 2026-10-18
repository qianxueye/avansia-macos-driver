# Third-party components and artwork

The MIT license covers this project's original source. It does not relicense
Evolis software, product images, trademarks or the components below.

## Evolis SDK

Printing uses the native macOS library from Evolis SDK 9.4.1. The proprietary
library and its distribution archive are not included in this repository or
the public application bundle. Installation can obtain the exact archive from
the original Evolis-published package distribution, verify its archive and
library integrity pins, and extract only the native macOS library. Python is
not installed or executed. A user-obtained supported archive/library can also
be imported. Any applicable Evolis terms remain the user's responsibility;
this project does not claim a redistribution grant or issue an Evolis license.

- SDK publisher and documentation: https://www2.evolis.com/sdk
- Evolis-published package: https://pypi.org/project/Evolis-SDK/9.4.1/
- Official SDK scope: https://www.evolis.com/our-solutions/software/evolis-premium-sdk-software-development-kit/

Avansia is not fully supported by the general SDK package. Feature availability
and validation are stated separately in the feature matrix.

## Evolis product artwork

The Avansia product photo is obtained from Evolis for the user's local
installation. It already contains transparency. It and its PNG/ICNS derivatives
are excluded from public source and application archives. The public bundle
contains a generic printer graphic created by this project. Evolis and Avansia
remain the respective trademark holders' marks; this is an independent driver.

- Product page: https://us.evolis.com/solutions/card-printers-us/avansia-card-printer/
- Website terms: https://www.evolis.com/legal-notices/

## CUPS 2.4.14

The private IPP engine uses OpenPrinting CUPS 2.4.14 under Apache License 2.0
with its stated exceptions. It does not replace macOS CUPS. The application
contains the upstream LICENSE, NOTICE, the exact local patches and source/build
references under `runtime/share/licenses/cups`. The release supplies the
corresponding upstream archive and patches as a separate source asset.

- Source: https://github.com/OpenPrinting/cups/releases/tag/v2.4.14
- Local modifications: `Patches/`

## libusb 1.0.29

The native USB adapter dynamically loads libusb 1.0.29, distributed under
GNU LGPL version 2.1 or later. Its COPYING file accompanies the library. The
release supplies the corresponding upstream source archive, and
`Scripts/build-libusb.sh` records the build and install-name adjustment.
The dynamic library remains replaceable; the application has no library
validation entitlement restricting such replacement.

- Source and license: https://github.com/libusb/libusb/releases/tag/v1.0.29

The compiler uses Apple's system frameworks and macOS CUPS client library.
Those system components are not redistributed in this project.
