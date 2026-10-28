#!/usr/bin/env python3
"""Verify a deliberately limited two-app TestFlight IPA; never accepts a full build.

Core testing is an explicit fallback, not a relaxation of full-capability checks.
No app-group or HealthKit entitlement may be claimed by either signed executable.
"""
from __future__ import annotations
import datetime
import os
from pathlib import Path, PurePosixPath
import plistlib
import subprocess
import sys
import zipfile


class CoreVerificationError(Exception):
    pass


def fail(message):
    raise CoreVerificationError(message)


def validate_info(phone, watch, bundle, build, client):
    if not isinstance(phone, dict) or not isinstance(watch, dict):
        fail("The core app metadata must be property-list dictionaries.")
    if watch.get("WKCompanionAppBundleIdentifier") != bundle:
        fail("The core Watch app must reference this iPhone companion.")
    for label, info, suffix in [("iPhone", phone, ""), ("Watch", watch, ".watchkitapp")]:
        if info.get("CFBundleIdentifier") != bundle + suffix:
            fail(label + " core bundle identifier is incorrect.")
        if info.get("CFBundleVersion") != build or info.get("CFBundleShortVersionString") != "0.5.0":
            fail(label + " core version does not match this release.")
        if info.get("DayTapeFeatureSet") != "core-testing" or info.get("DayTapeAppGroup") != "":
            fail(label + " must explicitly declare core-testing with no shared App Group.")
        if info.get("NSExtension"):
            fail(label + " is unexpectedly an extension.")
    if "NSHealthShareUsageDescription" in phone:
        fail("The core iPhone metadata still advertises HealthKit usage.")
    if phone.get("GIDClientID") != client:
        fail("The core Google client does not match the selected cloud build mode.")
    schemes = [scheme for value in phone.get("CFBundleURLTypes", [])
               for scheme in value.get("CFBundleURLSchemes", [])]
    if "daytape" not in schemes or ".".join(reversed(client.split("."))) not in schemes:
        fail("The core app's callback URL schemes are incomplete.")


def validate_signing(signature, profile, identifier, team, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if signature.get("com.apple.developer.team-identifier") != team or team not in profile.get("TeamIdentifier", []):
        fail("A core app was not signed for the configured Apple team.")
    if signature.get("com.apple.security.application-groups"):
        fail("A core executable unexpectedly claims an App Group.")
    if any(signature.get(key) for key in ["com.apple.developer.healthkit", "com.apple.developer.healthkit.background-delivery"]):
        fail("A core executable unexpectedly claims HealthKit.")
    authorized = profile.get("Entitlements", {})
    app_id = signature.get("application-identifier")
    if (not any(app_id == prefix + "." + identifier for prefix in profile.get("ApplicationIdentifierPrefix", []))
            or authorized.get("application-identifier") != app_id):
        fail("A core app's signed identifier does not match its profile.")
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime) or expiry.replace(tzinfo=datetime.timezone.utc) <= now:
        fail("A core app's distribution profile has expired.")
    if (signature.get("get-task-allow") or authorized.get("get-task-allow")
            or "ProvisionedDevices" in profile or profile.get("ProvisionsAllDevices")
            or not authorized.get("beta-reports-active")):
        fail("Core testing requires real App Store distribution signing.")
    # A profile may authorize extra capabilities for another build. Only capabilities
    # claimed by the signed executable grant access; the core executable must omit them.


def package_infos(package):
    names = package.namelist()
    if len(names) != len(set(names)):
        fail("The core IPA contains duplicate archive members.")
    for member in package.infolist():
        # ZipInfo normalizes OS separators on Windows; validate the original too.
        name = member.orig_filename
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or chr(92) in name:
            fail("The IPA has an unsafe member path.")
    phones = [name for name in names if name.startswith("Payload/") and name.count("/") == 2
              and name.endswith(".app/Info.plist")]
    if len(phones) != 1:
        fail("The core IPA must contain exactly one iPhone application.")
    watches = [name for name in names if name.startswith(phones[0][:-len("Info.plist")] + "Watch/")
               and name.count("/") == 4 and name.endswith(".app/Info.plist")]
    if len(watches) != 1:
        fail("The core IPA must contain exactly one companion Watch application.")
    expected = {phones[0][:-len("Info.plist")].rstrip("/"), watches[0][:-len("Info.plist")].rstrip("/")}
    code_bundles = {"/".join(PurePosixPath(name).parts[:index + 1]) for name in names
                    for index, part in enumerate(PurePosixPath(name).parts)
                    if part.endswith((".app", ".appex"))}
    if code_bundles != expected:
        fail("The core IPA contains an unexpected app or extension; Widgets must be omitted.")
    return plistlib.loads(package.read(phones[0])), plistlib.loads(package.read(watches[0]))


def checked(command, label):
    try:
        result = subprocess.run(command, capture_output=True, check=False)
    except OSError:
        fail(label + " could not start.")
    if result.returncode:
        fail(label + " failed; no profile or credential payload was printed.")
    return result.stdout


def main():
    if os.environ.get("TF_FEATURE_SET") != "core-testing" or os.environ.get("DAYTAPE_APP_GROUP"):
        fail("Core verification requires explicit core-testing and an empty group setting.")
    root = Path(os.environ["TF_PRIVATE_DIR"]).resolve()
    packages = list((root / "export").glob("*.ipa"))
    if len(packages) != 1:
        fail("Expected one core IPA in the private export directory.")
    with zipfile.ZipFile(packages[0]) as package:
        phone, watch = package_infos(package)
    bundle = os.environ["DAYTAPE_BUNDLE_PREFIX"]
    validate_info(phone, watch, bundle, os.environ["TF_BUILD_NUMBER"], os.environ["GOOGLE_CLIENT_ID"])
    expanded = root / "verified-core-export"
    if expanded.exists():
        fail("The core verification directory must be fresh.")
    checked(["ditto", "-x", "-k", str(packages[0]), str(expanded)], "Core IPA extraction")
    apps = list((expanded / "Payload").glob("*.app"))
    watches = list((apps[0] / "Watch").glob("*.app")) if len(apps) == 1 else []
    if len(apps) != 1 or len(watches) != 1:
        fail("The extracted core IPA must contain exactly the iPhone and Watch apps.")
    for label, app, identifier in [("iPhone", apps[0], bundle), ("Watch", watches[0], bundle + ".watchkitapp")]:
        checked(["codesign", "--verify", "--deep", "--strict", str(app)], label + " core signature verification")
        try:
            signature = plistlib.loads(checked(["codesign", "--display", "--entitlements", "-", "--xml", str(app)], label + " core signature inspection"))
            profile = plistlib.loads(checked(["security", "cms", "-D", "-i", str(app / "embedded.mobileprovision")], label + " core profile inspection"))
        except (plistlib.InvalidFileException, ValueError):
            fail(label + " core signing metadata is invalid.")
        validate_signing(signature, profile, identifier, os.environ["APPLE_TEAM_ID"])
    print("Verified core testing IPA: two real App Store distribution signatures, no Widgets, no claimed App Group or HealthKit.")


if __name__ == "__main__":
    try:
        main()
    except (CoreVerificationError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print("Core export verification failed: " + (str(error) if isinstance(error, CoreVerificationError) else "invalid private package or configuration"), file=sys.stderr)
        raise SystemExit(1)
