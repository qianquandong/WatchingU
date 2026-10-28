#!/usr/bin/env python3
"""Seed capability claims in a private unsigned archive before Xcode cloud signing.

The temporary ad-hoc signatures cannot be distributed. Xcode must replace them
with App Store signatures, which testflight.sh independently verifies afterward.
Unsigned export loses claims: https://github.com/tauri-apps/tauri/issues/15663
"""
from __future__ import annotations

import argparse
import os
import platform
import plistlib
import re
import subprocess
import sys
from pathlib import Path

GROUP_KEY = "com.apple.security.application-groups"
HEALTH_KEY = "com.apple.developer.healthkit"
HEALTH_BACKGROUND_KEY = "com.apple.developer.healthkit.background-delivery"


class PreservationError(Exception):
    """Deliberately bounded diagnostics, without credentials or profile payloads."""


def inside(path, parent, label):
    resolved = path.resolve()
    if not resolved.is_relative_to(parent.resolve()):
        raise PreservationError(label + " is outside the expected private archive/source directory.")
    return resolved


def read_plist(path, label):
    try:
        if not path.is_file() or path.stat().st_size > 512 * 1024:
            raise ValueError()
        value = plistlib.loads(path.read_bytes())
        if not isinstance(value, dict):
            raise ValueError()
        return value
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise PreservationError(label + " is missing or is not a valid bounded property list.") from None


def expand_entitlements(value, group):
    if isinstance(value, str):
        expanded = value.replace("$(DAYTAPE_APP_GROUP)", group)
        if "$" in expanded:
            raise PreservationError("An entitlement contains an unsupported or unexpanded variable.")
        return expanded
    if isinstance(value, list):
        return [expand_entitlements(item, group) for item in value]
    if isinstance(value, dict):
        if any(not isinstance(key, str) or "$" in key for key in value):
            raise PreservationError("An entitlement has an invalid or variable property key.")
        return {key: expand_entitlements(item, group) for key, item in value.items()}
    if isinstance(value, (bool, int, float, bytes)):
        return value
    raise PreservationError("An entitlement contains an unsupported property-list value.")


def one_bundle(parent, suffix, label):
    values = list(parent.glob("*" + suffix))
    if len(values) != 1 or not values[0].is_dir():
        raise PreservationError("The archive must contain exactly one " + label + ".")
    return values[0]


def checked(runner, command, label):
    try:
        result = runner(command, capture_output=True, check=False)
    except OSError:
        raise PreservationError(label + " could not start codesign.") from None
    if result.returncode:
        # Do not echo subprocess payloads or raw entitlements into build logs.
        raise PreservationError(label + " failed (codesign exit " + str(result.returncode) + ").")
    return result.stdout


def inspect(runner, bundle, label):
    data = checked(runner, ["codesign", "--display", "--entitlements", ":-", str(bundle)],
                   label + " temporary entitlement inspection")
    try:
        result = plistlib.loads(data)
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except (ValueError, plistlib.InvalidFileException):
        raise PreservationError(label + " temporary signature has no readable entitlement dictionary.") from None


def preserve(archive, source_root, private_dir, bundle_prefix, group, runner=subprocess.run):
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}", bundle_prefix):
        raise PreservationError("Invalid release bundle prefix.")
    if not re.fullmatch(r"group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){1,}", group):
        raise PreservationError("Invalid or unexpanded release App Group.")
    if not private_dir.is_dir():
        raise PreservationError("The private signing directory is missing.")
    archive = inside(archive, private_dir, "Archive")
    if archive.suffix != ".xcarchive" or not archive.is_dir():
        raise PreservationError("Expected a private .xcarchive directory.")
    source_root = source_root.resolve()
    phone = one_bundle(archive / "Products/Applications", ".app", "iPhone app")
    watch = one_bundle(phone / "Watch", ".app", "Watch app")
    phone_widget = one_bundle(phone / "PlugIns", ".appex", "iPhone widget")
    watch_widget = one_bundle(watch / "PlugIns", ".appex", "Watch widget")
    # Each inner signature must exist before its containing bundle is sealed.
    specs = [
        ("Watch widget", watch_widget, ".watchkitapp.widgets", "Widgets/DayTape.entitlements", False),
        ("Watch", watch, ".watchkitapp", "Watch/DayTape.entitlements", False),
        ("iPhone widget", phone_widget, ".widgets", "Widgets/DayTape.entitlements", False),
        ("iPhone", phone, "", "Phone/DayTape.entitlements", True),
    ]
    known_bundles = {inside(item[1], archive, item[0]) for item in specs}
    nested_bundles = {inside(path, archive, "Nested app/extension") for path in phone.rglob("*")
                      if path.suffix in (".app", ".appex") and path.is_dir()}
    if nested_bundles | {phone.resolve()} != known_bundles:
        raise PreservationError("The archive contains an unexpected nested app or extension.")
    prepared = []
    for label, path, suffix, relative_source, is_phone in specs:
        path = inside(path, archive, label)
        info = read_plist(inside(path / "Info.plist", archive, label + " Info.plist"), label + " Info.plist")
        if info.get("CFBundleIdentifier") != bundle_prefix + suffix:
            raise PreservationError(label + " bundle identifier does not match this release.")
        if info.get("DayTapeAppGroup") != group:
            raise PreservationError(label + " compiled App Group does not match this release.")
        executable = info.get("CFBundleExecutable")
        if (not isinstance(executable, str) or not executable or Path(executable).name != executable
                or not inside(path / executable, path, label + " executable").is_file()):
            raise PreservationError(label + " has no valid bundle executable.")
        if suffix.endswith(".widgets"):
            extension = info.get("NSExtension")
            if not isinstance(extension, dict) or extension.get("NSExtensionPointIdentifier") != "com.apple.widgetkit-extension":
                raise PreservationError(label + " is not a WidgetKit extension.")
        if suffix == ".watchkitapp" and info.get("WKCompanionAppBundleIdentifier") != bundle_prefix:
            raise PreservationError("The Watch app does not reference this iPhone companion.")
        source = inside(source_root / relative_source, source_root, label + " entitlement source")
        expected = expand_entitlements(read_plist(source, label + " entitlement source"), group)
        if expected.get(GROUP_KEY) != [group]:
            raise PreservationError(label + " entitlement source must claim exactly the configured App Group.")
        if is_phone:
            if expected.get(HEALTH_KEY) is not True or expected.get(HEALTH_BACKGROUND_KEY) is not True:
                raise PreservationError("The iPhone entitlement source must retain both HealthKit capabilities.")
        elif HEALTH_KEY in expected or HEALTH_BACKGROUND_KEY in expected:
            raise PreservationError(label + " must not acquire iPhone-only HealthKit capabilities.")
        prepared.append((label, path, expected, is_phone))
    # Validate all signing paths before modifying any binary, including symlink targets.
    nested_code = sorted({inside(path, archive, "Nested framework/library") for path in phone.rglob("*")
                          if (path.suffix == ".framework" and path.is_dir())
                          or (path.suffix == ".dylib" and path.is_file())},
                         key=lambda path: (-len(path.parts), str(path)))
    output = inside(private_dir / "archive-entitlements", private_dir, "Temporary entitlement directory")
    output.mkdir(mode=0o700, exist_ok=True)
    empty_path = inside(output / "nested-code.plist", private_dir, "Temporary empty entitlements")
    empty_path.write_bytes(plistlib.dumps({}))
    empty_path.chmod(0o600)
    for path in nested_code:
        checked(runner, ["codesign", "--force", "--sign", "-", "--timestamp=none",
                        "--entitlements", str(empty_path), "--generate-entitlement-der", str(path)],
                "Nested framework/library temporary signing")
    print("Prepared nested framework/library signatures with no capability claims:", len(nested_code))
    for index, (label, path, expected, is_phone) in enumerate(prepared):
        expanded_path = inside(output / (str(index) + ".plist"), private_dir, "Temporary expanded entitlements")
        expanded_path.write_bytes(plistlib.dumps(expected, sort_keys=True))
        expanded_path.chmod(0o600)
        checked(runner, ["codesign", "--force", "--sign", "-", "--timestamp=none",
                        "--entitlements", str(expanded_path), "--generate-entitlement-der", str(path)],
                label + " temporary signing")
        actual = inspect(runner, path, label)
        group_ok = actual.get(GROUP_KEY) == [group]
        health_ok = actual.get(HEALTH_KEY) is True
        background_ok = actual.get(HEALTH_BACKGROUND_KEY) is True
        print(label + " temporary capabilities: app_group=" + str(group_ok).lower()
              + ", healthkit=" + str(health_ok).lower() + ", health_background=" + str(background_ok).lower())
        if not group_ok or (is_phone and not (health_ok and background_ok)):
            raise PreservationError(label + " temporary signature did not retain required capabilities.")
        if any(actual.get(key) != value for key, value in expected.items()):
            raise PreservationError(label + " temporary signature changed a declared entitlement.")
    print("Preserved capabilities in four private ad-hoc archive signatures. App Store distribution signing is still required.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        if (platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
                or os.environ.get("GITHUB_REF") != "refs/heads/main"
                or os.environ.get("GITHUB_REPOSITORY") != "qianquandong/WatchingU"
                or os.environ.get("APPLE_SIGNING_STYLE") != "automatic"):
            raise PreservationError("Temporary archive signing is restricted to trusted main macOS automatic-signing CI.")
        private_dir = os.environ.get("TF_PRIVATE_DIR", "")
        if not private_dir:
            raise PreservationError("TF_PRIVATE_DIR is required.")
        preserve(args.archive, args.source_root, Path(private_dir),
                 os.environ.get("DAYTAPE_BUNDLE_PREFIX", ""), os.environ.get("DAYTAPE_APP_GROUP", ""))
    except (PreservationError, OSError) as error:
        # OS errors may contain file contents/paths; only controlled messages are public.
        message = str(error) if isinstance(error, PreservationError) else "Private archive file access failed."
        print("Archive entitlement preservation: " + message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
