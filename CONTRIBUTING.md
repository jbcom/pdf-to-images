# Contributing to pdf-to-images

Thanks for your interest in improving pdf-to-images. This is a small, focused
project — contributions that keep it that way are very welcome.

## Ground rules

- **Zero runtime dependencies.** The engine uses only frameworks bundled with
  macOS (PDFKit, CoreGraphics, ImageIO). No Homebrew, no SwiftPM packages. The
  only acceptable install prompt for an end user is the macOS "install developer
  tools" popup. A change that adds a dependency will not be merged.
- **One engine, generated wrappers.** `pdf-to-images.swift` is the single source
  of truth. The four Quick Action wrappers are generated from it by
  `build-wrappers.sh` — never hand-edit a `.workflow`, a `wrappers/shortcut-*.sh`,
  or a bundled engine copy. Edit the engine or the templates, then rebuild.
- **Headless-safe.** Wrappers must never open a blocking modal dialog — they run
  under agents and CI too. Use non-blocking notifications; honor
  `PDF_TO_IMAGES_QUIET`.

## Development setup

You need macOS with the Xcode Command Line Tools (`xcode-select --install`).
Nothing else.

```sh
# Run the engine directly
swift pdf-to-images.swift --format png path/to/file.pdf

# Regenerate the four wrappers from the engine + templates
./build-wrappers.sh

# Run the full integration test (engine + wrapper headless-safety)
./tests/run-integration-test.sh
```

## Making a change

1. Branch from `main`.
2. Make the change. If you touch the engine, run `./build-wrappers.sh` so the
   generated wrappers stay in sync, and commit the regenerated files.
3. `swiftc -typecheck pdf-to-images.swift` and `./tests/run-integration-test.sh`
   must both pass.
4. Use [Conventional Commits](https://www.conventionalcommits.org/) for commit
   messages (`feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `ci:`, `build:`,
   `chore:`) — release-please derives the changelog and version bump from them.
5. Open a pull request. CI runs the typecheck and integration test on macOS.

## Reporting bugs

Open an issue with the macOS version, the command or Quick Action used, and what
happened versus what you expected. A sample PDF that reproduces the problem is
ideal.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
