# pdf-to-images — every page + montage

**Date:** 2026-05-22
**Status:** Approved

## Problem

The original repo ships a macOS Automator Quick Action that converts a PDF to a
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

- Extract **every** page of a PDF as its own image into a subdirectory.
- Support **JPG and PNG** output.
- Build a **montage** image of all pages.
- Ship modern **Shortcuts** alongside fixed **Automator workflows**.
- **Zero Homebrew dependencies.** The only acceptable install prompt is the
  macOS "install developer tools" popup if Xcode CLT is absent.
- Standard CI/CD: `ci.yml` → `release.yml` → `cd.yml` with release-please.
- Break the GitHub fork relationship; credit the original author.
- Rename the repo to `pdf-to-images` — the project is the engine, not any one
  wrapper. Keep the engine OS-agnostic so Linux DE integration (GNOME Files /
  Dolphin / Nautilus actions) can be added later without touching it.

## Non-goals

- Output formats other than JPG/PNG (e.g. TIFF, WebP).
- Configurable DPI/quality UI (fixed sensible defaults).
- Linux/Windows wrappers **in this iteration** — the engine stays portable so
  Linux integration is a clean future addition, but no Linux wrapper ships now.

## Architecture

Single engine, four thin wrappers (one Automator + one Shortcut per format):

```text
pdf-to-images.swift                 ← engine (PDFKit/Quartz, zero deps)
  ├── Convert PDF to JPG.workflow   ← Automator Quick Action (jpg)
  ├── Convert PDF to PNG.workflow   ← Automator Quick Action (png)
  ├── Convert PDF to JPG.shortcut   ← Shortcuts Quick Action (jpg)
  └── Convert PDF to PNG.shortcut   ← Shortcuts Quick Action (png)
```

### Engine — `pdf-to-images.swift`

Swift script run via `swift pdf-to-images.swift --format <jpg|png> <pdf> [<pdf> ...]`.
The `--format` flag defaults to `jpg` when omitted. `swift` ships with the Xcode
Command Line Tools; if absent, invoking it triggers the standard macOS "install
developer tools" popup. No Homebrew, no `sips`.

The engine depends only on PDFKit + CoreGraphics, both of which Swift exposes on
Linux too (via swift-corelibs / the open-source PDFKit shims). It is written so
that platform-specific code paths, if ever needed, are isolated behind `#if
os(macOS)` — keeping a future Linux build a wrapper-only effort.

Argument parsing: a single optional `--format jpg|png` flag, then one or more
PDF paths. Unknown format → error and non-zero exit before any work.

Per PDF argument:

1. Open with `PDFDocument` (PDFKit). Before opening, the engine checks the path
   so the error message names the *actual* problem instead of a generic "cannot
   open": **file not found**, **not a file** (e.g. a directory), **not a valid
   PDF**, or — after opening — **PDF has no pages**. Any of these → print the
   specific error to stderr, skip this PDF, continue with the rest. This makes a
   wrapper's failure alert actionable. The wrappers also filter CoreGraphics's
   own `CG_PDF_VERBOSE` chatter out of the message they surface to the user.
2. Create subdir `<PDFname>_pages/` beside the source PDF. **Overwrite cleanly**:
   if it exists, remove and recreate it so stale images never linger.
3. Render every page to `page-001.<ext>`, `page-002.<ext>`, … (zero-padded to
   the page count's width) at **144 DPI**, where `<ext>` is the chosen format.
   - JPG: encoded at **quality 0.85**.
   - PNG: lossless, no quality knob.
4. Build `<PDFname>_montage.<ext>` beside the PDF, **in the same format as the
   pages**:
   - Grid is near-square: `cols = ceil(sqrt(n))`, `rows = ceil(n / cols)`.
   - Each cell holds one page scaled to a uniform thumbnail width, preserving
     aspect ratio, centered, on a white background, with thin gray separators.
   - **Skipped when the PDF has exactly 1 page** (montage would duplicate it).
5. Print one summary line per PDF to stdout:
   `<name>.pdf → N page(s) in <name>_pages/ + montage`.

**Color management.** Every render context and every fill color uses one
explicit sRGB color space. Colors are created with
`CGColor(colorSpace: srgb, components: …)`, *not* the convenience
`CGColor(red:green:blue:alpha:)` initializer — the latter creates colors in a
generic/extended-sRGB space, so filling them into an sRGB context triggers a
color-space conversion that visibly shifts vivid colors (pure red rasterizes as
`255,38,0`). Sharing one color space end-to-end keeps colors exact, which also
makes the primary-color integration test deterministic. The test fixture
generator follows the same rule.

Format handling is a single encode-step branch: pages render to a shared
`CGImage`; only the final `CGImageDestination` UTI differs (`public.jpeg` vs
`public.png`). This keeps jpg/png a one-line difference, not a code fork.

Exit code: `0` if at least one PDF succeeded; non-zero only if **every** input
failed (or on a bad `--format` value).

Case-insensitive extension handling: strip the extension via path APIs
(`deletingPathExtension`), not a lowercase-only string suffix.

### Wrappers

Four wrappers — an Automator workflow and a Shortcut for each of jpg and png.
The format is hard-pinned per wrapper. A user who downloads a release artifact
just double-clicks to install — no repo clone needed. Both wrapper *kinds* carry
the engine, but they carry it differently because their file shapes differ:

- **`Convert PDF to JPG.workflow` / `Convert PDF to PNG.workflow`** — a
  `.workflow` is a *bundle* (a directory). The Run Shell Script action's
  `COMMAND_STRING` is a small dispatcher with its `--format` fixed; the engine
  `pdf-to-images.swift` is copied into the bundle's `Contents/`, and the
  dispatcher locates it as a sibling via `${0:A:h}`.
- **`Convert PDF to JPG.shortcut` / `Convert PDF to PNG.shortcut`** — a
  `.shortcut` is a *single signed file*, so it cannot carry a sibling engine
  file. Instead the Shortcut's Run Shell Script action **embeds the full engine
  source**: at run time it writes `pdf-to-images.swift` to a temp file, runs it,
  and cleans up. This keeps the Shortcut self-contained — download, double-click,
  done — exactly like the bundled `.workflow`.

  **Single source of truth:** the embedded copy is *not* hand-maintained.
  `build-wrappers.sh` generates the Shortcut's shell body by splicing the current
  `pdf-to-images.swift` into the dispatcher at build time, the same way it
  splices the dispatcher into the `.workflow` plist. The engine has exactly one
  authored copy; every wrapper is regenerated from it.

  *Decision:* embed the engine in the Shortcut (vs. a fixed install path).
  *Why:* a fixed path would need a separate engine-install step, breaking the
  one-double-click install goal; embedding keeps the Shortcut self-contained and
  consistent with the `.workflow`.

The dispatcher body is identical across all four except the literal `jpg`/`png`
— generated from one template at build time so the four stay in lockstep.

**No blocking dialogs — runs headless-safe.** A wrapper may be invoked
interactively (a human in Finder) *or* non-interactively (an agent, CI, cron,
another script). It must never open a **modal** dialog: `osascript … display
alert` blocks until a human clicks it, hanging any headless run. Every wrapper
routes user messaging through a single `notify()` helper that (a) always writes
the full text to stderr and (b) posts a *non-blocking* `display notification`
banner — never a `display alert`. Setting `PDF_TO_IMAGES_QUIET=1` suppresses the
notification entirely, so a fully headless caller gets pure stdout/stderr with
zero GUI. The Xcode-CLT install popup is likewise triggered only on interactive
runs. This is a hard requirement: the wrapper layer is automatable.

### Error handling

- Per-PDF failures (not a PDF, unreadable, zero pages) print to stderr, skip,
  and continue. The batch does not abort on one bad file.
- The wrappers surface completion via a **non-blocking** notification (or
  stderr only, under `PDF_TO_IMAGES_QUIET`). Never a modal dialog.
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
   - Run the engine on the fixture **once per format** (`--format jpg` and
     `--format png`).
   - For each format: assert each `page-NNN.<ext>` exists and its center pixel
     matches the expected fill color within tolerance (PNG: exact match, since
     it is lossless; JPG: within tolerance).
   - Assert `<name>_montage.<ext>` exists in the matching format, has the
     expected grid dimensions, and each grid cell's center pixel matches the
     corresponding page's fill.

Integration (not unit) testing is the right call here: the montage geometry and
color fidelity are exactly what can silently regress, and a primary-color
fixture makes every assertion deterministic. Running both formats also pins the
encode-step branch.

### `release.yml` — on push to `main`

`googleapis/release-please-action` with `release-please-config.json` +
`.release-please-manifest.json`:

- `release-type: simple` (no `package.json` in this repo).
- Automated `CHANGELOG.md`, conventional-commit versioning, release PR.
- `extra-files`: `version.txt` so wrappers/README can display a version.
- Authenticated with the `CI_GITHUB_TOKEN` secret (a PAT) so release PRs
  re-trigger CI.

### `cd.yml` — on `workflow_run` of "Release" completing successfully

- Zip each of the four wrappers (`Convert PDF to {JPG,PNG}.{workflow,shortcut}`),
  each bundling the engine script.
- `softprops/action-gh-release` attaches all four zips to the GitHub Release.
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

These three are the complete set the three workflows use — every `uses:` line
is pinned to the commit SHA above, with the tag in a trailing comment.

## Repository changes

- **Un-fork (done):** `jbcom/convert_pdf_to_jpg_on_mac` was deleted and
  recreated as standalone `jbcom/pdf-to-images` (`isFork: false`) so it has its
  own Issues/Actions surface and no upstream PR target. Full local git history
  was preserved and re-pushed.
- **Attribution:** README and LICENSE credit the original author
  (`sanjeed5/convert_pdf_to_jpg_on_mac`).
- **README rewrite:** install via Releases (download the `.workflow` or
  `.shortcut` for the format you want), drop the "single-page only" caveat,
  document the per-page-subdir + montage behavior and jpg/png choice.

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
Convert PDF to PNG.workflow/        (engine bundled inside Contents/)
Convert PDF to JPG.shortcut         (built via shortcuts-playground)
Convert PDF to PNG.shortcut         (built via shortcuts-playground)
tests/
  make-fixture.swift
  run-integration-test.sh
docs/superpowers/specs/2026-05-22-pdf-to-jpg-every-page-design.md
README.md  LICENSE
```
