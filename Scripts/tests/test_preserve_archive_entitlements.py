import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "preserve_archive_entitlements.py"
spec = importlib.util.spec_from_file_location("preserve_archive_entitlements", SCRIPT)
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class FakeCodesign:
    def __init__(self, change=None, fail=None):
        self.calls = []
        self.signatures = {}
        self.change = change
        self.fail = fail

    def __call__(self, command, capture_output, check):
        self.calls.append(command)
        path = Path(command[-1])
        if self.fail and self.fail(command):
            return subprocess.CompletedProcess(command, 1, b"", b"private diagnostic not for publication")
        if "--force" in command:
            self.signatures[path] = plistlib.loads(Path(command[command.index("--entitlements") + 1]).read_bytes())
            if self.change:
                self.change(path, self.signatures[path])
            return subprocess.CompletedProcess(command, 0, b"", b"")
        return subprocess.CompletedProcess(command, 0, plistlib.dumps(self.signatures[path]), b"")


class PreserveArchiveTests(unittest.TestCase):
    prefix = "com.example.daytape"
    group = "group.com.example.daytape"

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.private = self.root / "private"
        self.archive = self.private / "DayTape.xcarchive"
        self.source = self.root / "source"
        self.phone = self.archive / "Products/Applications/DayTape.app"
        self.watch = self.phone / "Watch/DayTapeWatch.app"
        self.phone_widget = self.phone / "PlugIns/DayTapeWidgets.appex"
        self.watch_widget = self.watch / "PlugIns/DayTapeWatchWidgets.appex"
        for path, suffix in [(self.phone, ""), (self.watch, ".watchkitapp"),
                             (self.phone_widget, ".widgets"), (self.watch_widget, ".watchkitapp.widgets")]:
            path.mkdir(parents=True, exist_ok=True)
            info = dict(CFBundleIdentifier=self.prefix + suffix, CFBundleExecutable=path.stem,
                        DayTapeAppGroup=self.group)
            if suffix.endswith(".widgets"):
                info["NSExtension"] = {"NSExtensionPointIdentifier": "com.apple.widgetkit-extension"}
            if suffix == ".watchkitapp":
                info["WKCompanionAppBundleIdentifier"] = self.prefix
            (path / "Info.plist").write_bytes(plistlib.dumps(info))
            (path / path.stem).write_bytes(b"mock Mach-O")
        for folder in ["Phone", "Watch", "Widgets"]:
            (self.source / folder).mkdir(parents=True)
            value = {helper.GROUP_KEY: ["$(DAYTAPE_APP_GROUP)"]}
            if folder == "Phone":
                value[helper.HEALTH_KEY] = True
                value[helper.HEALTH_BACKGROUND_KEY] = True
            (self.source / folder / "DayTape.entitlements").write_bytes(plistlib.dumps(value))
        self.library = self.phone / "Frameworks/libswiftCompatibilitySpan.dylib"
        self.library.parent.mkdir()
        self.library.write_bytes(b"mock dylib")
        self.framework = self.phone / "Frameworks/Nested.framework"
        self.framework.mkdir()
        (self.framework / "Nested").write_bytes(b"mock framework")

    def run_preserve(self, runner):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            helper.preserve(self.archive, self.source, self.private, self.prefix, self.group, runner=runner)
        return output.getvalue()

    def update_plist(self, path, update):
        value = plistlib.loads(path.read_bytes())
        update(value)
        path.write_bytes(plistlib.dumps(value))

    def testSignsNestedCodeWithoutCapabilitiesThenEachTargetInsideOut(self):
        runner = FakeCodesign()
        output = self.run_preserve(runner)
        signed = [Path(call[-1]) for call in runner.calls if "--force" in call]
        self.assertEqual(set(signed[:2]), {self.library, self.framework})
        self.assertEqual(signed[2:], [self.watch_widget, self.watch, self.phone_widget, self.phone])
        for path in [self.library, self.framework]:
            self.assertEqual(runner.signatures[path], {})
        for path in [self.watch_widget, self.watch, self.phone_widget, self.phone]:
            self.assertEqual(runner.signatures[path][helper.GROUP_KEY], [self.group])
        self.assertTrue(runner.signatures[self.phone][helper.HEALTH_KEY])
        self.assertTrue(runner.signatures[self.phone][helper.HEALTH_BACKGROUND_KEY])
        self.assertNotIn(helper.HEALTH_KEY, runner.signatures[self.watch])
        for call in runner.calls:
            self.assertNotIn("--deep", call)
            if "--force" in call:
                self.assertEqual(call[call.index("--sign") + 1], "-")
                self.assertIn("--generate-entitlement-der", call)
                self.assertIn("--timestamp=none", call)
        self.assertNotIn(self.prefix, output)
        self.assertIn("iPhone temporary capabilities: app_group=true, healthkit=true, health_background=true", output)

    def testEveryBundleIDIsValidatedBeforeAnySigning(self):
        self.update_plist(self.phone / "Info.plist", lambda value: value.update(CFBundleIdentifier="com.other.app"))
        runner = FakeCodesign()
        with self.assertRaisesRegex(helper.PreservationError, "bundle identifier"):
            self.run_preserve(runner)
        self.assertEqual(runner.calls, [])

    def testCompiledGroupMismatchFailsBeforeSigning(self):
        self.update_plist(self.phone_widget / "Info.plist", lambda value: value.update(DayTapeAppGroup="group.other.app"))
        runner = FakeCodesign()
        with self.assertRaisesRegex(helper.PreservationError, "compiled App Group"):
            self.run_preserve(runner)
        self.assertEqual(runner.calls, [])

    def testOtherBuildVariablesAreRejectedBeforeSigning(self):
        self.update_plist(self.source / "Phone/DayTape.entitlements",
                          lambda value: value.update({"keychain-access-groups": ["$(AppIdentifierPrefix)shared"]}))
        runner = FakeCodesign()
        with self.assertRaisesRegex(helper.PreservationError, "unsupported or unexpanded variable"):
            self.run_preserve(runner)
        self.assertEqual(runner.calls, [])

    def testMissingSourceHealthPermissionCannotSilentlyShip(self):
        self.update_plist(self.source / "Phone/DayTape.entitlements",
                          lambda value: value.pop(helper.HEALTH_BACKGROUND_KEY))
        runner = FakeCodesign()
        with self.assertRaisesRegex(helper.PreservationError, "both HealthKit"):
            self.run_preserve(runner)
        self.assertEqual(runner.calls, [])

    def testExtraNestedExtensionCannotRemainUnsigned(self):
        (self.phone / "PlugIns/Unexpected.appex").mkdir()
        runner = FakeCodesign()
        with self.assertRaises(helper.PreservationError):
            self.run_preserve(runner)
        self.assertEqual(runner.calls, [])

    def testReadBackDetectsLostGroupAndHealthClaims(self):
        for key in [helper.GROUP_KEY, helper.HEALTH_KEY, helper.HEALTH_BACKGROUND_KEY]:
            with self.subTest(key=key):
                def change(path, value):
                    if path == self.phone:
                        value.pop(key)
                runner = FakeCodesign(change=change)
                with self.assertRaisesRegex(helper.PreservationError, "did not retain"):
                    self.run_preserve(runner)

    def testSigningFailureStopsAndDoesNotEchoSubprocessPayload(self):
        runner = FakeCodesign(fail=lambda command: command[-1] == str(self.watch_widget))
        with self.assertRaisesRegex(helper.PreservationError, "Watch widget temporary signing failed") as result:
            self.run_preserve(runner)
        self.assertNotIn("private diagnostic", str(result.exception))
        self.assertNotIn(self.phone, runner.signatures)

    def testArchiveOutsidePrivateDirectoryIsRejected(self):
        runner = FakeCodesign()
        (self.root / "unrelated").mkdir()
        with self.assertRaisesRegex(helper.PreservationError, "outside"):
            helper.preserve(self.archive, self.source, self.root / "unrelated", self.prefix, self.group, runner=runner)
        self.assertEqual(runner.calls, [])


if __name__ == "__main__":
    unittest.main()
