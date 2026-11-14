import shutil
import subprocess
import tempfile
import unittest
import plistlib
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "release.command"


@unittest.skipUnless(shutil.which("zsh"), "zsh nécessaire")
class ReleaseTests(unittest.TestCase):
    def test_invalid_arguments_fail_before_building_or_creating_files(self):
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "release.command"
            shutil.copyfile(SCRIPT, script)
            for arguments in ([], ["--unsigned"], ["--preview", "profil"],
                              ["--archive", "Apple Development: Nom (TEAMID)"],
                              ["Developer ID Application: Nom (TEAMID)", "profil"],
                              ["--package", ""]):
                with self.subTest(arguments=arguments):
                    result = subprocess.run(["zsh", str(script), *arguments],
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("Usage", result.stderr)
                    self.assertEqual(list(Path(folder).iterdir()), [script])

    @unittest.skipUnless(Path("/usr/bin/security").is_file(), "Trousseau macOS nécessaire")
    def test_missing_developer_id_is_rejected_before_build(self):
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder) / "release.command"
            shutil.copyfile(SCRIPT, script)
            result = subprocess.run([
                "zsh", str(script), "--archive", "Developer ID Application: Nabaztag Test Inexistant (0000000000)"
                ], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Certificat Developer ID Application introuvable", result.stderr)
            self.assertEqual(list(Path(folder).iterdir()), [script])

    @unittest.skipUnless(Path("/usr/bin/codesign").is_file(), "Signature macOS nécessaire")
    def test_invalid_or_unnotarized_app_cannot_create_distribution(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            script = root / "release.command"
            shutil.copyfile(SCRIPT, script)
            shutil.copyfile(SCRIPT.parent / "Info.plist", root / "Info.plist")
            info = plistlib.loads((root / "Info.plist").read_bytes())
            app = root / "Nabaztag IA.app"
            binaries = app / "Contents" / "MacOS"
            binaries.mkdir(parents=True)
            (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))
            for name in ("NabaztagIA", "NabaztagSSHAskpass"):
                shutil.copyfile("/usr/bin/true", binaries / name)
                (binaries / name).chmod(0o755)
            for target in (binaries / "NabaztagSSHAskpass", app):
                subprocess.run(["codesign", "--force", "--options", "runtime", "--sign", "-", str(target)],
                               capture_output=True, check=True, timeout=10)
            for source in (root / "missing.app", app):
                with self.subTest(source=source):
                    result = subprocess.run(["zsh", str(script), "--package", str(source)],
                                            capture_output=True, text=True, timeout=20)
                    self.assertNotEqual(result.returncode, 0)
                    if source == app:
                        self.assertIn("does not have a ticket stapled", result.stdout + result.stderr)
                    self.assertFalse((root / ".build").exists())
                    self.assertFalse((root / "dist").exists())
