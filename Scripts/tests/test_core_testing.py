import copy
import datetime
import importlib.util
import io
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_core_export", ROOT / "Scripts/verify_core_export.py")
core = importlib.util.module_from_spec(spec)
spec.loader.exec_module(core)


class CoreExportVerificationTests(unittest.TestCase):
    def setUp(self):
        self.bundle = "com.example.daytape"
        self.client = "configure.apps.googleusercontent.com"
        common = dict(CFBundleVersion="9.1", CFBundleShortVersionString="0.5.0",
                      DayTapeFeatureSet="core-testing", DayTapeAppGroup="")
        self.phone = dict(common, CFBundleIdentifier=self.bundle, GIDClientID=self.client,
                          CFBundleURLTypes=[dict(CFBundleURLSchemes=["daytape", "com.googleusercontent.apps.configure"])])
        self.watch = dict(common, CFBundleIdentifier=self.bundle + ".watchkitapp", WKCompanionAppBundleIdentifier=self.bundle)
        self.signature = {"com.apple.developer.team-identifier": "TEAM123456", "application-identifier": "TEAM123456." + self.bundle}
        self.profile = dict(TeamIdentifier=["TEAM123456"], ApplicationIdentifierPrefix=["TEAM123456"],
                            ExpirationDate=datetime.datetime(2099, 1, 1),
                            Entitlements={"application-identifier": "TEAM123456." + self.bundle, "beta-reports-active": True})

    def verify_info(self):
        core.validate_info(self.phone, self.watch, self.bundle, "9.1", self.client)

    def test_exact_two_app_metadata_passes_and_full_or_mislabeled_builds_fail(self):
        self.verify_info()
        for key, value in [("DayTapeFeatureSet", "full"), ("DayTapeAppGroup", "group.com.example.daytape"),
                           ("CFBundleVersion", "8.1"), ("NSHealthShareUsageDescription", "reads health")]:
            original = copy.deepcopy(self.phone)
            self.phone[key] = value
            with self.assertRaises(core.CoreVerificationError): self.verify_info()
            self.phone = original

    def test_missing_callback_and_wrong_companion_are_rejected(self):
        self.phone["CFBundleURLTypes"] = []
        with self.assertRaises(core.CoreVerificationError): self.verify_info()
        self.setUp(); self.watch["WKCompanionAppBundleIdentifier"] = "com.other.app"
        with self.assertRaises(core.CoreVerificationError): self.verify_info()

    def test_real_distribution_identity_is_required_and_extra_profile_authorization_does_not_grant_it(self):
        core.validate_signing(self.signature, self.profile, self.bundle, "TEAM123456")
        self.profile["Entitlements"].update({"com.apple.developer.healthkit": True,
                                          "com.apple.security.application-groups": ["group.example.authorized.elsewhere"]})
        core.validate_signing(self.signature, self.profile, self.bundle, "TEAM123456")
        for name, value in [("com.apple.developer.healthkit", True),
                            ("com.apple.developer.healthkit.background-delivery", True),
                            ("com.apple.security.application-groups", ["group.com.example.daytape"])]:
            signature = dict(self.signature); signature[name] = value
            with self.assertRaises(core.CoreVerificationError):
                core.validate_signing(signature, self.profile, self.bundle, "TEAM123456")

    def test_development_ad_hoc_wrong_team_and_expired_profiles_fail(self):
        for mutator in [lambda p: p.update(ProvisionedDevices=[]),
                        lambda p: p.update(ProvisionsAllDevices=True),
                        lambda p: p.update(TeamIdentifier=["OTHER12345"]),
                        lambda p: p.update(ExpirationDate=datetime.datetime(2000, 1, 1)),
                        lambda p: p["Entitlements"].update({"get-task-allow": True}),
                        lambda p: p["Entitlements"].update({"application-identifier": "TEAM123456.*"}),
                        lambda p: p["Entitlements"].pop("beta-reports-active")]:
            profile = copy.deepcopy(self.profile); mutator(profile)
            with self.assertRaises(core.CoreVerificationError):
                core.validate_signing(self.signature, profile, self.bundle, "TEAM123456")
        with self.assertRaises(core.CoreVerificationError):
            core.validate_signing({}, self.profile, self.bundle, "TEAM123456")

    def package(self, extras=()):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, "w") as archive:
            archive.writestr("Payload/DayTape.app/Info.plist", plistlib.dumps(self.phone))
            archive.writestr("Payload/DayTape.app/Watch/DayTapeWatch.app/Info.plist", plistlib.dumps(self.watch))
            for name in extras:
                member = zipfile.ZipInfo("placeholder")
                member.filename = name; member.orig_filename = name
                archive.writestr(member, b"not a permitted core member")
        stream.seek(0)
        return zipfile.ZipFile(stream)

    def test_archive_has_exact_two_apps_and_rejects_widgets_or_unsafe_members(self):
        with self.package() as package:
            phone, watch = core.package_infos(package)
            self.assertEqual(phone, self.phone); self.assertEqual(watch, self.watch)
        for name in ["Payload/DayTape.app/PlugIns/Widget.appex/Info.plist",
                     "Payload/DayTape.app/Watch/DayTapeWatch.app/PlugIns/Widget.appex/Info.plist",
                     "Payload/Other.app/Info.plist", "../escape", "/absolute", "Payload\\escape"]:
            with self.package([name]) as package:
                with self.assertRaises(core.CoreVerificationError): core.package_infos(package)


class FeatureSetGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        for folder in ["Phone", "Watch", "Shared", "Widgets", "Licenses", "Tests", "Scripts"]:
            shutil.copytree(ROOT / folder, self.root / folder, ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copyfile(ROOT / "Local.xcconfig", self.root / "Local.xcconfig")

    def tearDown(self): self.temporary.cleanup()

    def generate(self, *arguments):
        subprocess.run([sys.executable, str(self.root / "Scripts/generate_project.py"), *arguments],
                       check=True, capture_output=True)
        return (self.root / "DayTape.xcodeproj/project.pbxproj").read_text(encoding="utf-8")

    def info(self, folder): return plistlib.loads((self.root / folder / "Info.plist").read_bytes())

    def test_default_full_is_deterministic_and_keeps_all_four_targets_and_capabilities(self):
        first = self.generate()
        self.assertEqual(first, self.generate("--feature-set", "full"))
        self.assertEqual(first.count('"isa" = "PBXNativeTarget"'), 4)
        self.assertIn('"Embed DayTapeWidgets"', first)
        self.assertIn('"Embed DayTapeWatchWidgets"', first)
        self.assertEqual(self.info("Phone")["DayTapeFeatureSet"], "full")
        self.assertEqual(self.info("Phone")["DayTapeAppGroup"], "$(DAYTAPE_APP_GROUP)")
        entitlements = plistlib.loads((self.root / "Phone/DayTape.entitlements").read_bytes())
        self.assertTrue(entitlements["com.apple.developer.healthkit"])
        self.assertTrue(entitlements["com.apple.security.application-groups"])

    def test_explicit_core_has_two_apps_empty_entitlements_no_widget_embedding_and_is_reversible(self):
        full = self.generate()
        core_project = self.generate("--feature-set", "core-testing")
        self.assertEqual(core_project.count('"isa" = "PBXNativeTarget"'), 2)
        self.assertNotIn('"Embed DayTapeWidgets"', core_project)
        self.assertNotIn('"Embed DayTapeWatchWidgets"', core_project)
        self.assertNotIn('"com.apple.ApplicationGroups.iOS"', core_project)
        self.assertNotIn('"com.apple.HealthKit"', core_project)
        self.assertNotIn('"$(DAYTAPE_HEALTHKIT_FLAG)"', core_project)
        self.assertEqual(plistlib.loads((self.root / "Shared/CoreTesting.entitlements").read_bytes()), {})
        for folder in ["Phone", "Watch"]:
            self.assertEqual(self.info(folder)["DayTapeFeatureSet"], "core-testing")
            self.assertEqual(self.info(folder)["DayTapeAppGroup"], "")
        self.assertNotIn("NSHealthShareUsageDescription", self.info("Phone"))
        self.assertEqual(full, self.generate("--feature-set", "full"))


if __name__ == "__main__": unittest.main()
