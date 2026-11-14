# Changelog

## 0.1.0 — 2026-11-15

- Add `copy`, `download`, `convert`, `inspect`, `verify`, and `restore` commands.
- Store checksummed metadata manifests beside outputs.
- Preserve filesystem mode, timestamps, extended attributes, and available POSIX ACLs.
- Record HTTP provenance and Last-Modified on downloads.
- Transfer supported embedded tags through optional ExifTool during conversion.
- Add unit tests and macOS/Linux CI.
