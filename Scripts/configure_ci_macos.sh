#!/bin/bash
# Run this yourself on your Mac to write WatchingU's Actions configuration.
# Reads only the .p8 path you supply. Does not create keys or run a workflow.
set +x
set -euo pipefail
umask 077

fail() { printf '%s\n' "CI setup: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || fail 'Run this helper on your Mac.'
[[ "${GITHUB_ACTIONS:-}" != true ]] || fail 'This one-time helper is for your Mac, not a CI runner.'
[[ "$#" -le 4 ]] || fail 'Usage: bash Scripts/configure_ci_macos.sh /path/to/AuthKey_KEYID.p8 GOOGLE_IOS_CLIENT_ID [ISSUER_ID] [KEY_ID]'
for tool in gh python3 openssl; do
  command -v "$tool" >/dev/null 2>&1 || fail "Install ${tool} before running this helper."
done

REPOSITORY=qianquandong/WatchingU
# Pin every gh call to the intended host even if the Mac uses enterprise gh.
export GH_HOST=github.com
export APPLE_TEAM_ID="${APPLE_TEAM_ID:-GB24TMUMQ5}"
export DAYTAPE_BUNDLE_PREFIX="${DAYTAPE_BUNDLE_PREFIX:-com.aimanjack.daytape}"
export APP_STORE_CONNECT_API_KEY_ID="${4:-${APP_STORE_CONNECT_API_KEY_ID:-}}"
export APP_STORE_CONNECT_API_ISSUER_ID="${3:-${APP_STORE_CONNECT_API_ISSUER_ID:-}}"
KEY_PATH="${1:-}"
export GOOGLE_CLIENT_ID="${2:-}"
if [[ -z "$KEY_PATH" ]]; then
  [[ -t 0 ]] || fail 'Supply the path to the existing GitHub CI API key .p8 file.'
  read -r -p 'Path to the existing GitHub CI AuthKey .p8 file: ' KEY_PATH
fi
if [[ -z "$GOOGLE_CLIENT_ID" ]]; then
  [[ -t 0 ]] || fail 'Supply the real Google iOS OAuth client ID as the second argument.'
  read -r -p 'Google iOS OAuth client ID: ' GOOGLE_CLIENT_ID
fi
if [[ -z "$APP_STORE_CONNECT_API_KEY_ID" ]]; then
  key_filename="${KEY_PATH##*/}"
  if [[ "$key_filename" =~ ^AuthKey_([A-Z0-9]{10})\.p8$ ]]; then
    APP_STORE_CONNECT_API_KEY_ID="${BASH_REMATCH[1]}"
  else
    [[ -t 0 ]] || fail 'Supply APP_STORE_CONNECT_API_KEY_ID or use the original AuthKey_KEYID.p8 filename.'
    read -r -p 'App Store Connect API Key ID: ' APP_STORE_CONNECT_API_KEY_ID
  fi
fi
if [[ -z "$APP_STORE_CONNECT_API_ISSUER_ID" ]]; then
  [[ -t 0 ]] || fail 'Supply the App Store Connect Issuer ID as the third argument or APP_STORE_CONNECT_API_ISSUER_ID.'
  read -r -p 'App Store Connect API Issuer ID: ' APP_STORE_CONNECT_API_ISSUER_ID
fi

python3 - "$KEY_PATH" <<'PY'
import os
from pathlib import Path
import re
import sys
import uuid

patterns = {
    'APPLE_TEAM_ID': r'[A-Z0-9]{10}',
    'DAYTAPE_BUNDLE_PREFIX': r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}',
    'GOOGLE_CLIENT_ID': r'[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com',
    'APP_STORE_CONNECT_API_KEY_ID': r'[A-Z0-9]{10}',
}
for name, pattern in patterns.items():
    if not re.fullmatch(pattern, os.environ[name]):
        raise SystemExit('Invalid or placeholder value for ' + name)
try:
    uuid.UUID(os.environ['APP_STORE_CONNECT_API_ISSUER_ID'])
except ValueError:
    raise SystemExit('APP_STORE_CONNECT_API_ISSUER_ID must be a UUID.')
key = Path(sys.argv[1]).expanduser()
if not key.is_file() or key.suffix.lower() != '.p8':
    raise SystemExit('Supply a readable .p8 file downloaded for the existing API key.')
try:
    content = key.read_bytes()
except OSError:
    raise SystemExit('The supplied .p8 file could not be read.')
if (len(content) > 32000 or b'-----BEGIN PRIVATE KEY-----' not in content
        or b'-----END PRIVATE KEY-----' not in content):
    raise SystemExit('The supplied file must be an unencrypted App Store Connect .p8 private key.')
PY
# Resolve a literal ~/ path supplied as an argument without evaluating shell code.
KEY_PATH="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$KEY_PATH")"
openssl pkey -in "$KEY_PATH" -check -noout >/dev/null 2>&1 || fail 'The supplied private key is invalid.'
gh auth status --hostname github.com >/dev/null 2>&1 || fail 'Run gh auth login --hostname github.com, then retry.'
permission="$(gh repo view "$REPOSITORY" --json viewerPermission --jq .viewerPermission)"
[[ "$permission" == ADMIN ]] || fail 'The signed-in GitHub account needs administrator access to qianquandong/WatchingU.'

printf '%s\n' "Configuring Actions secrets and variables for ${REPOSITORY}."
# Pass secret values through standard input, never --body or command arguments.
printf '%s' "$APP_STORE_CONNECT_API_KEY_ID" | gh secret set APP_STORE_CONNECT_API_KEY_ID --repo "$REPOSITORY"
printf '%s' "$APP_STORE_CONNECT_API_ISSUER_ID" | gh secret set APP_STORE_CONNECT_API_ISSUER_ID --repo "$REPOSITORY"
python3 - "$KEY_PATH" <<'PY' | gh secret set APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64 --repo "$REPOSITORY"
import base64
from pathlib import Path
import sys
sys.stdout.write(base64.b64encode(Path(sys.argv[1]).read_bytes()).decode('ascii'))
PY
printf '%s' "$APPLE_TEAM_ID" | gh variable set APPLE_TEAM_ID --repo "$REPOSITORY"
printf '%s' "$DAYTAPE_BUNDLE_PREFIX" | gh variable set DAYTAPE_BUNDLE_PREFIX --repo "$REPOSITORY"
printf '%s' "$GOOGLE_CLIENT_ID" | gh variable set GOOGLE_CLIENT_ID --repo "$REPOSITORY"
printf '%s\n' 'Configured 3 secrets and 3 variables. No workflow was started.'
