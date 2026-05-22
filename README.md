# pdf-to-images

Convert **every page** of a PDF into JPG or PNG images — plus a montage of all
pages — straight from the macOS Finder. Local, private, zero dependencies.

This project began as a fork of
[sanjeed5/convert_pdf_to_jpg_on_mac](https://github.com/sanjeed5/convert_pdf_to_jpg_on_mac);
thanks to the original author for the starting point.

## What it does

Right-click a PDF in Finder → **Quick Actions** → **Convert PDF to JPG**
(or **PNG**). For `Report.pdf` you get:

- `Report_pages/` — `page-001.jpg`, `page-002.jpg`, … one image per page.
- `Report_montage.jpg` — a near-square grid of every page (skipped for
  single-page PDFs).

Rendering is 144 DPI; JPG uses quality 0.85; PNG is lossless.

## Install

Download the action you want from the
[latest release](https://github.com/jbcom/pdf-to-images/releases/latest):

| File | Installs into |
|---|---|
| `Convert-PDF-to-JPG.workflow.zip` | Automator Quick Action (JPG) |
| `Convert-PDF-to-PNG.workflow.zip` | Automator Quick Action (PNG) |
| `Convert-PDF-to-JPG.shortcut.zip` | Shortcuts Quick Action (JPG) |
| `Convert-PDF-to-PNG.shortcut.zip` | Shortcuts Quick Action (PNG) |

Unzip and double-click the `.workflow` or `.shortcut` to install it. macOS adds
it to the Quick Actions menu in Finder.

Apple is phasing Automator out in favor of Shortcuts — the `.shortcut` versions
are the forward-looking choice; the `.workflow` versions remain for older macOS.

## Requirements

- macOS (modern versions).
- The Xcode Command Line Tools. If they are missing, the first run shows the
  standard macOS "install developer tools" prompt — click Install and run the
  action again. **No Homebrew, no other downloads.**

## How it works

A single Swift script, `pdf-to-images.swift`, uses Apple's PDFKit and
CoreGraphics to render and montage pages. Each Quick Action is a thin wrapper
that calls it with a fixed `--format`. The engine has no platform-specific
dependencies, so Linux file-manager integrations are a natural future addition.

## Development

```bash
# Run the engine directly
swift pdf-to-images.swift --format png path/to/file.pdf

# Rebuild the Automator wrappers from the template + engine
./build-wrappers.sh

# Run the integration test
./tests/run-integration-test.sh
```

## License

[MIT](LICENSE). Original work © sanjeed5; modifications © Jon Bogaty.
