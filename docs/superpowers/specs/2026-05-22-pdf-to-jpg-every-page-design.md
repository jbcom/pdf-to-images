# Convert PDF to JPG — every page + montage

**Date:** 2026-05-22
**Status:** Approved

## Problem

The current repo ships a macOS Automator Quick Action that converts a PDF to a
single JPG via `sips`. It has defects:

1. **`sips` only rasterizes page 1** of a multi-page PDF — a hard tool limitation,
   hence the README's "single-page only" caveat.
2. `${pdf%.pdf}` strips only lowercase `.pdf`; `Report.PDF` → `Report.PDF.jpg`.
3. No collision handling — re-running silently overwrites output.
4. No PDF validation, no `sips` exit-code check — failures are swallowed.
5. No quality/DPI flags — text-heavy PDFs come out blurry.
6. No user feedback on success or failure.

Automator is also being phased out by Apple in favor of Shortcuts.

## Goals

- Extract **every** page of a PDF as its own JPG into a subdirectory.
- Build a **montage** image of all pages.
- Ship a modern **Shortcut** alongside the fixed **Automator workflow**.
- **Zero Homebrew dependencies.** The only acceptable install prompt is the
  macOS "install developer tools" popup if Xcode CLT is absent.
- Standard CI/CD: `ci.yml` → `release.yml` → `cd.yml` with release-please.
- Break the GitHub fork relationship; credit the original author.
- Rename the repo to `pdf-to-images` — the project is the engine, not any one
  wrapper. Keep the engine OS-agnostic so Linux DE integration (GNOME Files /
  Dolphin / Nautilus actions) can be added later without touching it.

## Non-goals

- Output formats other than JPEG.
- Configurable DPI/quality UI (fixed sensible defaults).
- Linux/Windows wrappers **in this iteration** — the engine stays portable so
  Linux integration is a clean future addition, but no Linux wrapper ships now.

## Architecture

Single engine, two thin wrappers:

```
pdf-to-images.swift                 ← engine (PDFKit/Quartz, zero deps)
  ├── Convert PDF to JPG.workflow   ← Automator Quick Action wrapper
  └── Convert PDF to JPG.shortcut   ← Shortcuts Quick Action wrapper
```

### Engine — `pdf-to-images.swift`

Swift script run via `swift pdf-to-images.swift <pdf> [<pdf> ...]`.
`swift` ships with the Xcode Command Line Tools; if absent, invoking it triggers
the standard macOS "install developer tools" popup. No Homebrew, no `sips`.

The engine depends only on PDFKit + CoreGraphics, both of which Swift exposes on
Linux too (via swift-corelibs / the open-source PDFKit shims). It is written so
that platform-specific code paths, if ever needed, are isolated behind `#if
os(macOS)` — keeping a future Linux build a wrapper-only effort.

Per PDF argument:

1. Open with `PDFDocument` (PDFKit). If it fails or has 0 pages → print an
   error to stderr, skip this PDF, continue with the rest.
2. Create subdir `<PDFname>_pages/` beside the source PDF. **Overwrite cleanly**:
   if it exists, remove and recreate it so stale images never linger.
3. Render every page to `page-001.jpg`, `page-002.jpg`, … (zero-padded to the
   page count's width) at **144 DPI**, **JPEG quality 0.85**.
4. Build `<PDFname>_montage.jpg` beside the PDF:
   - Grid is near-square: `cols = ceil(sqrt(n))`, `rows = ceil(n / cols)`.
   - Each cell holds one page scaled to a uniform thumbnail width, preserving
     aspect ratio, centered, on a white background, with thin gray separators.
   - **Skipped when the PDF has exactly 1 page** (montage would duplicate it).
5. Print one summary line per PDF to stdout:
   `<name>.pdf → N page(s) in <name>_pages/ + montage`.

Exit code: `0` if at least one PDF succeeded; non-zero only if **every** input
failed.

Case-insensitive extension handling: strip the extension via path APIs
(`deletingPathExtension`), not a lowercase-only string suffix.

### Wrappers

Both wrappers locate `pdf-to-images.swift` relative to themselves and run
`swift <script> "$@"`, so a user who downloads a release artifact just
double-clicks to install — no repo clone needed.

- **`Convert PDF to JPG.workflow`** — the existing Run Shell Script action;
  `COMMAND_STRING` replaced with the dispatcher. The script is bundled inside
  `Contents/` so the workflow is self-contained.
- **`Convert PDF to JPG.shortcut`** — a Quick Action (Finder, receives PDF
  files) with a Run Shell Script action calling the same engine. Built and
  validated via the `shortcuts-playground` skill.

### Error handling

- Per-PDF failures (not a PDF, unreadable, zero pages) print to stderr, skip,
  and continue. The batch does not abort on one bad file.
- The wrappers surface a Finder/Notification Center message on completion.
- Engine exits non-zero only when no input produced output.

## CI/CD

Three workflows. **Every `uses:` is pinned to a commit SHA** resolved live from
GitHub on 2026-05-22 (not training data); the trailing comment records the tag.

### `ci.yml` — on `pull_request`, `macos-latest`

1. `swift -typecheck pdf-to-images.swift` — compile check.
2. **Integration test** (`tests/run-integration-test.sh`):
   - `tests/make-fixture.swift` generates a deterministic PDF whose pages are
     each a solid primary fill (page 1 red, 2 green, 3 blue, 4 yellow, …).
     The fixture is generated at test time, not checked in as a binary.
   - Run the engine on the fixture.
   - Assert each `page-NNN.jpg` exists and its center pixel matches the
     expected fill color within tolerance.
   - Assert `<name>_montage.jpg` exists, has the expected grid dimensions, and
     each grid cell's center pixel matches the corresponding page's fill.

Integration (not unit) testing is the right call here: the montage geometry and
color fidelity are exactly what can silently regress, and a primary-color
fixture makes every assertion deterministic.

### `release.yml` — on push to `main`

`googleapis/release-please-action` with `release-please-config.json` +
`.release-please-manifest.json`:

- `release-type: simple` (no `package.json` in this repo).
- Automated `CHANGELOG.md`, conventional-commit versioning, release PR.
- `extra-files`: `version.txt` so wrappers/README can display a version.
- Authenticated with the `CI_GITHUB_TOKEN` secret (a PAT) so release PRs
  re-trigger CI.

### `cd.yml` — on `workflow_run` of "Release" completing successfully

- Zip `Convert PDF to JPG.workflow` and `Convert PDF to JPG.shortcut` (each
  bundling the engine script).
- `softprops/action-gh-release` attaches both zips to the GitHub Release.
- README install section points users at the Releases page — removes the
  "download the whole repository" friction.

### `dependabot.yml`

`github-actions` ecosystem, monthly, so SHA pins stay current.

## Pinned action SHAs (resolved 2026-05-22)

| Action | SHA | Tag |
|---|---|---|
| actions/checkout | `de0fac2e4500dabe0009e67214ff5f5447ce83dd` | v6.0.2 |
| googleapis/release-please-action | `45996ed1f6d02564a971a2fa1b5860e934307cf7` | v5.0.0 |
| softprops/action-gh-release | `b4309332981a82ec1c5618f44dd2e27cc8bfbfda` | v3.0.0 |

(Additional actions, e.g. `actions/upload-artifact@043fb46d… v7.0.1`, pinned as
needed during implementation, each resolved live from GitHub.)

## Repository changes

- **Un-fork:** delete and recreate `jbcom/convert_pdf_to_jpg_on_mac` as a
  standalone (non-fork) repo so it has its own Issues/Actions surface and no
  upstream PR target. Local git history is the source of truth and is preserved.
- **Attribution:** README and LICENSE credit the original author
  (`sanjeed5/convert_pdf_to_jpg_on_mac`).
- **README rewrite:** install via Releases (download `.workflow` or
  `.shortcut`), drop the "single-page only" caveat, document the
  per-page-subdir + montage behavior.

## Testing

`tests/` contains:

- `make-fixture.swift` — generates the primary-color multi-page test PDF.
- `run-integration-test.sh` — drives the engine and asserts page count, file
  existence, per-page fill colors, and montage grid geometry + cell fills.

Wired into `ci.yml` on `macos-latest`.

## File layout (after implementation)

```
pdf-to-images.swift
version.txt
release-please-config.json
.release-please-manifest.json
.github/
  workflows/ci.yml
  workflows/release.yml
  workflows/cd.yml
  dependabot.yml
Convert PDF to JPG.workflow/        (engine bundled inside Contents/)
Convert PDF to JPG.shortcut         (built via shortcuts-playground)
tests/
  make-fixture.swift
  run-integration-test.sh
docs/superpowers/specs/2026-05-22-pdf-to-jpg-every-page-design.md
README.md  LICENSE
```
