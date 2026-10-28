#!/bin/bash
# Run only on a disposable GitHub-hosted macOS runner. Never enable shell tracing.
set +x
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

fail() { printf '%s\n' "TestFlight: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail 'A macOS host with full Xcode is required.'
[[ "${GITHUB_ACTIONS:-}" == true && "${GITHUB_REF:-}" == refs/heads/main ]] || fail 'Run the manual TestFlight workflow on main.'
[[ -n "${RUNNER_TEMP:-}" ]] || fail 'RUNNER_TEMP is required.'
export APPLE_SIGNING_STYLE="${APPLE_SIGNING_STYLE:-automatic}"
export TF_BUILD_MODE="${TF_BUILD_MODE:-google-drive}"
export TF_FEATURE_SET="${TF_FEATURE_SET:-full}"
case "$TF_FEATURE_SET" in
  full) export DAYTAPE_APP_GROUP="${DAYTAPE_APP_GROUP:-group.${DAYTAPE_BUNDLE_PREFIX:-}}" ;;
  core-testing)
    [[ "$APPLE_SIGNING_STYLE" == automatic ]] || fail 'The explicit core-testing fallback supports automatic signing only.'
    export DAYTAPE_APP_GROUP=
    printf '%s\n' 'CORE TESTING VARIANT: health association and widgets are omitted. Recording, synchronization, transcription and AI remain available.'
    ;;
  *) fail 'TF_FEATURE_SET must be full or core-testing.' ;;
esac
case "$TF_BUILD_MODE" in
  google-drive) printf '%s\n' 'Build mode: Google Drive backup. A real Google iOS OAuth client is required.' ;;
  local-recording)
    # This existing sentinel makes DriveConnection.configured false at runtime.
    export GOOGLE_CLIENT_ID=configure.apps.googleusercontent.com
    printf '%s\n' 'Build mode: local recording only. No Google Drive upload or cloud-based local cleanup; recordings remain on the iPhone.'
    ;;
  *) fail 'TF_BUILD_MODE must be google-drive or local-recording.' ;;
esac

# Validate names and values without printing credentials or decoded material.
python3 - <<'PY'
import base64
import binascii
import os
import re
import uuid

required = ['APPLE_TEAM_ID', 'DAYTAPE_BUNDLE_PREFIX',
            'APP_STORE_CONNECT_API_KEY_ID', 'APP_STORE_CONNECT_API_ISSUER_ID',
            'APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64']
if os.environ['TF_BUILD_MODE'] == 'google-drive':
    required.append('GOOGLE_CLIENT_ID')
style = os.environ['APPLE_SIGNING_STYLE']
if style not in ('automatic', 'manual'):
    raise SystemExit('APPLE_SIGNING_STYLE must be automatic or manual.')
if style == 'manual':
    required += ['APPLE_DISTRIBUTION_P12_BASE64', 'APPLE_DISTRIBUTION_P12_PASSWORD',
                 'APPLE_PROVISION_PROFILE_IOS_BASE64', 'APPLE_PROVISION_PROFILE_WATCH_BASE64',
                 'APPLE_PROVISION_PROFILE_IOS_WIDGET_BASE64', 'APPLE_PROVISION_PROFILE_WATCH_WIDGET_BASE64']
missing = [name for name in required if not os.environ.get(name, '').strip()]
if missing:
    raise SystemExit('Configure these GitHub Actions secrets/variables first: ' + ', '.join(missing))
patterns = {
    'APPLE_TEAM_ID': r'[A-Z0-9]{10}',
    'DAYTAPE_BUNDLE_PREFIX': r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}',
    'APP_STORE_CONNECT_API_KEY_ID': r'[A-Z0-9]{10}',
}
if os.environ['TF_FEATURE_SET'] == 'full':
    patterns['DAYTAPE_APP_GROUP'] = r'group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){1,}'
elif os.environ['DAYTAPE_APP_GROUP']:
    raise SystemExit('The core-testing variant must have no configured App Group.')
if os.environ['TF_BUILD_MODE'] == 'google-drive':
    patterns['GOOGLE_CLIENT_ID'] = r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com'
for name, pattern in patterns.items():
    if not re.fullmatch(pattern, os.environ[name]):
        raise SystemExit('Invalid or placeholder value for ' + name)
try:
    uuid.UUID(os.environ['APP_STORE_CONNECT_API_ISSUER_ID'])
except ValueError:
    raise SystemExit('APP_STORE_CONNECT_API_ISSUER_ID must be a UUID.')
for name in required:
    if name.endswith('_BASE64'):
        try:
            decoded = base64.b64decode(''.join(os.environ[name].split()), validate=True)
        except (ValueError, binascii.Error):
            raise SystemExit('Invalid base64 in ' + name)
        if not decoded:
            raise SystemExit('Empty decoded value in ' + name)
        if name == 'APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64' and b'-----BEGIN PRIVATE KEY-----' not in decoded:
            raise SystemExit('The App Store Connect API secret must contain the downloaded .p8 private key.')
print('Required configuration is present for build mode ' + os.environ['TF_BUILD_MODE'] + '.')
PY

# Generate an explicit variant in this disposable checkout; default/full retains four targets.
python3 Scripts/generate_project.py --feature-set "$TF_FEATURE_SET"

# Reject missing or transparent store icons before the full build and upload.
# Asset catalogs compile the same opaque 1024px source for both app platforms.
python3 - <<'PY'
import json
import struct
from pathlib import Path

for folder, platform in [('Phone', 'ios'), ('Watch', 'watchos')]:
    catalog = Path(folder) / 'Assets.xcassets/AppIcon.appiconset'
    contents = json.loads((catalog / 'Contents.json').read_text(encoding='utf-8'))
    entries = [entry for entry in contents.get('images', [])
               if entry.get('idiom') == 'universal' and entry.get('platform') == platform
               and entry.get('size') == '1024x1024']
    if len(entries) != 1 or not entries[0].get('filename'):
        raise SystemExit(folder + ' needs one named universal 1024x1024 AppIcon source.')
    icon = (catalog / entries[0]['filename']).resolve()
    if not icon.is_relative_to(catalog.resolve()) or not icon.is_file():
        raise SystemExit(folder + ' AppIcon source is missing or outside its asset catalog.')
    data = icon.read_bytes()
    if len(data) < 33 or data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR':
        raise SystemExit(folder + ' AppIcon must be a valid PNG.')
    width, height, depth, color = struct.unpack('>IIBB', data[16:26])
    if (width, height, depth, color) != (1024, 1024, 8, 2):
        raise SystemExit(folder + ' AppIcon must be 1024x1024, 8-bit RGB with no alpha channel.')
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if kind == b'tRNS':
            raise SystemExit(folder + ' AppIcon must not contain PNG transparency.')
        offset += length + 12
        if kind == b'IEND':
            break
    print(folder + ' AppIcon source is present, opaque RGB, and 1024x1024.')
PY

# Since April 28, 2026 Apple requires Xcode 26+ and current platform SDKs
# for App Store Connect uploads. Deployment targets may remain iOS 17/Watch 10.
python3 - <<'PY'
import re
import subprocess

checks = [('Xcode', ['xcodebuild', '-version'], r'Xcode (\d+(?:\.\d+)*)'),
          ('iOS SDK', ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], r'(\d+(?:\.\d+)*)'),
          ('watchOS SDK', ['xcrun', '--sdk', 'watchos', '--show-sdk-version'], r'(\d+(?:\.\d+)*)')]
for name, command, pattern in checks:
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    match = re.search(pattern, result.stdout)
    if not match or tuple(map(int, match.group(1).split('.'))) < (26, 0):
        raise SystemExit(name + ' 26 or newer is required for this TestFlight upload.')
    print(name, match.group(1))
PY

mkdir -p artifacts
# Tests and Swift packages do not inherit deployment credentials.
env -u APP_STORE_CONNECT_API_KEY_ID -u APP_STORE_CONNECT_API_ISSUER_ID \
  -u APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 -u APPLE_DISTRIBUTION_P12_BASE64 \
  -u APPLE_DISTRIBUTION_P12_PASSWORD -u APPLE_PROVISION_PROFILE_IOS_BASE64 \
  -u APPLE_PROVISION_PROFILE_WATCH_BASE64 -u APPLE_PROVISION_PROFILE_IOS_WIDGET_BASE64 \
  -u APPLE_PROVISION_PROFILE_WATCH_WIDGET_BASE64 bash Scripts/ci_build.sh

TF_PRIVATE_DIR="$(mktemp -d "${RUNNER_TEMP%/}/daytape-testflight.XXXXXX")"
export TF_PRIVATE_DIR
TF_KEYCHAIN="${TF_PRIVATE_DIR}/signing.keychain-db"
TF_KEYCHAIN_CREATED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$TF_KEYCHAIN_CREATED" == 1 ]]; then
    security delete-keychain "$TF_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  python3 - <<'PY' || true
import os
import shutil
from pathlib import Path
root = Path(os.environ['TF_PRIVATE_DIR'])
manifest = root / 'installed-profiles.txt'
if manifest.exists():
    for name in manifest.read_text().splitlines():
        Path(name).unlink(missing_ok=True)
shutil.rmtree(root)
PY
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

python3 - <<'PY'
import base64
import os
from pathlib import Path
root = Path(os.environ['TF_PRIVATE_DIR'])
files = {'APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64': 'AuthKey.p8'}
if os.environ['APPLE_SIGNING_STYLE'] == 'manual':
    files.update(APPLE_DISTRIBUTION_P12_BASE64='distribution.p12',
                 APPLE_PROVISION_PROFILE_IOS_BASE64='iphone.mobileprovision',
                 APPLE_PROVISION_PROFILE_WATCH_BASE64='watch.mobileprovision',
                 APPLE_PROVISION_PROFILE_IOS_WIDGET_BASE64='iphone-widget.mobileprovision',
                 APPLE_PROVISION_PROFILE_WATCH_WIDGET_BASE64='watch-widget.mobileprovision')
for name, filename in files.items():
    output = root / filename
    output.write_bytes(base64.b64decode(''.join(os.environ[name].split()), validate=True))
    output.chmod(0o600)
PY
openssl pkey -in "$TF_PRIVATE_DIR/AuthKey.p8" -noout >/dev/null 2>&1 || fail 'The API private key could not be read.'

if [[ "$APPLE_SIGNING_STYLE" == manual ]]; then
  for profile_kind in iphone watch iphone-widget watch-widget; do
    security cms -D -i "$TF_PRIVATE_DIR/${profile_kind}.mobileprovision" > "$TF_PRIVATE_DIR/${profile_kind}-profile.plist"
  done
  python3 - <<'PY'
import datetime
import hashlib
import os
import plistlib
import shutil
import uuid
from pathlib import Path

root = Path(os.environ['TF_PRIVATE_DIR'])
team = os.environ['APPLE_TEAM_ID']
bundle = os.environ['DAYTAPE_BUNDLE_PREFIX']
now = datetime.datetime.now(datetime.timezone.utc)
profiles = {}
certificates = {}
for kind, identifier in [('iphone', bundle), ('watch', bundle + '.watchkitapp'),
                         ('iphone-widget', bundle + '.widgets'), ('watch-widget', bundle + '.watchkitapp.widgets')]:
    with (root / (kind + '-profile.plist')).open('rb') as stream:
        profile = plistlib.load(stream)
    entitlement = profile.get('Entitlements', {})
    expiry = profile.get('ExpirationDate')
    if expiry is None or expiry.replace(tzinfo=datetime.timezone.utc) <= now:
        raise SystemExit(kind + ' provisioning profile has expired.')
    if team not in profile.get('TeamIdentifier', []):
        raise SystemExit(kind + ' provisioning profile belongs to a different Apple team.')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    app_id = entitlement.get('application-identifier', '')
    if not any(app_id == prefix + '.' + identifier for prefix in prefixes):
        raise SystemExit(kind + ' provisioning profile does not match the configured bundle identifier.')
    if (profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
            or entitlement.get('get-task-allow') or not entitlement.get('beta-reports-active')):
        raise SystemExit(kind + ' profile must be an App Store Connect distribution profile.')
    if os.environ['DAYTAPE_APP_GROUP'] not in entitlement.get('com.apple.security.application-groups', []):
        raise SystemExit(kind + ' profile must include the configured shared App Group.')
    if kind == 'iphone' and not entitlement.get('com.apple.developer.healthkit'):
        raise SystemExit('The iPhone provisioning profile must include HealthKit for opt-in health context.')
    try:
        profile_uuid = str(uuid.UUID(profile['UUID'])).upper()
    except (KeyError, ValueError):
        raise SystemExit(kind + ' profile has an invalid UUID.')
    profiles[kind] = profile_uuid
    certificates[kind] = [hashlib.sha1(cert).hexdigest().upper()
                          for cert in profile.get('DeveloperCertificates', [])]
    for directory in [Path.home() / 'Library/MobileDevice/Provisioning Profiles',
                      Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles']:
        directory.mkdir(parents=True, exist_ok=True)
        destination = directory / (profile_uuid + '.mobileprovision')
        if destination.exists():
            raise SystemExit('A profile with the same UUID already exists; use a fresh runner.')
        # Record first so a copy interrupted by cancellation is still cleaned up.
        with (root / 'installed-profiles.txt').open('a') as stream:
            stream.write(str(destination) + '\n')
        shutil.copyfile(root / (kind + '.mobileprovision'), destination)
        destination.chmod(0o600)
with (root / 'profiles.plist').open('wb') as stream:
    plistlib.dump(profiles, stream)
with (root / 'certificates.plist').open('wb') as stream:
    plistlib.dump(certificates, stream)
print('All four App Store provisioning profiles match the apps, widgets, shared group and team.')
PY
  TF_KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
  printf '::add-mask::%s\n' "$TF_KEYCHAIN_PASSWORD"
  security create-keychain -p "$TF_KEYCHAIN_PASSWORD" "$TF_KEYCHAIN"
  TF_KEYCHAIN_CREATED=1
  security set-keychain-settings -lut 21600 "$TF_KEYCHAIN"
  security unlock-keychain -p "$TF_KEYCHAIN_PASSWORD" "$TF_KEYCHAIN"
  security import "$TF_PRIVATE_DIR/distribution.p12" -P "$APPLE_DISTRIBUTION_P12_PASSWORD" \
    -A -t cert -f pkcs12 -k "$TF_KEYCHAIN" >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
    -k "$TF_KEYCHAIN_PASSWORD" "$TF_KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$TF_KEYCHAIN" login.keychain-db
  security find-identity -v -p codesigning "$TF_KEYCHAIN" > "$TF_PRIVATE_DIR/identities.txt"
  python3 - <<'PY'
import os
import plistlib
import re
from pathlib import Path
root = Path(os.environ['TF_PRIVATE_DIR'])
with (root / 'certificates.plist').open('rb') as stream:
    certificates = plistlib.load(stream)
identities = set(re.findall(r'([A-Fa-f0-9]{40})\s+"Apple Distribution:',
                            (root / 'identities.txt').read_text()))
shared = set.intersection(*(set(value) for value in certificates.values()))
if not shared.intersection(identity.upper() for identity in identities):
    raise SystemExit('The P12 needs a valid Apple Distribution identity with its private key, included in all four profiles.')
PY
fi

export TF_BUILD_NUMBER="${GITHUB_RUN_NUMBER:?}.${GITHUB_RUN_ATTEMPT:?}"
python3 - <<'PY'
import os
import plistlib
from pathlib import Path
root = Path(os.environ['TF_PRIVATE_DIR'])
style = os.environ['APPLE_SIGNING_STYLE']
client = os.environ['GOOGLE_CLIENT_ID']
lines = [
    'DAYTAPE_BUNDLE_PREFIX = ' + os.environ['DAYTAPE_BUNDLE_PREFIX'],
    'DAYTAPE_APP_GROUP = ' + os.environ['DAYTAPE_APP_GROUP'],
    'DEVELOPMENT_TEAM = ' + os.environ['APPLE_TEAM_ID'],
    'GOOGLE_CLIENT_ID = ' + client,
    'GOOGLE_REVERSED_CLIENT_ID = ' + '.'.join(reversed(client.split('.'))),
    'DAYTAPE_HEALTHKIT_FLAG = ' + ('DAYTAPE_HEALTHKIT' if os.environ['TF_FEATURE_SET'] == 'full' else ''),
    'DAYTAPE_ENTITLEMENTS = ' + ('Phone/DayTape.entitlements' if os.environ['TF_FEATURE_SET'] == 'full' else 'Shared/CoreTesting.entitlements'),
    'CODE_SIGN_STYLE = ' + style.capitalize(),
]
options = dict(method='app-store-connect', signingStyle=style,
               teamID=os.environ['APPLE_TEAM_ID'], uploadSymbols=True,
               manageAppVersionAndBuildNumber=False)
if style == 'manual':
    with (root / 'profiles.plist').open('rb') as stream:
        profiles = plistlib.load(stream)
    lines += ['CODE_SIGN_IDENTITY = Apple Distribution',
              'DAYTAPE_PROFILE_IOS = ' + profiles['iphone'],
              'DAYTAPE_PROFILE_WATCH = ' + profiles['watch'],
              'DAYTAPE_PROFILE_IOS_WIDGET = ' + profiles['iphone-widget'],
              'DAYTAPE_PROFILE_WATCH_WIDGET = ' + profiles['watch-widget']]
    bundle = os.environ['DAYTAPE_BUNDLE_PREFIX']
    options['signingCertificate'] = 'Apple Distribution'
    options['provisioningProfiles'] = {bundle: profiles['iphone'], bundle + '.watchkitapp': profiles['watch'],
        bundle + '.widgets': profiles['iphone-widget'], bundle + '.watchkitapp.widgets': profiles['watch-widget']}
(root / 'Signing.xcconfig').write_text('\n'.join(lines) + '\n', encoding='utf-8')
for destination in ['export', 'upload']:
    with (root / (destination + '.plist')).open('wb') as stream:
        plistlib.dump(dict(options, destination=destination), stream)
PY

# Keep raw build output private. It can contain expanded signing settings.
# Preserve redacted diagnostics only; never upload profiles, archives, P12 or P8.
run_private() {
  local label="$1"
  shift
  local status=0
  "$@" > "$TF_PRIVATE_DIR/${label}.log" 2>&1 || status=$?
  TF_LOG_LABEL="$label" python3 - <<'PY'
import os
from pathlib import Path
label = os.environ['TF_LOG_LABEL']
text = (Path(os.environ['TF_PRIVATE_DIR']) / (label + '.log')).read_text(errors='replace')
for name in ['APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64', 'APPLE_DISTRIBUTION_P12_BASE64',
             'APPLE_DISTRIBUTION_P12_PASSWORD', 'APPLE_PROVISION_PROFILE_IOS_BASE64',
             'APPLE_PROVISION_PROFILE_WATCH_BASE64', 'APP_STORE_CONNECT_API_KEY_ID',
             'APPLE_PROVISION_PROFILE_IOS_WIDGET_BASE64', 'APPLE_PROVISION_PROFILE_WATCH_WIDGET_BASE64',
             'APP_STORE_CONNECT_API_ISSUER_ID']:
    value = os.environ.get(name, '')
    if value:
        text = text.replace(value, '[REDACTED]')
text = text.replace(os.environ['TF_PRIVATE_DIR'], '[PRIVATE_RUNNER_DIRECTORY]')
(Path('artifacts') / (label + '.log')).write_text(text)
print('\n'.join(text.splitlines()[-35:]))
PY
  [[ "$status" == 0 ]] || fail "${label} failed; see the redacted diagnostics artifact."
}

authentication=(-authenticationKeyPath "$TF_PRIVATE_DIR/AuthKey.p8"
  -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID"
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID")
archive_options=()
export_options=()
if [[ "$APPLE_SIGNING_STYLE" == automatic ]]; then
  # A fresh distribution-only team may have no registered development devices.
  # Build the archive without signing or provisioning; App Store export below
  # obtains distribution profiles and cloud signing using the API key.
  archive_options=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
  export_options=(-allowProvisioningUpdates "${authentication[@]}")
  printf '%s\n' 'Archiving without signing. App Store distribution signing will occur during export.'
fi
run_private archive xcodebuild \
  -project DayTape.xcodeproj -scheme DayTape -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$TF_PRIVATE_DIR/DayTape.xcarchive" \
  -derivedDataPath "$TF_PRIVATE_DIR/DerivedData" \
  -clonedSourcePackagesDirPath .build/SourcePackages \
  -xcconfig "$TF_PRIVATE_DIR/Signing.xcconfig" \
  ${archive_options[@]+"${archive_options[@]}"} CURRENT_PROJECT_VERSION="$TF_BUILD_NUMBER" \
  CODE_SIGN_STYLE="$(python3 -c 'import os; print(os.environ["APPLE_SIGNING_STYLE"].capitalize())')" \
  archive

if [[ "$APPLE_SIGNING_STYLE" == automatic && "$TF_FEATURE_SET" == full ]]; then
  # Export inherits capability claims from archive signatures. Seed private ad-hoc
  # signatures first; the export step must still produce real distribution signing.
  run_private preserve-entitlements python3 Scripts/preserve_archive_entitlements.py \
    --archive "$TF_PRIVATE_DIR/DayTape.xcarchive"
fi

run_private export xcodebuild -exportArchive \
  -archivePath "$TF_PRIVATE_DIR/DayTape.xcarchive" \
  -exportPath "$TF_PRIVATE_DIR/export" -exportOptionsPlist "$TF_PRIVATE_DIR/export.plist" \
  ${export_options[@]+"${export_options[@]}"}

# Verify package metadata, then the actual distribution signatures/profiles.
if [[ "$TF_FEATURE_SET" == core-testing ]]; then
  run_private verify-core-export python3 Scripts/verify_core_export.py
else
python3 - <<'PY'
import datetime
import os
import plistlib
import subprocess
import zipfile
from pathlib import Path
root = Path(os.environ['TF_PRIVATE_DIR'])
packages = list((root / 'export').glob('*.ipa'))
if len(packages) != 1:
    raise SystemExit('Expected exactly one exported IPA.')
with zipfile.ZipFile(packages[0]) as package:
    names = package.namelist()
    phones = [n for n in names if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
    if len(phones) != 1:
        raise SystemExit('The IPA does not contain exactly one iPhone application.')
    phone = plistlib.loads(package.read(phones[0]))
    watches = [n for n in names if '/Watch/' in n and n.count('/') == 4 and n.endswith('.app/Info.plist')]
    if len(watches) != 1:
        raise SystemExit('The IPA must contain the companion Watch application.')
    watch = plistlib.loads(package.read(watches[0]))
    widget_infos = []
    for label, parent in [('iPhone widget', phones[0]), ('Watch widget', watches[0])]:
        prefix = parent[:-len('Info.plist')] + 'PlugIns/'
        matches = [name for name in names if name.startswith(prefix) and
                   name.count('/') == prefix.count('/') + 1 and name.endswith('.appex/Info.plist')]
        if len(matches) != 1:
            raise SystemExit('The IPA must embed exactly one ' + label + ' extension.')
        widget_infos.append(plistlib.loads(package.read(matches[0])))
bundle = os.environ['DAYTAPE_BUNDLE_PREFIX']
if phone.get('CFBundleIdentifier') != bundle or watch.get('CFBundleIdentifier') != bundle + '.watchkitapp':
    raise SystemExit('The exported bundle identifiers do not match the signing configuration.')
if watch.get('WKCompanionAppBundleIdentifier') != bundle:
    raise SystemExit('The Watch companion bundle identifier is incorrect.')
for info, suffix in [(phone, ''), (watch, '.watchkitapp'),
                     (widget_infos[0], '.widgets'), (widget_infos[1], '.watchkitapp.widgets')]:
    if info.get('CFBundleIdentifier') != bundle + suffix:
        raise SystemExit('An exported app/widget bundle identifier does not match its signing configuration.')
    if info.get('CFBundleVersion') != os.environ['TF_BUILD_NUMBER']:
        raise SystemExit('All four app/widget build numbers must match this workflow run.')
    if info.get('CFBundleShortVersionString') != '0.5.0':
        raise SystemExit('All four app/widget versions must be 0.5.0.')
    if info.get('DayTapeAppGroup') != os.environ['DAYTAPE_APP_GROUP']:
        raise SystemExit('An exported app/widget is missing the configured shared App Group.')
for info in widget_infos:
    if info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension':
        raise SystemExit('An embedded extension is not a WidgetKit extension.')
if phone.get('GIDClientID') != os.environ['GOOGLE_CLIENT_ID']:
    raise SystemExit('The exported client configuration does not match the selected build mode.')
schemes = [s for entry in phone.get('CFBundleURLTypes', []) for s in entry.get('CFBundleURLSchemes', [])]
if '.'.join(reversed(os.environ['GOOGLE_CLIENT_ID'].split('.'))) not in schemes:
    raise SystemExit('The Google OAuth callback URL scheme is missing.')
if 'daytape' not in schemes:
    raise SystemExit('The DayTape app URL scheme is missing.')

def checked(command, label):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        # Tool diagnostics may include paths; never dump profile payloads.
        detail = result.stderr.decode(errors='replace').replace(str(root), '[PRIVATE_RUNNER_DIRECTORY]')
        raise SystemExit(label + ' failed. ' + detail[-1600:])
    return result.stdout

# ditto preserves bundle permissions and symlinks, unlike ZipFile.extractall.
expanded = root / 'verified-export'
checked(['ditto', '-x', '-k', str(packages[0]), str(expanded)], 'IPA extraction')
apps = list((expanded / 'Payload').glob('*.app'))
if len(apps) != 1:
    raise SystemExit('The expanded IPA must contain one iPhone app.')
watch_apps = list((apps[0] / 'Watch').glob('*.app'))
if len(watch_apps) != 1:
    raise SystemExit('The expanded iPhone app must embed one Watch app.')
phone_widgets = list((apps[0] / 'PlugIns').glob('*.appex'))
watch_widgets = list((watch_apps[0] / 'PlugIns').glob('*.appex'))
if len(phone_widgets) != 1 or len(watch_widgets) != 1:
    raise SystemExit('The expanded IPA must embed one iPhone widget and one Watch widget.')
team = os.environ['APPLE_TEAM_ID']
now = datetime.datetime.now(datetime.timezone.utc)
for label, app, identifier in [('iPhone', apps[0], bundle),
                               ('Watch', watch_apps[0], bundle + '.watchkitapp'),
                               ('iPhone widget', phone_widgets[0], bundle + '.widgets'),
                               ('Watch widget', watch_widgets[0], bundle + '.watchkitapp.widgets')]:
    checked(['codesign', '--verify', '--deep', '--strict', str(app)], label + ' code signature verification')
    try:
        signature = plistlib.loads(checked(
            ['codesign', '--display', '--entitlements', '-', '--xml', str(app)],
            label + ' signed entitlements inspection'))
        profile = plistlib.loads(checked(
            ['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')],
            label + ' embedded profile inspection'))
    except plistlib.InvalidFileException:
        raise SystemExit(label + ' signing metadata is not a valid property list.')
    if (signature.get('com.apple.developer.team-identifier') != team
            or team not in profile.get('TeamIdentifier', [])):
        raise SystemExit(label + ' was not signed for the configured Apple team.')
    profile_entitlements = profile.get('Entitlements', {})
    group = os.environ['DAYTAPE_APP_GROUP']
    signature_group = group in signature.get('com.apple.security.application-groups', [])
    profile_group = group in profile_entitlements.get('com.apple.security.application-groups', [])
    print(label + ' distribution capabilities: signature_app_group=' + str(signature_group).lower()
          + ', profile_app_group=' + str(profile_group).lower()
          + ', signature_healthkit=' + str(bool(signature.get('com.apple.developer.healthkit'))).lower()
          + ', profile_healthkit=' + str(bool(profile_entitlements.get('com.apple.developer.healthkit'))).lower())
    if not signature_group:
        raise SystemExit(label + ' distribution SIGNATURE is missing the required shared App Group.')
    if not profile_group:
        raise SystemExit(label + ' distribution PROFILE does not authorize the required shared App Group.')
    if label == 'iPhone':
        for key, capability in [('com.apple.developer.healthkit', 'HealthKit'),
                                ('com.apple.developer.healthkit.background-delivery', 'HealthKit background delivery')]:
            if not signature.get(key):
                raise SystemExit('The iPhone distribution SIGNATURE is missing ' + capability + '.')
            if not profile_entitlements.get(key):
                raise SystemExit('The iPhone distribution PROFILE does not authorize ' + capability + '.')
    app_id = signature.get('application-identifier')
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    if (not any(app_id == prefix + '.' + identifier for prefix in prefixes)
            or profile_entitlements.get('application-identifier') != app_id):
        raise SystemExit(label + ' signed application identifier does not match its bundle and profile.')
    expiry = profile.get('ExpirationDate')
    if expiry is None or expiry.replace(tzinfo=datetime.timezone.utc) <= now:
        raise SystemExit(label + ' embedded provisioning profile has expired.')
    if (signature.get('get-task-allow') or profile_entitlements.get('get-task-allow')
            or 'ProvisionedDevices' in profile or profile.get('ProvisionsAllDevices')
            or not profile_entitlements.get('beta-reports-active')):
        raise SystemExit(label + ' must have App Store distribution signing, without development/debugger access.')
print('Verified all four App Store distribution signatures, teams, groups, application identifiers and embedded profiles for '
      + os.environ['TF_BUILD_MODE'] + '.')
PY
fi

# Xcode's upload destination uses API-key authentication and the same archive.
# It uploads a build only: no App Store release, tester invitation or beta review.
run_private upload xcodebuild -exportArchive \
  -archivePath "$TF_PRIVATE_DIR/DayTape.xcarchive" \
  -exportPath "$TF_PRIVATE_DIR/upload" \
  -exportOptionsPlist "$TF_PRIVATE_DIR/upload.plist" \
  -allowProvisioningUpdates "${authentication[@]}"
printf '%s\n' 'Upload accepted by App Store Connect. Apple processing must finish before TestFlight can install the build.'
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf 'Uploaded DayTape build **%s** (%s) to App Store Connect. Apple processing is still required; check TestFlight for the final status.\n' \
    "$TF_BUILD_NUMBER" "$TF_BUILD_MODE" >> "$GITHUB_STEP_SUMMARY"
  if [[ "$TF_FEATURE_SET" == core-testing ]]; then
    printf '\n**Core testing variant:** health association and widgets are omitted. Recording, synchronization, transcription, AI, marks, location, speaker identification, export and desktop access remain available. This is not a full-capability acceptance build.\n' >> "$GITHUB_STEP_SUMMARY"
  fi
  if [[ "$TF_BUILD_MODE" == local-recording ]]; then
    printf '\nLocal recording only: Google Drive upload and cloud-based local cleanup are unavailable. Recordings remain on the iPhone.\n' \
      >> "$GITHUB_STEP_SUMMARY"
  fi
fi
