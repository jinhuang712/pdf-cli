# 026. macOS updates leave the cache alone

Decided: 2026-10-15    Status: current

The cache key holds the page content and the parser version, and leaves the macOS version out, so a macOS update parses nothing again. Each page records the macOS build it was parsed on, and `pdf reparse` reads a page or a file again on the running macOS. When the test set shows that a macOS release changes the output, a new pdf-cli release raises the parser version, and each page is parsed again on its next read.

This follows "Pay once, read many times" and "Same file, same answer". A document seldom mixes two macOS versions, because a worker parses the whole document right after its first use.

| Option | For | Against |
|---|---|---|
| **macOS left out of the key** | Nothing is parsed twice. A cached answer never changes on its own. | Apple's fixes reach a cached file only through `pdf reparse` or a new pdf-cli release. |
| The macOS major version in the key | Each yearly macOS brings its fixes to every file read again. | Every file is parsed again once a year. A 300-page scan costs about 3 minutes of OCR. |
| The full macOS build in the key | Every page matches the running macOS. | Every minor update, several a year, parses everything again. |
