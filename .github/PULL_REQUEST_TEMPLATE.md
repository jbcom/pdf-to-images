<!--
Use a Conventional Commit style for the PR title (feat:, fix:, docs:, …) —
release-please derives the changelog and version bump from it.
-->

## Summary

<!-- What does this change and why? -->

## Changes

<!-- Bullet the notable changes. -->

-

## Checklist

- [ ] `swiftc -typecheck pdf-to-images.swift` passes
- [ ] `./tests/run-integration-test.sh` passes
- [ ] If the engine changed, I ran `./build-wrappers.sh` and committed the regenerated wrappers
- [ ] No new runtime dependency was added (macOS-bundled frameworks only)
- [ ] Docs updated if behavior changed
