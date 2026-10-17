import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("package_ipa", Path(__file__).with_name("package-ipa.py"))
ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ipa)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = self.root / "NodeScope.app"
        self.app.mkdir()
        info = {"CFBundleIdentifier": "app.nodescope.speedtest", "CFBundleExecutable": "NodeScope",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.2.1", "CFBundleVersion": "5"}
        (self.app / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        self.binary = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 2, 0, 0, 0, 0)
        (self.app / "NodeScope").write_bytes(self.binary)
        (self.app / "NodeScope").chmod(0o755)
        self.output = self.root / "test.ipa"

    def test_fresh_package_has_shallow_xml_manifest_and_preserves_executable(self):
        (self.app / "._Info.plist").write_bytes(b"resource fork")
        (self.app / "Resources").mkdir()
        (self.app / "Resources/sample.txt").write_text("resource")
        ipa.package(self.app, self.output)
        self.assertEqual(ipa.verify(self.output)["CFBundleVersion"], "5")
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(archive.read(ipa.APP + "NodeScope"), self.binary)
            self.assertTrue(archive.getinfo(ipa.APP + "NodeScope").external_attr >> 16 & 0o111)
            self.assertEqual(archive.read(ipa.APP + "Resources/sample.txt"), b"resource")
            self.assertFalse(any("._Info" in n for n in archive.namelist()))

    def test_repeated_build_removes_stale_files_and_is_reproducible(self):
        stale = self.app / "stale.txt"
        stale.write_text("previous build")
        ipa.package(self.app, self.output)
        stale.unlink()
        ipa.package(self.app, self.output)
        expected = self.output.read_bytes()
        ipa.package(self.app, self.output)
        self.assertEqual(self.output.read_bytes(), expected)
        with zipfile.ZipFile(self.output) as archive:
            self.assertNotIn(ipa.APP + "stale.txt", archive.namelist())

    def test_local_header_crc_mismatch_is_rejected(self):
        ipa.package(self.app, self.output)
        raw = bytearray(self.output.read_bytes())
        with zipfile.ZipFile(self.output) as archive:
            offset = archive.getinfo(ipa.MANIFEST).header_offset
        raw[offset + 14] ^= 1  # Central-directory CRC still valid, local CRC wrong.
        self.output.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, "sizes/CRC"):
            ipa.verify(self.output)

    def test_nested_actions_zip_is_not_an_ipa(self):
        ipa.package(self.app, self.output)
        outer = self.root / "artifact.zip"
        with zipfile.ZipFile(outer, "w") as archive:
            archive.write(self.output, "NodeScope-unsigned.ipa")
        with self.assertRaisesRegex(ValueError, "first file"):
            ipa.verify(outer)

    def test_missing_manifest_and_symlinks_fail_before_replacing_output(self):
        ipa.package(self.app, self.output)
        original = self.output.read_bytes()
        (self.app / "link").symlink_to("NodeScope")
        with self.assertRaisesRegex(ValueError, "symlinks"):
            ipa.package(self.app, self.output)
        self.assertEqual(self.output.read_bytes(), original)
        (self.app / "link").unlink()
        (self.app / "Info.plist").unlink()
        with self.assertRaises(FileNotFoundError):
            ipa.package(self.app, self.output)
        self.assertEqual(self.output.read_bytes(), original)

    def test_incomplete_download_is_rejected(self):
        ipa.package(self.app, self.output)
        self.output.write_bytes(self.output.read_bytes()[:-16])
        with self.assertRaisesRegex(ValueError, "end record"):
            ipa.verify(self.output)


if __name__ == "__main__":
    unittest.main()
