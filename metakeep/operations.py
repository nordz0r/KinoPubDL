from __future__ import annotations

import ctypes
import datetime as dt
import email.utils
import errno
import os
import shutil
import subprocess
import sys
import urllib.request
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

from .metadata import _embedded_metadata, capture, restore, sha256_file, verify, write_manifest


def _require_new_destination(destination: Path) -> None:
    sidecar = Path(str(destination) + ".metakeep.json")
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"Refusing to overwrite existing destination: {destination}")
    if sidecar.exists() or sidecar.is_symlink():
        raise FileExistsError(f"Refusing to overwrite existing sidecar: {sidecar}")
    destination.parent.mkdir(parents=True, exist_ok=True)


def _rename_noreplace(source: Path, destination: Path) -> None:
    if os.name == "nt":
        os.rename(source, destination)
        return

    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith("linux"):
        rename = getattr(libc, "renameat2", None)
        if rename is None:
            raise OSError(errno.ENOSYS, "atomic no-replace rename is unavailable", destination)
        rename.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename.restype = ctypes.c_int
        result = rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1)
    elif sys.platform == "darwin":
        rename = getattr(libc, "renamex_np", None)
        if rename is None:
            raise OSError(errno.ENOSYS, "atomic no-replace rename is unavailable", destination)
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(os.fsencode(source), os.fsencode(destination), 0x00000004)
    else:
        raise OSError(errno.ENOSYS, "atomic no-replace rename is unsupported", destination)

    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def _install(temporary: Path, destination: Path, manifest: dict[str, Any]) -> Path:
    sidecar = write_manifest(temporary, manifest)
    destination_sidecar = Path(str(destination) + ".metakeep.json")
    try:
        _rename_noreplace(temporary, destination)
        _rename_noreplace(sidecar, destination_sidecar)
    except Exception:
        _clean(temporary)
        _clean(sidecar)
        raise
    return destination_sidecar


def _temporary_path(destination: Path) -> Path:
    return destination.with_name(f".{destination.name}.metakeep-{uuid.uuid4().hex}")


def _clean(path: Path) -> None:
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        try:
            path.unlink()
        except FileNotFoundError:
            pass


def _restore_source_times(root: Path, manifest: dict[str, Any]) -> None:
    for entry in reversed(manifest.get("entries", [])):
        relative = entry.get("path", ".")
        source = root if relative == "." else root.joinpath(*Path(relative).parts)
        try:
            os.utime(
                source,
                ns=(int(entry["atime_ns"]), int(entry["mtime_ns"])),
                follow_symlinks=False,
            )
        except (OSError, NotImplementedError, KeyError, TypeError):
            pass


def copy_path(source: Path, destination: Path, restore_owner: bool = False) -> dict[str, Any]:
    source = Path(source)
    destination = Path(destination)
    if not source.exists() and not source.is_symlink():
        raise FileNotFoundError(source)
    _require_new_destination(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("Source and destination must be different paths")

    source_manifest = capture(source, "copy", include_embedded=False)
    temporary = _temporary_path(destination)
    try:
        if source.is_symlink():
            os.symlink(os.readlink(source), temporary)
        elif source.is_dir():
            shutil.copytree(source, temporary, copy_function=shutil.copy2, symlinks=True)
        else:
            shutil.copy2(source, temporary, follow_symlinks=False)
        _restore_source_times(source, source_manifest)
        source_manifest["warnings"].extend(
            restore(temporary, source_manifest, restore_owner=restore_owner)
        )
        verification = verify(temporary, source_manifest, check_owner=restore_owner)
        critical_failures = [
            check
            for check in verification["checks"]
            if check.get("reason") or set(check.get("failed", [])) & {"kind", "sha256", "target"}
        ]
        if critical_failures:
            raise RuntimeError(f"Content verification failed before install: {critical_failures}")
        if not verification["ok"]:
            source_manifest["warnings"].append(
                "Some filesystem metadata could not be applied; original values remain in this "
                "sidecar. Run metakeep verify for details."
            )
        sidecar = _install(temporary, destination, source_manifest)
    except Exception:
        _clean(temporary)
        raise
    return {
        "path": str(destination),
        "manifest": str(sidecar),
        "warnings": source_manifest["warnings"],
    }


def _origin(url: str) -> str:
    parts = urlsplit(url)
    if not parts.scheme or not parts.hostname:
        raise ValueError("URL must include a scheme and hostname")
    host = parts.hostname
    if ":" in host:
        host = f"[{host}]"
    if parts.port:
        host = f"{host}:{parts.port}"
    return urlunsplit((parts.scheme, host, "", "", ""))


def download_url(
    url: str,
    destination: Path,
    timeout: float = 60.0,
    record_url: bool = False,
) -> dict[str, Any]:
    destination = Path(destination)
    parts = urlsplit(url)
    if parts.scheme.lower() not in {"http", "https"} or not parts.hostname:
        raise ValueError("Only HTTP and HTTPS download URLs are supported")
    _require_new_destination(destination)
    temporary = _temporary_path(destination)
    request = urllib.request.Request(url, headers={"User-Agent": "MetaKeep/0.1.0"})
    try:
        with (
            urllib.request.urlopen(request, timeout=timeout) as response,
            temporary.open("wb") as output,
        ):
            shutil.copyfileobj(response, output, length=1024 * 1024)
            headers = {
                key.lower(): value
                for key, value in response.headers.items()
                if key.lower()
                in {
                    "content-type",
                    "content-length",
                    "content-disposition",
                    "last-modified",
                    "etag",
                    "cache-control",
                }
            }
            final_url = response.geturl()
            status = getattr(response, "status", 200)
        if status < 200 or status >= 300:
            raise RuntimeError(f"Download returned HTTP status {status}")
        last_modified = headers.get("last-modified")
        if last_modified:
            try:
                parsed = email.utils.parsedate_to_datetime(last_modified)
                if parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=dt.timezone.utc)
                modified_ns = int(parsed.timestamp() * 1_000_000_000)
                current_atime_ns = temporary.stat().st_atime_ns
                os.utime(temporary, ns=(current_atime_ns, modified_ns))
            except (TypeError, ValueError, OSError, OverflowError):
                pass

        manifest = capture(temporary, "download")
        manifest["source"] = {"kind": "http", "origin": _origin(final_url)}
        if record_url:
            manifest["source"]["url"] = final_url
        manifest["http"] = {"status": status, "headers": headers}
        manifest["downloaded_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        manifest["sha256"] = sha256_file(temporary)
        sidecar = _install(temporary, destination, manifest)
    except Exception:
        _clean(temporary)
        raise
    return {
        "path": str(destination),
        "manifest": str(sidecar),
        "sha256": manifest["sha256"],
        "warnings": manifest["warnings"],
    }


def _replace_placeholders(command: list[str], source: Path, destination: Path) -> list[str]:
    if not command:
        raise ValueError("Provide a converter command after --")
    joined = "\0".join(command)
    if "{input}" not in joined or "{output}" not in joined:
        raise ValueError("Converter arguments must include both {input} and {output} placeholders")
    return [
        part.replace("{input}", str(source)).replace("{output}", str(destination))
        for part in command
    ]


def convert_file(
    source: Path,
    destination: Path,
    command: list[str],
    restore_owner: bool = False,
    require_embedded: bool = False,
) -> dict[str, Any]:
    source = Path(source)
    destination = Path(destination)
    if not source.is_file():
        raise ValueError("Conversion currently accepts one regular file as input")
    _require_new_destination(destination)
    source_manifest = capture(source, "convert-source")
    source_entry = source_manifest["entries"][0]
    embedded = source_entry.get("embedded")
    exiftool_available = shutil.which("exiftool") is not None
    if require_embedded and not exiftool_available:
        raise RuntimeError("--require-embedded needs ExifTool to inspect and transfer metadata")
    inspection_errors = [
        warning
        for warning in source_manifest["warnings"]
        if warning.startswith(
            ("ExifTool could not read embedded metadata", "Could not parse ExifTool output")
        )
    ]
    if require_embedded and inspection_errors:
        raise RuntimeError(
            "ExifTool could not inspect source metadata: " + "; ".join(inspection_errors)
        )

    temporary = destination.with_name(
        f".{destination.stem}.metakeep-{uuid.uuid4().hex}{destination.suffix}"
    )
    argv = _replace_placeholders(command, source, temporary)
    try:
        subprocess.run(argv, check=True)
        _restore_source_times(source, source_manifest)
        if not temporary.is_file() or temporary.is_symlink():
            raise RuntimeError("Converter completed without creating the requested output file")

        warnings: list[str] = list(source_manifest["warnings"])
        if embedded and exiftool_available:
            transfer = subprocess.run(
                [
                    "exiftool",
                    "-TagsFromFile",
                    str(source),
                    "-all:all",
                    "-overwrite_original",
                    str(temporary),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if transfer.returncode:
                raise RuntimeError(
                    f"ExifTool could not transfer embedded metadata: {transfer.stderr.strip()}"
                )
            output_tags, tag_warnings = _embedded_metadata(temporary)
            warnings.extend(tag_warnings)
            volatile_tails = {
                "ImageWidth",
                "ImageHeight",
                "ExifImageWidth",
                "ExifImageHeight",
                "FileModifyDate",
                "FileAccessDate",
                "FileInodeChangeDate",
                "FileName",
                "Directory",
                "FileSize",
                "FileType",
                "FileTypeExtension",
                "MIMEType",
                "FilePermissions",
                "FileCreateDate",
            }
            source_tags = {
                key: value
                for key, value in embedded.items()
                if not key.startswith(("File:", "Composite:", "ExifTool:"))
                and key.rsplit(":", 1)[-1] not in volatile_tails
            }
            gaps = sorted(
                key
                for key, value in source_tags.items()
                if not output_tags or output_tags.get(key) != value
            )
            if gaps:
                message = "Some embedded tags could not be verified after conversion: " + ", ".join(
                    gaps
                )
                if require_embedded:
                    raise RuntimeError(message)
                warnings.append(message)
        elif not exiftool_available:
            message = (
                "Embedded metadata could not be inspected or transferred; install ExifTool. "
                "Source filesystem metadata is retained in the sidecar."
            )
            if require_embedded:
                raise RuntimeError(message)
            warnings.append(message)

        apply_manifest = {"entries": [source_entry]}
        warnings.extend(restore(temporary, apply_manifest, restore_owner=restore_owner))
        output_manifest = capture(temporary, "convert-output")
        output_manifest["operation"] = "convert"
        output_manifest["source"] = {"name": source.name}
        output_manifest["source_metadata"] = source_manifest
        output_manifest["converter"] = argv[0]
        output_manifest["warnings"] = sorted(set(output_manifest["warnings"] + warnings))
        verification = verify(temporary, output_manifest)
        critical_failures = [
            check
            for check in verification["checks"]
            if check.get("reason") or set(check.get("failed", [])) & {"kind", "sha256", "target"}
        ]
        if critical_failures:
            raise RuntimeError(f"Converted output content verification failed: {critical_failures}")
        if not verification["ok"]:
            output_manifest["warnings"].append(
                "Some filesystem metadata could not be applied; source values remain in "
                "source_metadata."
            )
        sidecar = _install(temporary, destination, output_manifest)
    except Exception:
        _clean(temporary)
        raise
    return {
        "path": str(destination),
        "manifest": str(sidecar),
        "warnings": output_manifest["warnings"],
    }


def inspect_path(path: Path) -> dict[str, Any]:
    manifest = capture(Path(path), "inspect")
    for entry in manifest["entries"]:
        if "xattrs" in entry:
            entry["xattrs"] = sorted(entry["xattrs"].keys())
        if "embedded" in entry:
            entry["embedded"] = sorted(entry["embedded"].keys())
    return manifest
