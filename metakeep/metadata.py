from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any

SCHEMA = "metakeep/v1"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except (OSError, TypeError):
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    with os.fdopen(fd, "rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _xattrs(path: Path) -> tuple[dict[str, str] | None, list[str]]:
    if not hasattr(os, "listxattr"):
        return None, ["Extended attributes are not supported by this Python platform."]
    try:
        names = os.listxattr(path, follow_symlinks=False)
    except (OSError, TypeError) as exc:
        return None, [f"Could not read extended attributes for {path.name}: {exc}"]

    values: dict[str, str] = {}
    warnings: list[str] = []
    for name in sorted(names):
        try:
            value = os.getxattr(path, name, follow_symlinks=False)
            values[name] = base64.b64encode(value).decode("ascii")
        except (OSError, TypeError) as exc:
            warnings.append(f"Could not read xattr {name!r} on {path.name}: {exc}")
    return values, warnings


def _acl(path: Path, is_symlink: bool) -> tuple[str | None, list[str]]:
    if is_symlink:
        return None, []
    getfacl = shutil.which("getfacl")
    if not getfacl:
        return None, []
    result = subprocess.run(
        [getfacl, "-cp", str(path)], capture_output=True, text=True, check=False
    )
    if result.returncode:
        return None, [f"Could not read ACL for {path.name}: {result.stderr.strip()}"]
    acl = result.stdout.strip()
    return (acl or None), []


def _embedded_metadata(path: Path) -> tuple[dict[str, Any] | None, list[str]]:
    if not shutil.which("exiftool"):
        return None, []
    result = subprocess.run(
        ["exiftool", "-json", "-G1", "-a", "-s", "-all:all", str(path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        return None, [
            f"ExifTool could not read embedded metadata for {path.name}: {result.stderr.strip()}"
        ]
    try:
        payload = json.loads(result.stdout)
        tags = payload[0] if payload else {}
    except (json.JSONDecodeError, IndexError, TypeError) as exc:
        return None, [f"Could not parse ExifTool output for {path.name}: {exc}"]
    tags.pop("SourceFile", None)
    return (tags or None), []


def _kind(mode: int) -> str:
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISLNK(mode):
        return "symlink"
    return "other"


def _entry(
    path: Path, relative: str, st: os.stat_result, include_embedded: bool
) -> tuple[dict[str, Any], list[str]]:
    kind = _kind(st.st_mode)
    entry: dict[str, Any] = {
        "path": relative,
        "kind": kind,
        "mode": stat.S_IMODE(st.st_mode),
        "uid": st.st_uid,
        "gid": st.st_gid,
        "atime_ns": st.st_atime_ns,
        "mtime_ns": st.st_mtime_ns,
        "size": st.st_size,
    }
    if hasattr(st, "st_birthtime"):
        entry["birthtime_ns"] = int(st.st_birthtime * 1_000_000_000)
    warnings: list[str] = []
    if kind == "file":
        entry["sha256"] = sha256_file(path)
    elif kind == "symlink":
        entry["target"] = os.readlink(path)

    attrs, attr_warnings = _xattrs(path)
    if attrs is not None:
        entry["xattrs"] = attrs
    warnings.extend(attr_warnings)

    acl, acl_warnings = _acl(path, kind == "symlink")
    if acl is not None:
        entry["acl"] = acl
    warnings.extend(acl_warnings)

    if include_embedded and kind == "file":
        embedded, embedded_warnings = _embedded_metadata(path)
        if embedded is not None:
            entry["embedded"] = embedded
        warnings.extend(embedded_warnings)
    return entry, warnings


def _walk(root: Path) -> list[tuple[Path, str, os.stat_result]]:
    root_stat = root.lstat()
    if not stat.S_ISDIR(root_stat.st_mode):
        return [(root, ".", root_stat)]

    items: list[tuple[Path, str, os.stat_result]] = []
    stack = [(root, ".", root_stat)]
    while stack:
        current, relative, current_stat = stack.pop()
        items.append((current, relative, current_stat))
        if not stat.S_ISDIR(current_stat.st_mode):
            continue
        with os.scandir(current) as iterator:
            children = sorted(iterator, key=lambda item: item.name, reverse=True)
        for child in children:
            child_path = Path(child.path)
            child_relative = child.name if relative == "." else f"{relative}/{child.name}"
            child_stat = child.stat(follow_symlinks=False)
            stack.append((child_path, child_relative, child_stat))
    return items


def capture(path: Path, operation: str, include_embedded: bool = True) -> dict[str, Any]:
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        raise FileNotFoundError(path)
    entries: list[dict[str, Any]] = []
    warnings: list[str] = []
    captured: list[tuple[Path, int, int]] = []
    if os.name == "posix" and not shutil.which("getfacl"):
        warnings.append(
            "POSIX ACLs could not be inspected; install getfacl/setfacl to preserve them."
        )
    for item, relative, item_stat in _walk(path):
        entry, entry_warnings = _entry(item, relative, item_stat, include_embedded)
        entries.append(entry)
        warnings.extend(entry_warnings)
        captured.append((item, entry["atime_ns"], entry["mtime_ns"]))

    # Hashing can update access times. Restore the source times after inspection.
    for item, atime_ns, mtime_ns in reversed(captured):
        try:
            os.utime(item, ns=(atime_ns, mtime_ns), follow_symlinks=False)
        except (OSError, NotImplementedError):
            pass

    return {
        "schema": SCHEMA,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "operation": operation,
        "source": {"name": path.name or str(path)},
        "entries": entries,
        "warnings": sorted(set(warnings)),
    }


def _entry_target(root: Path, relative: str) -> Path:
    if not isinstance(relative, str):
        raise ValueError("Manifest entry path must be text")
    if relative == ".":
        return root
    posix = PurePosixPath(relative)
    windows = PureWindowsPath(relative)
    unsafe = posix.is_absolute() or any(part in {"", ".", ".."} for part in posix.parts)
    if os.name == "nt":
        unsafe = unsafe or windows.is_absolute() or bool(windows.drive) or "\\" in relative
        unsafe = unsafe or any(part in {".", ".."} for part in windows.parts)
    if unsafe:
        raise ValueError(f"Unsafe path in metadata manifest: {relative!r}")
    target = root.joinpath(*posix.parts)
    root_real = root.resolve()
    parent_real = target.parent.resolve()
    try:
        if os.path.commonpath((str(root_real), str(parent_real))) != str(root_real):
            raise ValueError(f"Manifest path escapes its root: {relative!r}")
    except ValueError as exc:
        raise ValueError(f"Manifest path escapes its root: {relative!r}") from exc
    return target


def apply_entry(path: Path, entry: dict[str, Any], restore_owner: bool = False) -> list[str]:
    warnings: list[str] = []
    if entry.get("kind") == "symlink":
        if entry.get("target") != os.readlink(path):
            warnings.append(f"Symlink target differs for {path}")
    elif restore_owner and hasattr(os, "chown"):
        try:
            os.chown(path, int(entry["uid"]), int(entry["gid"]), follow_symlinks=False)
        except (OSError, NotImplementedError, KeyError) as exc:
            warnings.append(f"Could not restore owner for {path.name}: {exc}")

    if entry.get("kind") != "symlink":
        try:
            os.chmod(path, int(entry["mode"]), follow_symlinks=False)
        except (OSError, NotImplementedError, KeyError) as exc:
            warnings.append(f"Could not restore mode for {path.name}: {exc}")

    expected_attrs = entry.get("xattrs")
    if expected_attrs is not None:
        if not hasattr(os, "setxattr"):
            warnings.append(f"Extended attributes cannot be restored on this platform: {path.name}")
        else:
            for name, encoded in expected_attrs.items():
                try:
                    os.setxattr(
                        path,
                        name,
                        base64.b64decode(encoded, validate=True),
                        follow_symlinks=False,
                    )
                except (OSError, ValueError, TypeError) as exc:
                    warnings.append(f"Could not restore xattr {name!r} on {path.name}: {exc}")

    acl = entry.get("acl")
    if acl:
        setfacl = shutil.which("setfacl")
        if not setfacl:
            warnings.append(f"Saved ACL for {path.name}, but setfacl is unavailable.")
        else:
            result = subprocess.run(
                [setfacl, "--set-file=-", "--", str(path)],
                input=acl + "\n",
                capture_output=True,
                text=True,
                check=False,
            )
            if result.returncode:
                warnings.append(f"Could not restore ACL for {path.name}: {result.stderr.strip()}")

    try:
        os.utime(
            path,
            ns=(int(entry["atime_ns"]), int(entry["mtime_ns"])),
            follow_symlinks=False,
        )
    except (OSError, NotImplementedError, KeyError) as exc:
        warnings.append(f"Could not restore timestamps for {path.name}: {exc}")
    return warnings


def restore(root: Path, manifest: dict[str, Any], restore_owner: bool = False) -> list[str]:
    root = Path(root)
    warnings: list[str] = []
    entries = sorted(
        manifest.get("entries", []),
        key=lambda entry: (entry.get("path", ".").count("/"), entry.get("path", ".")),
        reverse=True,
    )
    for entry in entries:
        target = _entry_target(root, entry.get("path", "."))
        if not target.exists() and not target.is_symlink():
            warnings.append(f"Missing path; skipped metadata restore: {target}")
            continue
        if not restore_owner:
            current = target.lstat()
            if current.st_uid != entry.get("uid") or current.st_gid != entry.get("gid"):
                warnings.append(
                    f"UID/GID saved in sidecar but not restored for {target.name}; "
                    "use --owner if appropriate."
                )
        warnings.extend(apply_entry(target, entry, restore_owner=restore_owner))
    return warnings


def _current_xattrs(path: Path) -> dict[str, str] | None:
    attrs, _ = _xattrs(path)
    return attrs


def verify(root: Path, manifest: dict[str, Any], check_owner: bool = False) -> dict[str, Any]:
    root = Path(root)
    checks: list[dict[str, Any]] = []
    warnings = list(manifest.get("warnings", []))
    verified_times: list[tuple[Path, int, int]] = []
    for entry in manifest.get("entries", []):
        path = _entry_target(root, entry.get("path", "."))
        if not path.exists() and not path.is_symlink():
            checks.append({"path": entry.get("path", "."), "ok": False, "reason": "missing"})
            continue
        st = path.lstat()
        verified_times.append((path, st.st_atime_ns, st.st_mtime_ns))
        failures: list[str] = []
        if _kind(st.st_mode) != entry.get("kind"):
            failures.append("kind")
        if stat.S_IMODE(st.st_mode) != entry.get("mode"):
            failures.append("mode")
        if abs(st.st_mtime_ns - int(entry.get("mtime_ns", st.st_mtime_ns))) > 1_000_000:
            failures.append("mtime")
        if check_owner and (st.st_uid != entry.get("uid") or st.st_gid != entry.get("gid")):
            failures.append("owner")
        if entry.get("kind") == "file" and sha256_file(path) != entry.get("sha256"):
            failures.append("sha256")
        if entry.get("kind") == "symlink" and os.readlink(path) != entry.get("target"):
            failures.append("target")
        if "xattrs" in entry and _current_xattrs(path) != entry["xattrs"]:
            failures.append("xattrs")
        if "acl" in entry:
            if not shutil.which("getfacl"):
                warnings.append(
                    f"ACL verification unavailable for {entry.get('path', '.')}: "
                    "getfacl is not installed."
                )
            else:
                acl, acl_warnings = _acl(path, entry.get("kind") == "symlink")
                warnings.extend(acl_warnings)
                if acl != entry["acl"]:
                    failures.append("acl")
        checks.append({"path": entry.get("path", "."), "ok": not failures, "failed": failures})
    for path, atime_ns, mtime_ns in reversed(verified_times):
        try:
            os.utime(path, ns=(atime_ns, mtime_ns), follow_symlinks=False)
        except (OSError, NotImplementedError):
            pass
    return {
        "ok": all(check["ok"] for check in checks),
        "operation": manifest.get("operation"),
        "checks": checks,
        "warnings": sorted(set(warnings)),
    }


def write_manifest(path: Path, manifest: dict[str, Any]) -> Path:
    sidecar = Path(str(path) + ".metakeep.json")
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{sidecar.name}.", suffix=".tmp", dir=sidecar.parent
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(manifest, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, sidecar)
    finally:
        if temporary.exists():
            temporary.unlink()
    return sidecar


def load_manifest(path: Path) -> dict[str, Any]:
    manifest_path = Path(path)
    if manifest_path.is_dir() or (
        not manifest_path.name.endswith(".metakeep.json")
        and manifest_path.suffix.lower() != ".json"
    ):
        manifest_path = Path(str(manifest_path) + ".metakeep.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict) or manifest.get("schema") != SCHEMA:
        raise ValueError(f"Unsupported manifest schema in {manifest_path}")
    if not isinstance(manifest.get("entries"), list):
        raise ValueError(f"Manifest entries are invalid in {manifest_path}")
    return manifest
