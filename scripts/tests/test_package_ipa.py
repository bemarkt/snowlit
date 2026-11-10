"""Portable checks of the uploaded archive, not a substitute for Apple packaging."""

import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("package_ipa", Path(__file__).parents[1] / "package_ipa.py")
package_ipa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_ipa)


class ArchiveVerificationTests(unittest.TestCase):
    revision = "1" * 40

    def make_archive(self, folder, *, platform="iPhoneOS", revision=None, executable=True, extra=None):
        ipa = Path(folder) / "Snowlit.ipa"
        prefix = "Payload/Snowlit.app/"
        info = dict(CFBundleIdentifier="io.github.bemarkt.snowlit", CFBundleExecutable="Snowlit",
                    CFBundleShortVersionString="0.1.0", CFBundleVersion="1", MinimumOSVersion="26.0",
                    CFBundleSupportedPlatforms=[platform], UIDeviceFamily=[1])
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr(prefix + "Info.plist", plistlib.dumps(info))
            archive.writestr(prefix + "SnowlitBuild.json", json.dumps(dict(sourceRevision=revision or self.revision, signing="unsigned")))
            entry = zipfile.ZipInfo(prefix + "Snowlit")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            archive.writestr(entry, b"fixture executable bytes")
            if extra:
                archive.writestr(extra, b"unexpected content")
        return ipa

    def test_archive_hash_metadata_and_executable_match_downloaded_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            ipa = self.make_archive(folder)
            report = package_ipa.verify_archive(ipa, self.revision)
            self.assertEqual(report["ipaSHA256"], hashlib.sha256(ipa.read_bytes()).hexdigest())
            self.assertEqual(report["sourceRevision"], self.revision)
            self.assertEqual(report["bundle"]["MinimumOSVersion"], "26.0")
            self.assertEqual(report["executableSHA256"], hashlib.sha256(b"fixture executable bytes").hexdigest())

    def test_simulator_source_mismatch_and_lost_permission_are_rejected(self):
        for change in [dict(platform="iPhoneSimulator"), dict(revision="2" * 40), dict(executable=False)]:
            with self.subTest(change=change), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(ValueError):
                    package_ipa.verify_archive(self.make_archive(folder, **change), self.revision)

    def test_only_unsigned_app_content_can_be_uploaded(self):
        for extra in ["PROGRESS.md", "Payload/Snowlit.app/.local/report.txt",
                      "Payload/Snowlit.app/docs/rewrite/plan.md", "Payload/Snowlit.app/logo.png",
                      "Payload/Snowlit.app/embedded.mobileprovision", "Payload/Snowlit.app/_CodeSignature/CodeResources",
                      "Payload/Snowlit.app/../private.txt"]:
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as folder:
                with self.assertRaises(ValueError):
                    package_ipa.verify_archive(self.make_archive(folder, extra=extra), self.revision)


if __name__ == "__main__":
    unittest.main()
