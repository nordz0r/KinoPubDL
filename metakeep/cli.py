from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

from .metadata import load_manifest, restore, verify
from .operations import convert_file, copy_path, download_url, inspect_path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="metakeep",
        description="Preserve and verify filesystem and embedded metadata across file workflows.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  metakeep copy original.tif archive/original.tif\n"
            "  metakeep download https://example.org/image.tif image.tif\n"
            "  metakeep convert input.tif output.jpg -- magick {input} {output}\n"
            "  metakeep verify output.jpg"
        ),
    )
    parser.add_argument("--version", action="version", version="%(prog)s 0.1.0")
    commands = parser.add_subparsers(dest="action", required=True)

    copy_cmd = commands.add_parser("copy", help="Copy a file or directory and preserve metadata")
    copy_cmd.add_argument("source", type=Path)
    copy_cmd.add_argument("destination", type=Path)
    copy_cmd.add_argument(
        "--owner",
        action="store_true",
        help="Try to restore numeric UID/GID (usually requires root)",
    )

    download_cmd = commands.add_parser(
        "download", help="Download a file and record HTTP provenance"
    )
    download_cmd.add_argument("url")
    download_cmd.add_argument("destination", type=Path)
    download_cmd.add_argument("--timeout", type=float, default=60.0)
    download_cmd.add_argument(
        "--record-url",
        action="store_true",
        help="Store the full URL, including path/query, in the sidecar",
    )

    convert_cmd = commands.add_parser("convert", help="Convert a file and carry metadata forward")
    convert_cmd.add_argument("source", type=Path)
    convert_cmd.add_argument("destination", type=Path)
    convert_cmd.add_argument(
        "--owner",
        action="store_true",
        help="Try to restore numeric UID/GID (usually requires root)",
    )
    convert_cmd.add_argument(
        "--require-embedded",
        action="store_true",
        help="Fail unless ExifTool can transfer detected embedded metadata",
    )
    convert_cmd.add_argument(
        "converter",
        nargs=argparse.REMAINDER,
        help="Converter argv after --; use {input} and {output}",
    )

    inspect_cmd = commands.add_parser(
        "inspect", help="Show metadata summary for a file or directory"
    )
    inspect_cmd.add_argument("path", type=Path)

    verify_cmd = commands.add_parser(
        "verify", help="Verify content and metadata against its sidecar"
    )
    verify_cmd.add_argument("path", type=Path)
    verify_cmd.add_argument("--manifest", type=Path)
    verify_cmd.add_argument("--owner", action="store_true", help="Also compare UID/GID")

    restore_cmd = commands.add_parser(
        "restore", help="Restore saved filesystem metadata from a sidecar"
    )
    restore_cmd.add_argument("path", type=Path)
    restore_cmd.add_argument("--manifest", type=Path)
    restore_cmd.add_argument(
        "--owner",
        action="store_true",
        help="Try to restore numeric UID/GID (usually requires root)",
    )
    return parser


def _json(value: object) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def _manifest_path(args: argparse.Namespace) -> Path:
    if args.manifest:
        return args.manifest
    return args.path


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.action == "copy":
            result = copy_path(args.source, args.destination, restore_owner=args.owner)
            _json(result)
            return 0
        if args.action == "download":
            result = download_url(
                args.url, args.destination, timeout=args.timeout, record_url=args.record_url
            )
            _json(result)
            return 0
        if args.action == "convert":
            command = list(args.converter)
            if command and command[0] == "--":
                command = command[1:]
            result = convert_file(
                args.source,
                args.destination,
                command,
                restore_owner=args.owner,
                require_embedded=args.require_embedded,
            )
            _json(result)
            return 0
        if args.action == "inspect":
            _json(inspect_path(args.path))
            return 0
        if args.action == "verify":
            manifest = load_manifest(args.manifest or args.path)
            result = verify(args.path, manifest, check_owner=args.owner)
            _json(result)
            return 0 if result["ok"] else 1
        if args.action == "restore":
            manifest = load_manifest(args.manifest or args.path)
            warnings = restore(args.path, manifest, restore_owner=args.owner)
            _json({"path": str(args.path), "restored": True, "warnings": warnings})
            return 0
    except (OSError, ValueError, RuntimeError, TypeError, subprocess.SubprocessError) as exc:
        print(f"metakeep: {exc}", file=sys.stderr)
        return 2
    return 2
