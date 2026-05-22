# Security Policy

## Supported versions

The latest release is supported. Older releases are not patched — upgrade to the
newest release on the [Releases page](https://github.com/jbcom/pdf-to-images/releases/latest).

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

Use GitHub's [private vulnerability reporting](https://github.com/jbcom/pdf-to-images/security/advisories/new)
for this repository. You will get an acknowledgement, and a fix or response once
the report is assessed.

## Scope notes

pdf-to-images runs entirely locally — it reads PDF files you select and writes
images next to them. It makes no network calls and uploads nothing. The most
relevant surface is the shell dispatcher inside each Quick Action: it passes file
paths and user-facing strings to `swift` and `osascript`. Reports about command
construction, argument handling, or the embedded engine are in scope.
