#!/usr/bin/env python3
"""Build and verify a plain ZIP32 IPA for on-device signing tools."""
import argparse
import os
from pathlib import Path, PurePosixPath
import plistlib
import stat
import struct
import tempfile
import zipfile

APP = "Payload/NodeScope.app/"
MANIFEST = APP + "Info.plist"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(path):
    raw = Path(path).read_bytes()
    require(raw[:4] == b"PK\x03\x04", "IPA must start with a ZIP local header")
    require(raw[-22:-18] == b"PK\x05\x06", "Expected ZIP32 end record without a comment")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [i.filename for i in entries]
        require(len(names) == len(set(names)), "Duplicate ZIP entries")
        require(names[:3] == ["Payload/", APP, MANIFEST], "Main Info.plist must be the first file")
        require(all(n.startswith(APP) or n == "Payload/" for n in names), "Unexpected main bundle layout")
        next_offset = 0
        for entry in entries:
            name = entry.filename
            require(name.isascii() and "\\" not in name and not name.startswith("/")
                    and ".." not in PurePosixPath(name).parts, "Invalid archive path")
            require(entry.compress_type == zipfile.ZIP_STORED, "Compatibility IPA must use stored entries")
            require(entry.flag_bits == 0 and not entry.extra and not entry.comment,
                    "ZIP flags, extra fields and comments are unsupported")
            require(entry.header_offset == next_offset, "Unexpected bytes between local records")
            offset = entry.header_offset
            fields = struct.unpack_from("<IHHHHHIIIHH", raw, offset)
            signature, version, flags, method, _, _, crc, compressed, size, name_size, extra_size = fields
            require(signature == 0x04034B50 and version <= 20 and flags == 0 and method == 0,
                    "Unsupported local ZIP header")
            require((crc, compressed, size) == (entry.CRC, entry.compress_size, entry.file_size),
                    "Local ZIP sizes/CRC do not match the central directory")
            start = offset + 30
            require(raw[start:start + name_size] == name.encode("ascii") and extra_size == 0,
                    "Local ZIP path/extra field mismatch")
            next_offset = start + name_size + size
            archive.read(entry)  # Checks the CRC of every file, including local-header scanning.
        require(next_offset == archive.start_dir, "Unexpected data before the central directory")
        manifest = archive.read(MANIFEST)
        require(manifest.startswith(b"<?xml"), "Use an XML main Info.plist")
        info = plistlib.loads(manifest)
        require(info.get("CFBundleIdentifier") == "app.nodescope.speedtest", "Unexpected bundle ID")
        require(info.get("CFBundlePackageType") == "APPL", "Expected an application bundle")
        executable = info.get("CFBundleExecutable", "")
        require(executable and PurePosixPath(executable).name == executable, "Invalid executable name")
        binary = archive.read(APP + executable)
        require(len(binary) >= 32 and struct.unpack_from("<II", binary) == (0xFEEDFACF, 0x100000C)
                and struct.unpack_from("<I", binary, 12)[0] == 2, "Expected an arm64 iOS executable")
        return info


def package(app, output):
    app, output = Path(app), Path(output)
    require(app.is_dir() and app.name == "NodeScope.app", "Expected NodeScope.app directory")
    manifest = plistlib.loads((app / "Info.plist").read_bytes())
    output.parent.mkdir(parents=True, exist_ok=True)
    paths = sorted(app.rglob("*"))
    require(not any(p.is_symlink() for p in paths), "Resolve bundle symlinks before packaging")
    # A seekable output writes sizes and CRC directly into each local header. No
    # streaming descriptors, ZIP64, macOS extra fields or compression are used.
    handle, temporary = tempfile.mkstemp(prefix=".nodescope-", suffix=".ipa", dir=output.parent)
    os.close(handle)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED, allowZip64=False) as archive:
            def write(name, data=b"", mode=0o644):
                entry = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
                entry.create_system = 3
                directory = name.endswith("/")
                entry.external_attr = ((stat.S_IFDIR if directory else stat.S_IFREG) | mode) << 16
                if directory:
                    entry.external_attr |= 0x10
                archive.writestr(entry, data)

            write("Payload/", mode=0o755)
            write(APP, mode=0o755)
            write(MANIFEST, plistlib.dumps(manifest, fmt=plistlib.FMT_XML))
            for path in paths:
                relative = path.relative_to(app).as_posix()
                if relative == "Info.plist" or any(part in (".DS_Store", "__MACOSX") or part.startswith("._")
                                                   for part in path.relative_to(app).parts):
                    continue
                if path.is_dir():
                    write(APP + relative + "/", mode=0o755)
                else:
                    write(APP + relative, path.read_bytes(), 0o755 if path.stat().st_mode & 0o111 else 0o644)
        verify(temporary)
        os.replace(temporary, output)  # Replaces rather than appends to any previous build.
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("package")
    build.add_argument("app")
    build.add_argument("output")
    check = sub.add_parser("verify")
    check.add_argument("ipa")
    args = parser.parse_args()
    if args.command == "package":
        package(args.app, args.output)
        print("Packaged and verified:", args.output)
    else:
        info = verify(args.ipa)
        print("Verified IPA:", info["CFBundleShortVersionString"], "build", info["CFBundleVersion"])
