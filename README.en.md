<p align="center"><strong>English</strong> · <a href="README.md">Русский</a></p>

<p align="center"><img src="assets/hero.svg" alt="MetaKeep — Metadata, kept." width="100%"></p>

<p align="center">
  <a href="https://github.com/nordz0r/metadata-preserver/actions/workflows/ci.yml"><img src="https://github.com/nordz0r/metadata-preserver/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/nordz0r/metadata-preserver/releases"><img src="https://img.shields.io/github/v/release/nordz0r/metadata-preserver?display_name=tag" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-65e6d0.svg" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/python-3.10%2B-75a7ff.svg" alt="Python 3.10+">
</p>

<p align="center"><b>Keep the metadata, not just the bytes.</b><br>Copy, download, and convert with a verifiable sidecar manifest.</p>

**MetaKeep** is a small, cross-platform CLI for moving files through common workflows without silently discarding available metadata. It preserves filesystem attributes, records provenance in a JSON sidecar, verifies the result, and clearly reports what the OS or converter could not carry over.

> MetaKeep does not promise the impossible: an HTTP server cannot provide the original ACL or Finder tags, and a target format may not support every embedded tag. Values that cannot be transferred remain in the sidecar, and limitations are surfaced explicitly.

## Contents

[Features](#features) · [Quick start](#quick-start) · [Commands](#commands) · [Metadata coverage](#metadata-coverage) · [Conversion](#conversion) · [Security](#security) · [Development](#development)

## Features

- 📦 **Metadata-aware copy** — files and directories, staged copy, metadata restoration, and verification before installation.
- 🌐 **Download provenance** — selected HTTP headers (`ETag`, `Last-Modified`, etc.), SHA-256, and source origin alongside the file.
- 🔄 **Converter wrapper** — runs the selected converter without a shell and transfers supported metadata.
- 🧾 **Portable sidecar** — `*.metakeep.json` stores values that cannot safely or correctly fit in the target format.
- ✅ **Verify / restore** — compare content and attributes; restore filesystem metadata from a trusted manifest.
- 🔒 **No overwrite by default** — existing destinations remain untouched; resolve conflicts explicitly first.
- 🪶 **No required dependencies** — Python standard library; ExifTool and POSIX ACL tools are optional.

## Quick start

Requires Python 3.10 or newer.

```bash
python -m pip install .
```

Copy a file and keep its manifest:

```bash
metakeep copy "Original Photo.tif" "archive/Original Photo.tif"
metakeep verify "archive/Original Photo.tif"
```

Download a file and record HTTP provenance:

```bash
metakeep download https://example.org/photo.jpg photo.jpg
```

Convert a file while carrying supported filesystem and embedded metadata:

```bash
metakeep convert photo.tif photo.jpg -- magick {input} {output}
```

Install [ExifTool](https://exiftool.org/) to transfer supported EXIF/IPTC/XMP and other embedded tags. Strict mode fails when ExifTool is unavailable:

```bash
metakeep convert --require-embedded photo.tif photo.jpg -- magick {input} {output}
```

> Every output gets a sibling sidecar, for example `photo.jpg.metakeep.json`. Keep it with the file when future verification or restoration matters.

## Commands

| Command | Purpose |
|:--|:--|
| `metakeep copy SRC DEST` | Copy a file or directory, preserve available filesystem metadata, and verify content. |
| `metakeep download URL DEST` | Download an HTTP(S) file, record provenance, and set mtime from `Last-Modified` when provided. |
| `metakeep convert SRC DEST -- COMMAND {input} {output}` | Run a converter without a shell, then transfer filesystem metadata and supported embedded tags with ExifTool. |
| `metakeep inspect PATH` | Show a metadata summary without printing binary xattr values. |
| `metakeep verify PATH` | Verify content and metadata against the sibling sidecar. |
| `metakeep restore PATH` | Restore filesystem metadata from a sidecar. Use trusted manifests only. |

Use `--manifest PATH` with `verify` or `restore` when the sidecar is stored elsewhere. `--owner` also attempts to restore numeric UID/GID and usually requires root:

```bash
metakeep verify archive/file.bin --owner
metakeep restore archive/file.bin --manifest backup/file.bin.metakeep.json --owner
```

URL paths and parameters are omitted by default; the sidecar stores only the origin. `--record-url` stores the complete URL, including query parameters. Do not use it for URLs containing tokens or credentials.

## Metadata coverage

| Metadata | Copy | Download | Convert |
|:--|:--:|:--:|:--:|
| Content SHA-256 | ✅ verified | ✅ recorded | ✅ recorded |
| POSIX mode and access/modified times | ✅ transferred | ✅ mtime from HTTP, when available | ✅ copied from source |
| Extended attributes / macOS resource forks | ✅ when supported by OS | ✅ attributes on local output | ✅ transferred and stored in sidecar |
| POSIX ACL | ✅ with `getfacl`/`setfacl` | — | ✅ when ACL tools are available |
| UID/GID | 🧾 recorded; apply with `--owner` | 🧾 recorded | 🧾 recorded; apply with `--owner` |
| EXIF, IPTC, XMP, other embedded tags | bytes unchanged | unavailable from HTTP | ExifTool transfer when formats support it |
| Selected HTTP headers and origin | — | ✅ recorded | — |
| Creation/birth time | 🧾 recorded when exposed by OS | unavailable over HTTP | 🧾 source retained in sidecar |

`copy` never overwrites a destination. `convert` accepts one regular file as input; use `copy` for directories.

## Conversion

MetaKeep does not guess converter-specific syntax. Pass its argv after `--` and use both required placeholders:

```bash
metakeep convert input.png output.webp -- magick {input} -quality 88 {output}
```

The command runs directly, without `sh -c` or `shell=True`. When ExifTool is installed and detects embedded metadata, MetaKeep invokes `-TagsFromFile ... -all:all`. Without ExifTool, source metadata remains in `source_metadata` in the sidecar and a warning prevents the missing transfer from being mistaken for success. `--require-embedded` requires ExifTool. Support depends on the source and target formats: values the target format cannot represent remain available in the sidecar, but will not appear inside the converted file.

After conversion, MetaKeep transfers mode, timestamps, xattrs, and available ACLs, then verifies the output. Restoring birth time, ownership without `--owner`, and incompatible ACLs may require manual review.

## Security

- Sidecars contain xattr values, numeric owner, timestamps, SHA-256, and may include embedded tags such as GPS coordinates. Protect them like the source file.
- Full URLs are not stored unless `--record-url` is set; query strings may contain tokens.
- `restore` applies sidecar data to the filesystem. Never restore from an untrusted manifest.
- Converters run with the current user's permissions. Use trusted programs and do not pass untrusted commands.
- See [SECURITY.md](SECURITY.md) and the [MIT License](LICENSE).

## Development

```bash
python -m unittest discover -s tests -v
python -m metakeep --help
```

There are no runtime dependencies. CI tests Python 3.10–3.13 on Linux and macOS. See [CHANGELOG.md](CHANGELOG.md) for changes.
