from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from metakeep.metadata import capture, load_manifest, restore, verify
from metakeep.operations import (
    _install,
    _origin,
    _rename_noreplace,
    convert_file,
    copy_path,
    download_url,
)


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = b"downloaded payload\n"
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Last-Modified", "Wed, 21 Oct 2015 07:28:00 GMT")
        self.send_header("ETag", '"metakeep-test"')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


class MetaKeepTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_copy_preserves_content_mode_mtime_and_manifest(self) -> None:
        source = self.root / "source file.bin"
        destination = self.root / "copies" / "copy file.bin"
        source.write_bytes(b"metadata matters\n")
        source.chmod(0o640)
        expected_mtime = 1_700_000_000_000_000_000
        os.utime(source, ns=(expected_mtime, expected_mtime))
        if hasattr(os, "setxattr"):
            try:
                os.setxattr(source, "user.metakeep-test", b"attribute")
            except OSError:
                pass

        result = copy_path(source, destination)
        self.assertEqual(destination.read_bytes(), source.read_bytes())
        self.assertEqual(destination.stat().st_mode & 0o777, 0o640)
        self.assertEqual(destination.stat().st_mtime_ns, expected_mtime)
        manifest = load_manifest(destination)
        self.assertEqual(manifest["operation"], "copy")
        self.assertTrue(verify(destination, manifest)["ok"])
        self.assertTrue(Path(result["manifest"]).is_file())

    def test_copy_refuses_overwrite(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_text("source")
        destination.write_text("keep me")
        with self.assertRaises(FileExistsError):
            copy_path(source, destination)
        self.assertEqual(destination.read_text(), "keep me")

    def test_copy_refuses_to_overwrite_existing_sidecar(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_text("source")
        Path(str(destination) + ".metakeep.json").write_text("keep sidecar")
        with self.assertRaises(FileExistsError):
            copy_path(source, destination)
        self.assertFalse(destination.exists())

    def test_download_rejects_non_http_schemes(self) -> None:
        destination = self.root / "download.bin"
        with self.assertRaises(ValueError):
            download_url("file:///etc/hosts", destination)
        self.assertFalse(destination.exists())

    def test_ipv6_download_origin_keeps_brackets(self) -> None:
        self.assertEqual(_origin("https://[2001:db8::1]:8443/file"), "https://[2001:db8::1]:8443")

    def test_atomic_install_never_replaces_existing_destination(self) -> None:
        source = self.root / "staged"
        destination = self.root / "destination"
        source.write_text("staged data")
        destination.write_text("concurrent data")
        with self.assertRaises(FileExistsError):
            _rename_noreplace(source, destination)
        self.assertEqual(source.read_text(), "staged data")
        self.assertEqual(destination.read_text(), "concurrent data")

    def test_install_cleanup_does_not_delete_destination_created_during_race(self) -> None:
        temporary = self.root / "staged-output"
        destination = self.root / "destination"
        temporary.write_text("staged data")

        def create_concurrent_destination(_source: Path, path: Path) -> None:
            path.write_text("concurrent data")
            raise FileExistsError(path)

        with patch(
            "metakeep.operations._rename_noreplace", side_effect=create_concurrent_destination
        ):
            with self.assertRaises(FileExistsError):
                _install(temporary, destination, {"schema": "metakeep/v1", "entries": []})
        self.assertEqual(destination.read_text(), "concurrent data")

    @unittest.skipIf(os.name == "nt", "Backslashes are path separators on Windows")
    def test_copy_accepts_windows_like_posix_filename(self) -> None:
        source = self.root / "tree"
        destination = self.root / "tree-copy"
        source.mkdir()
        name = "C:notes\\raw.bin"
        (source / name).write_bytes(b"valid POSIX filename")
        copy_path(source, destination)
        self.assertEqual((destination / name).read_bytes(), b"valid POSIX filename")

    @patch(
        "metakeep.metadata._embedded_metadata",
        return_value=(
            None,
            ["ExifTool could not read embedded metadata for source.bin: unsupported"],
        ),
    )
    @patch(
        "metakeep.operations.shutil.which",
        side_effect=lambda name: "/usr/bin/exiftool" if name == "exiftool" else None,
    )
    def test_require_embedded_fails_when_exiftool_cannot_read_source(
        self, _which: object, _metadata: object
    ) -> None:
        source = self.root / "source.bin"
        destination = self.root / "output.bin"
        source.write_bytes(b"source")
        with self.assertRaisesRegex(RuntimeError, "could not inspect source metadata"):
            convert_file(
                source,
                destination,
                [sys.executable, "-c", "pass", "{input}", "{output}"],
                require_embedded=True,
            )
        self.assertFalse(destination.exists())

    def test_restore_rejects_manifest_paths_outside_root(self) -> None:
        manifest = {"entries": [{"path": "../outside", "kind": "file"}]}
        with self.assertRaises(ValueError):
            restore(self.root, manifest)

    @patch("metakeep.operations.shutil.which", return_value=None)
    def test_require_embedded_fails_without_exiftool(self, _which: object) -> None:
        source = self.root / "source.txt"
        destination = self.root / "output.txt"
        source.write_text("source")
        with self.assertRaisesRegex(RuntimeError, "ExifTool"):
            convert_file(
                source,
                destination,
                [sys.executable, "-c", "pass", "{input}", "{output}"],
                require_embedded=True,
            )
        self.assertFalse(destination.exists())

    def test_download_records_http_headers_hash_and_last_modified(self) -> None:
        server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            destination = self.root / "download.bin"
            url = f"http://127.0.0.1:{server.server_port}/asset?token=do-not-record"
            result = download_url(url, destination)
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

        self.assertEqual(destination.read_bytes(), b"downloaded payload\n")
        manifest = json.loads(Path(result["manifest"]).read_text(encoding="utf-8"))
        self.assertEqual(manifest["operation"], "download")
        self.assertEqual(manifest["source"]["origin"], f"http://127.0.0.1:{server.server_port}")
        self.assertNotIn("url", manifest["source"])
        self.assertNotIn("do-not-record", json.dumps(manifest))
        self.assertEqual(manifest["http"]["headers"]["etag"], '"metakeep-test"')
        self.assertEqual(destination.stat().st_mtime_ns, 1_445_412_480_000_000_000)
        self.assertTrue(verify(destination, manifest)["ok"])

    def test_convert_carries_filesystem_metadata_without_shell(self) -> None:
        source = self.root / "source.txt"
        destination = self.root / "converted.txt"
        source.write_text("small payload\n")
        source.chmod(0o640)
        expected_mtime = 1_650_000_000_000_000_000
        os.utime(source, ns=(expected_mtime, expected_mtime))
        converter = [
            sys.executable,
            "-c",
            (
                "import pathlib,sys; "
                "pathlib.Path(sys.argv[2]).write_bytes(pathlib.Path(sys.argv[1]).read_bytes().upper())"
            ),
            "{input}",
            "{output}",
        ]

        result = convert_file(source, destination, converter)
        self.assertEqual(destination.read_text(), "SMALL PAYLOAD\n")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o640)
        self.assertEqual(destination.stat().st_mtime_ns, expected_mtime)
        manifest = load_manifest(destination)
        self.assertEqual(manifest["operation"], "convert")
        self.assertEqual(
            manifest["source_metadata"]["entries"][0]["sha256"],
            hashlib.sha256(source.read_bytes()).hexdigest(),
        )
        self.assertTrue(verify(destination, manifest)["ok"])
        self.assertTrue(Path(result["manifest"]).is_file())

    def test_convert_requires_placeholders_and_preserves_old_destination(self) -> None:
        source = self.root / "source.txt"
        destination = self.root / "existing.txt"
        source.write_text("source")
        destination.write_text("do not overwrite")
        with self.assertRaises(FileExistsError):
            convert_file(source, destination, [sys.executable, "-c", "pass"])
        self.assertEqual(destination.read_text(), "do not overwrite")
        destination.unlink()
        with self.assertRaisesRegex(ValueError, "placeholders"):
            convert_file(source, destination, [sys.executable, "-c", "pass"])
        self.assertFalse(destination.exists())

    def test_manifest_detects_content_change(self) -> None:
        source = self.root / "source.bin"
        destination = self.root / "copy.bin"
        source.write_bytes(b"original")
        copy_path(source, destination)
        destination.write_bytes(b"changed")
        result = verify(destination, load_manifest(destination))
        self.assertFalse(result["ok"])
        self.assertIn("sha256", result["checks"][0]["failed"])

    def test_capture_restores_directory_access_time_after_walking(self) -> None:
        source = self.root / "tree"
        source.mkdir()
        (source / "asset.bin").write_bytes(b"nested")
        timestamp = 1_600_000_000_000_000_000
        os.utime(source, ns=(timestamp, timestamp))
        capture(source, "inspect", include_embedded=False)
        self.assertEqual(source.stat().st_atime_ns, timestamp)

    def test_directory_copy_keeps_nested_file_and_relative_manifest(self) -> None:
        source = self.root / "tree"
        destination = self.root / "tree-copy"
        (source / "nested").mkdir(parents=True)
        (source / "nested" / "asset.bin").write_bytes(b"nested")
        copy_path(source, destination)
        manifest = load_manifest(destination)
        self.assertIn("nested/asset.bin", {entry["path"] for entry in manifest["entries"]})
        self.assertTrue(verify(destination, manifest)["ok"])


if __name__ == "__main__":
    unittest.main()
