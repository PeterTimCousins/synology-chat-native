#!/usr/bin/env python3
"""Run packaging scripts against disposable apps and fake build/sign tools."""
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPOSITORY = Path(__file__).resolve().parents[1]


class PackagingTests(unittest.TestCase):
    def run_case(self, script, failure=None, candidate=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            shutil.copyfile(REPOSITORY / "scripts" / script, root / "scripts" / script)
            shutil.copytree(REPOSITORY / "packaging", root / "packaging")
            api = script == "package-api-app.sh"
            name = "Synology Chat Native API" if api else "Synology Chat Native"
            package_root = root / "build/candidates" if candidate else root / "build"
            app = package_root / (name + ".app")
            previous = package_root / (name + ".previous.app")
            canonical = root / "build" / (name + ".app/preserved-marker")
            if candidate:
                canonical.parent.mkdir(parents=True)
                canonical.write_text("canonical-untouched")
            for path, marker in [(app, "current"), (previous, "older")]:
                path.mkdir(parents=True)
                (path / "preserved-marker").write_text(marker)
            tools = root / "tools"
            tools.mkdir()
            scripts = {
                "swift": '#!/bin/bash\n[[ "$PACKAGING_FAILURE" == build ]] && exit 31\nmkdir -p .build/release\nprintf synthetic > .build/release/SynologyChatNative\n',
                "codesign": '#!/bin/bash\n[[ "$PACKAGING_FAILURE" == sign ]] && exit 32\nexit 0\n',
                "mv": '#!/bin/bash\nif [[ "$PACKAGING_FAILURE" == install && "$1" == *-package.* ]]; then exit 33; fi\nexec /bin/mv "$@"\n'
            }
            for tool, content in scripts.items():
                path = tools / tool
                path.write_text(content)
                path.chmod(0o755)
            env = {**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"], "PACKAGING_FAILURE": failure or "none"}
            result = subprocess.run(["bash", str(root / "scripts" / script)] + (["--candidate"] if candidate else []), cwd=root, env=env, capture_output=True)
            self.assertEqual(result.returncode == 0, failure is None, result.stderr.decode())
            if candidate:
                self.assertEqual(canonical.read_text(), "canonical-untouched")
            if failure in ("build", "sign"):
                self.assertEqual((app / "preserved-marker").read_text(), "current")
                self.assertEqual((previous / "preserved-marker").read_text(), "older")
                self.assertFalse((root / "build/package-history").exists())
            else:
                retained = list((root / "build/package-history").glob("*/*.app/preserved-marker"))
                self.assertEqual([path.read_text() for path in retained], ["older"])
                if failure == "install":
                    self.assertEqual((app / "preserved-marker").read_text(), "current", "Failed install must restore current app")
                else:
                    self.assertEqual((previous / "preserved-marker").read_text(), "current")
                    self.assertEqual((app / "Contents/MacOS/SynologyChatNative").read_text(), "synthetic")
                    manifest = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                    if api:
                        self.assertEqual(manifest["CFBundleIdentifier"], "com.costwisegroup.synology-chat-native.api")
                        self.assertEqual(manifest["CFBundleDisplayName"], "Chat Native")
                        self.assertEqual(manifest["CFBundleIconFile"], "NativeAppIcon")
                        self.assertEqual((app / "Contents/Resources/NativeAppIcon.icns").read_bytes(), (root / "packaging/NativeAppIcon.icns").read_bytes())
                        self.assertNotEqual((root / "packaging/NativeAppIcon.icns").read_bytes(), (root / "packaging/AppIcon.icns").read_bytes())
                        for key in ("NSAppTransportSecurity", "NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
                            self.assertNotIn(key, manifest)
                    else:
                        self.assertEqual(manifest["CFBundleIdentifier"], "com.costwisegroup.synology-chat-native")
                        self.assertTrue(manifest["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"])
            self.assertFalse(list((root / "build").glob("*-package.*")), "Private staging should be cleaned")

    def testSuccessfulReplacementRetainsBothEarlierBuilds(self):
        for script in ("package-app.sh", "package-api-app.sh"):
            with self.subTest(script=script):
                self.run_case(script)

    def testBuildFailurePreservesEveryApp(self):
        for script in ("package-app.sh", "package-api-app.sh"):
            with self.subTest(script=script):
                self.run_case(script, "build")

    def testSigningFailurePreservesEveryApp(self):
        for script in ("package-app.sh", "package-api-app.sh"):
            with self.subTest(script=script):
                self.run_case(script, "sign")

    def testInstallFailureRestoresCurrentAppAndRetainsOlderBuild(self):
        for script in ("package-app.sh", "package-api-app.sh"):
            with self.subTest(script=script):
                self.run_case(script, "install")

    def testCandidatePackagingNeverReplacesCanonicalAppOnSuccessOrFailure(self):
        for failure in (None, "build", "sign", "install"):
            with self.subTest(failure=failure):
                self.run_case("package-api-app.sh", failure, candidate=True)

    def testPreviewUsesNativeManifestWithoutChangingWrapperTemplate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            shutil.copyfile(REPOSITORY / "scripts/package-native-preview.sh", root / "scripts/package-native-preview.sh")
            shutil.copytree(REPOSITORY / "packaging", root / "packaging")
            template = (root / "packaging/Info.plist").read_bytes()
            tools = root / "tools"
            tools.mkdir()
            for name, content in {
                "swift": '#!/bin/bash\nmkdir -p .build/debug\nprintf synthetic > .build/debug/SynologyChatNative\n',
                "codesign": '#!/bin/bash\nexit 0\n'
            }.items():
                path = tools / name
                path.write_text(content)
                path.chmod(0o755)
            result = subprocess.run(["bash", "scripts/package-native-preview.sh"], cwd=root,
                env={**os.environ, "PATH": str(tools) + ":" + os.environ["PATH"]}, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            manifest = plistlib.loads((root / "build/Synology Chat API Preview.app/Contents/Info.plist").read_bytes())
            self.assertEqual(manifest["CFBundleIdentifier"], "com.costwisegroup.synology-chat-native.api-preview")
            self.assertEqual(manifest["CFBundleDisplayName"], "Chat Native Preview")
            self.assertEqual(manifest["CFBundleIconFile"], "PreviewAppIcon")
            self.assertEqual((root / "build/Synology Chat API Preview.app/Contents/Resources/PreviewAppIcon.icns").read_bytes(), (root / "packaging/PreviewAppIcon.icns").read_bytes())
            self.assertNotEqual((root / "packaging/PreviewAppIcon.icns").read_bytes(), (root / "packaging/NativeAppIcon.icns").read_bytes())
            for key in ("NSAppTransportSecurity", "NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
                self.assertNotIn(key, manifest)
            self.assertEqual((root / "packaging/Info.plist").read_bytes(), template)


if __name__ == "__main__":
    unittest.main()
