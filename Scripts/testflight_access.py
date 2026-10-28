#!/usr/bin/env python3
"""Check/enable an uploaded build for EXISTING internal TestFlight testers.

Runs with the three existing ASC secrets only on trusted main GitHub Actions.
Dependencies: Tools/requirements.txt (install before exposing deployment secrets).
Default check mode makes GET requests only. An explicit ensure-only flag may
invite the existing tester proven to match the unique Account Holder. It never
creates testers, invites other accounts, enables public links, or submits review.

Apple API references:
https://developer.apple.com/documentation/appstoreconnectapi/get-v1-builds
https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate
https://developer.apple.com/documentation/appstoreconnectapi/post-v1-builds-_id_-relationships-betagroups
https://developer.apple.com/documentation/appstoreconnectapi/patch-v1-builds-_id_
https://developer.apple.com/documentation/appstoreconnectapi/post-v1-betatesterinvitations
https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/
"""
from __future__ import annotations

import argparse
import base64
from collections import Counter
import json
import os
import plistlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ORIGIN = "https://api.appstoreconnect.apple.com"
ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class AccessError(Exception):
    """Contains only deliberately non-sensitive diagnostics."""


class APIError(AccessError):
    def __init__(self, status, codes=()):
        self.status = status
        safe = [c for c in codes if isinstance(c, str) and re.fullmatch(r"[A-Z0-9_.-]{1,100}", c)]
        super().__init__(f"ASC HTTP {status}" + (": " + ",".join(safe) if safe else ""))


def identifier(value):
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise AccessError("ASC returned an invalid resource identifier.")
    return value


def safe_name(value):
    # Even group names can contain an email address. Never echo an API resource.
    value = re.sub(r"\S+@\S+", "[redacted]", str(value))
    return "".join(c for c in value if c.isprintable())[:100]


def trusted_url(path):
    url = urllib.parse.urljoin(ORIGIN + "/", path)
    parts = urllib.parse.urlsplit(url)
    if (parts.scheme, parts.netloc) != ("https", "api.appstoreconnect.apple.com") or not parts.path.startswith("/v1/"):
        raise AccessError("Refused a non-ASC API URL or pagination link.")
    if parts.username or parts.password or parts.fragment:
        raise AccessError("Refused an invalid ASC API URL.")
    return url


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None  # Never forward the bearer token, even to another Apple host.


class ASC:
    def __init__(self, env=os.environ):
        if env.get("GITHUB_ACTIONS") != "true" or env.get("GITHUB_REF") != "refs/heads/main":
            raise AccessError("ASC credentials may be used only by trusted main GitHub Actions.")
        if env.get("GITHUB_REPOSITORY") != "qianquandong/WatchingU":
            raise AccessError("Unexpected deployment repository.")
        try:
            from cryptography.hazmat.primitives import serialization
            self.key = serialization.load_pem_private_key(
                base64.b64decode("".join(env["APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64"].split()), validate=True), None)
            self.kid = env["APP_STORE_CONNECT_API_KEY_ID"]
            self.issuer = env["APP_STORE_CONNECT_API_ISSUER_ID"]
            from cryptography.hazmat.primitives.asymmetric import ec
            if not isinstance(self.key, ec.EllipticCurvePrivateKey) or not isinstance(self.key.curve, ec.SECP256R1):
                raise ValueError()
        except ImportError:
            raise AccessError("Install Tools/requirements.txt before the secret-bearing step.") from None
        except Exception:
            raise AccessError("Missing or invalid ASC signing configuration.") from None
        self.opener = urllib.request.build_opener(NoRedirect())

    def token(self):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        def part(value):
            return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).rstrip(b"=")
        now = int(time.time())
        header = part({"alg": "ES256", "kid": self.kid, "typ": "JWT"})
        payload = part({"iss": self.issuer, "iat": now - 5, "exp": now + 600, "aud": "appstoreconnect-v1"})
        message = header + b"." + payload
        r, s = utils.decode_dss_signature(self.key.sign(message, ec.ECDSA(hashes.SHA256())))
        signature = base64.urlsafe_b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).rstrip(b"=")
        return (message + b"." + signature).decode()

    def request(self, method, path, params=None, body=None):
        url = trusted_url(path)
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        # Invitation sends are not idempotent. A lost response must be inspected,
        # never retried automatically while Apple's state may still be catching up.
        retry_allowed = not (method == "POST" and urllib.parse.urlsplit(url).path == "/v1/betaTesterInvitations")
        for attempt in range(3):
            req = urllib.request.Request(url, method=method,
                headers={"Authorization": "Bearer " + self.token(), "Accept": "application/json", "Content-Type": "application/json"},
                data=None if body is None else json.dumps(body).encode())
            try:
                with self.opener.open(req, timeout=30) as response:
                    data = response.read(4 * 1024 * 1024 + 1)
                if len(data) > 4 * 1024 * 1024:
                    raise AccessError("ASC response exceeded the bounded size.")
                return json.loads(data) if data else {}
            except urllib.error.HTTPError as error:
                if retry_allowed and error.code in (429, 500, 502, 503, 504) and attempt < 2:
                    time.sleep(2 ** attempt * 3)
                    continue
                try:
                    codes = [e.get("code") for e in json.loads(error.read(64 * 1024)).get("errors", [])]
                except Exception:
                    codes = []
                # Never include response detail, request URL, headers, or exception repr.
                raise APIError(error.code, codes) from None
            except (urllib.error.URLError, TimeoutError):
                if retry_allowed and attempt < 2:
                    time.sleep(2 ** attempt * 3)
                    continue
                raise AccessError("ASC network request failed; inspect server state before retrying a mutation.") from None
            except (ValueError, UnicodeError):
                raise AccessError("ASC returned invalid JSON.") from None

    def listing(self, path, params=None):
        result, seen = [], set()
        for _ in range(100):
            url = trusted_url(path)
            if url in seen:
                raise AccessError("ASC pagination repeated a page.")
            seen.add(url)
            page = self.request("GET", path, params=params)
            if not isinstance(page.get("data"), list):
                raise AccessError("ASC returned an invalid resource list.")
            result.extend(page["data"])
            path = page.get("links", {}).get("next")
            if not path:
                return result
            params = None
        raise AccessError("ASC pagination exceeded its bounded page count.")


def attributes(resource):
    return resource.get("attributes", {})


def testers(api, group):
    # Do not request email/firstName/lastName. Internal identity is group membership,
    # NOT inviteType (Apple's enum only has EMAIL and PUBLIC_LINK).
    return api.listing(f"/v1/betaGroups/{identifier(group['id'])}/betaTesters",
        {"fields[betaTesters]": "state", "limit": 200})


def group_builds(api, group):
    return {identifier(b["id"]) for b in api.listing(
        f"/v1/betaGroups/{identifier(group['id'])}/relationships/builds", {"limit": 200})}


def choose_group(groups, members, requested=None):
    internal = [g for g in groups if attributes(g).get("isInternalGroup") is True]
    if requested:
        matches = [g for g in internal if g["id"] == requested]
        if len(matches) != 1:
            raise AccessError("Requested internal group does not belong to this app.")
        return matches[0]
    populated = [g for g in internal if members[g["id"]]]
    if len(populated) == 1:
        return populated[0]
    if len(populated) > 1:
        raise AccessError("Multiple populated internal groups; set ASC_INTERNAL_GROUP_ID.")
    if len(internal) == 1:
        return internal[0]
    raise AccessError("No unambiguous existing internal group; select one explicitly in App Store Connect.")


def find_app(api, bundle):
    apps = api.listing("/v1/apps", {"filter[bundleId]": bundle, "fields[apps]": "bundleId", "limit": 2})
    matches = [a for a in apps if attributes(a).get("bundleId") == bundle]
    if len(matches) != 1:
        raise AccessError("The exact app record is missing or inaccessible to this API key.")
    return identifier(matches[0]["id"])


def find_build(api, app_id, number, marketing):
    params = {"filter[app]": app_id, "sort": "-uploadedDate", "limit": 2,
        "fields[builds]": "version,processingState,expired,usesNonExemptEncryption"}
    if number:
        params["filter[version]"] = number
    if marketing:
        params["filter[preReleaseVersion.version]"] = marketing
    builds = api.listing("/v1/builds", params)
    if not builds:
        return None
    if number and len(builds) != 1:
        raise AccessError("The build number is ambiguous; specify its marketing version.")
    return builds[0]


def masked_identity(value):
    """A recognizable hint, never a complete email or username."""
    value = str(value)
    if "@" not in value:
        return (value[:1] if value else "") + "***"
    local, domain = value.rsplit("@", 1)
    return (local[:1] or "*") + "***@" + (domain[:1] or "*") + "***"


def inspect_inventory(api, options):
    """Read-only preflight even before the first build is uploaded/processed."""
    app_id = find_app(api, options.bundle_id)
    groups = api.listing(f"/v1/apps/{app_id}/betaGroups",
        {"fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds", "limit": 200})
    report = {"app_id": app_id, "mode": "inspect", "groups": [], "account_holder_count": None,
        "all_users_enabled_api_field": "not_exposed_in_documented_betaGroups_schema"}
    for group in groups:
        if attributes(group).get("isInternalGroup") is not True:
            continue
        people = testers(api, group)
        report["groups"].append({"id": identifier(group["id"]), "name": safe_name(attributes(group).get("name", "")),
            "tester_count": len(people), "tester_states": dict(Counter(safe_name(attributes(p).get("state")) for p in people)),
            "all_builds_access": attributes(group).get("hasAccessToAllBuilds") is True})
    report["internal_group_count"] = len(report["groups"])
    try:
        users = api.listing("/v1/users", {"fields[users]": "roles,username,allAppsVisible", "limit": 200})
        role_counts = Counter()
        owners = []
        for user in users:
            roles = attributes(user).get("roles", [])
            role_counts.update(safe_name(r) for r in roles)
            if "ACCOUNT_HOLDER" in roles:
                owners.append({"id": identifier(user["id"]), "identity_hint": masked_identity(attributes(user).get("username", "")),
                    "all_apps_visible": attributes(user).get("allAppsVisible") is True})
        report.update(users_readable=True, users_scope="team_users_not_proof_of_app_specific_access",
            user_count=len(users), role_counts=dict(role_counts), account_holder_count=len(owners), account_holders=owners)
    except APIError as error:
        if error.status != 403:
            raise
        report.update(users_readable=False, users_reason="API_KEY_CANNOT_READ_USERS")
    return report


def invite_existing_owner(api, app_id, group, attempted):
    """Prove membership and owner equality in CI; return only state/count metadata."""
    if attributes(group).get("isInternalGroup") is not True:
        raise AccessError("Owner invitation requires an existing internal group.")
    users = api.listing("/v1/users", {"fields[users]": "roles,username", "limit": 200})
    owners = [u for u in users if "ACCOUNT_HOLDER" in attributes(u).get("roles", [])]
    if len(owners) != 1:
        raise AccessError("Owner invitation requires exactly one Account Holder.")
    username = attributes(owners[0]).get("username")
    if not isinstance(username, str) or "@" not in username or any(c.isspace() for c in username):
        raise AccessError("The Account Holder identity cannot be verified.")
    # Emails stay only in CI memory and are never added to reports or exceptions.
    gid = identifier(group["id"])
    people = api.listing(f"/v1/betaGroups/{gid}/betaTesters",
        {"fields[betaTesters]": "email,state", "limit": 200})
    matches = [p for p in people if isinstance(attributes(p).get("email"), str)
        and attributes(p)["email"].casefold() == username.casefold()]
    if len(matches) != 1:
        raise AccessError("Selected internal group must contain exactly one existing tester matching the Account Holder.")
    owner = matches[0]
    owner_id = identifier(owner["id"])
    state = attributes(owner).get("state")
    if state not in ("NOT_INVITED", "INVITED", "ACCEPTED", "INSTALLED", "REVOKED"):
        raise AccessError("The existing owner tester has an unknown invitation state.")
    if state == "NOT_INVITED" and owner_id not in attempted:
        # Mark BEFORE issuing the request: success with a lost response must not
        # cause the polling loop to send again while GET still says NOT_INVITED.
        attempted.add(owner_id)
        api.request("POST", "/v1/betaTesterInvitations", body={"data": {
            "type": "betaTesterInvitations", "relationships": {
                "app": {"data": {"type": "apps", "id": identifier(app_id)}},
                # Deprecated in Apple's schema but kept explicitly: app-only is
                # not an acceptable fallback for this single-owner permission.
                "betaTester": {"data": {"type": "betaTesters", "id": owner_id}}
            }}})
        people = testers(api, group)
        current = [p for p in people if p.get("id") == owner_id]
        if len(current) != 1:
            raise AccessError("Owner invitation request sent; authoritative tester state could not be confirmed.")
        state = attributes(current[0]).get("state")
        if state not in ("NOT_INVITED", "INVITED", "ACCEPTED", "INSTALLED", "REVOKED"):
            raise AccessError("Owner invitation request sent; authoritative state is not recognized.")
    return {"owner_verified": True, "owner_tester_state": state,
        "owner_invitation_attempted": owner_id in attempted}, people


def inspect_access(api, options):
    """One bounded pass, injectable API for offline tests; no private data returned."""
    app_id = find_app(api, options.bundle_id)
    build = find_build(api, app_id, options.build_number, options.marketing_version)
    report = {"app_id": app_id, "ready": False, "reason": "BUILD_NOT_VISIBLE"}
    if build is None:
        return report
    build_id = identifier(build["id"])
    state = attributes(build).get("processingState")
    report.update(build_id=build_id, build_number=safe_name(attributes(build).get("version", "")),
        processing_state=safe_name(state))
    if attributes(build).get("expired") is True:
        report["reason"] = "BUILD_EXPIRED"
        return report
    if state != "VALID":
        report["reason"] = "PROCESSING" if state == "PROCESSING" else "PROCESSING_FAILED"
        return report
    details = api.request("GET", f"/v1/builds/{build_id}/buildBetaDetail",
        params={"fields[buildBetaDetails]": "internalBuildState"})
    internal_state = attributes(details.get("data", {})).get("internalBuildState")
    report["internal_state"] = safe_name(internal_state)
    if internal_state == "MISSING_EXPORT_COMPLIANCE":
        if options.mode == "ensure" and options.declare_exempt:
            if attributes(build).get("usesNonExemptEncryption") is True:
                raise AccessError("Refused to override an existing non-exempt encryption declaration.")
            with open(Path(__file__).resolve().parents[1] / "Phone/Info.plist", "rb") as source:
                if plistlib.load(source).get("ITSAppUsesNonExemptEncryption") is not False:
                    raise AccessError("The source plist does not declare encryption exemption.")
            if attributes(build).get("usesNonExemptEncryption") is None:
                api.request("PATCH", f"/v1/builds/{build_id}", body={"data": {"type": "builds", "id": build_id,
                    "attributes": {"usesNonExemptEncryption": False}}})
            report["reason"] = "COMPLIANCE_UPDATED_WAITING"
        else:
            report["reason"] = "EXPORT_COMPLIANCE_REQUIRES_ACTION"
        return report
    if internal_state not in ("READY_FOR_BETA_TESTING", "IN_BETA_TESTING"):
        report["reason"] = "INTERNAL_STATE_REQUIRES_ACTION"
        return report
    groups = api.listing(f"/v1/apps/{app_id}/betaGroups",
        {"fields[betaGroups]": "name,isInternalGroup,hasAccessToAllBuilds", "limit": 200})
    internal = [g for g in groups if attributes(g).get("isInternalGroup") is True]
    members = {g["id"]: testers(api, g) for g in internal}
    group = choose_group(groups, members, options.internal_group_id)
    gid = identifier(group["id"])
    known_internal = {identifier(t["id"]) for people in members.values() for t in people}
    requested = set(options.tester_id)
    if not requested.issubset(known_internal):
        raise AccessError("Requested tester is not an existing internal member of this app; no invitation was sent.")
    missing = requested - {t["id"] for t in members[gid]}
    if missing and options.mode == "ensure":
        api.request("POST", f"/v1/betaGroups/{gid}/relationships/betaTesters",
            body={"data": [{"type": "betaTesters", "id": t} for t in sorted(missing)]})
        members[gid] = testers(api, group)
    accepted = sum(attributes(t).get("state") in ("ACCEPTED", "INSTALLED") for t in members[gid])
    report.update(group_id=gid, group_name=safe_name(attributes(group).get("name", "")),
        tester_count=len(members[gid]), accepted_testers=accepted)
    if not members[gid]:
        report["reason"] = "NO_INTERNAL_TESTERS"
        return report
    assigned = attributes(group).get("hasAccessToAllBuilds") is True or build_id in group_builds(api, group)
    if not assigned and options.mode == "ensure":
        api.request("POST", f"/v1/builds/{build_id}/relationships/betaGroups",
            body={"data": [{"type": "betaGroups", "id": gid}]})
        report["reason"] = "BUILD_ASSIGNED_WAITING"
        return report
    if assigned and options.mode == "ensure" and getattr(options, "invite_existing_owner", False):
        if not hasattr(options, "owner_invitation_attempts"):
            options.owner_invitation_attempts = set()
        owner_report, members[gid] = invite_existing_owner(api, app_id, group, options.owner_invitation_attempts)
        report.update(owner_report)
        accepted = sum(attributes(t).get("state") in ("ACCEPTED", "INSTALLED") for t in members[gid])
        report["accepted_testers"] = accepted
        if report["owner_tester_state"] == "NOT_INVITED":
            report["reason"] = "OWNER_INVITATION_AWAITING_CONFIRMATION"
            return report
        if report["owner_tester_state"] == "INVITED":
            report["reason"] = "ACCEPT_EXISTING_INVITATION"
            return report
        if report["owner_tester_state"] == "REVOKED":
            report["reason"] = "OWNER_STATE_REQUIRES_ACTION"
            return report
    if not assigned:
        report["reason"] = "BUILD_NOT_ASSIGNED"
    elif missing:
        report["reason"] = "TESTER_ASSIGNMENT_WAITING"
    elif accepted == 0:
        report["reason"] = "ACCEPT_EXISTING_INVITATION"
    elif internal_state != "IN_BETA_TESTING":
        report["reason"] = "WAITING_FOR_INTERNAL_TESTING"
    else:
        report.update(ready=True, reason="INTERNAL_TESTING_AVAILABLE")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("inspect", "check", "ensure"), default="check")
    parser.add_argument("--bundle-id", default=os.environ.get("DAYTAPE_BUNDLE_PREFIX", "com.aimanjack.daytape"))
    parser.add_argument("--build-number", default=os.environ.get("TF_BUILD_NUMBER"))
    parser.add_argument("--marketing-version", default="0.5.0")
    parser.add_argument("--internal-group-id", default=os.environ.get("ASC_INTERNAL_GROUP_ID"))
    parser.add_argument("--tester-id", action="append", default=[])
    parser.add_argument("--declare-exempt", action="store_true", help="Explicitly apply the source plist's existing false declaration if compliance is missing")
    parser.add_argument("--invite-existing-owner", action="store_true",
        help="Ensure only: invite a NOT_INVITED tester already in the selected internal group, only after unique Account Holder equality is proved")
    parser.add_argument("--timeout-seconds", type=int, default=0, help="Poll for up to this time (maximum 7200); 0 means one check")
    parser.add_argument("--poll-seconds", type=int, default=30)
    options = parser.parse_args(argv)
    if options.mode == "ensure" and not options.build_number:
        parser.error("ensure requires an exact --build-number")
    if options.invite_existing_owner and options.mode != "ensure":
        parser.error("--invite-existing-owner requires ensure mode")
    if not 0 <= options.timeout_seconds <= 7200 or not 1 <= options.poll_seconds <= 60:
        parser.error("invalid bounded polling interval")
    try:
        if options.internal_group_id:
            identifier(options.internal_group_id)
        for tester in options.tester_id:
            identifier(tester)
        api = ASC()
        if options.mode == "inspect":
            print(json.dumps(inspect_inventory(api, options), ensure_ascii=True, sort_keys=True), flush=True)
            return 0
        deadline = time.monotonic() + options.timeout_seconds
        previous = None
        while True:
            report = inspect_access(api, options)
            output = json.dumps(report, ensure_ascii=True, sort_keys=True)
            if output != previous:
                print(output, flush=True)
                previous = output
            if report["ready"]:
                # API availability cannot prove installation on the user's physical device.
                return 0
            if report["reason"] in ("PROCESSING_FAILED", "BUILD_EXPIRED", "NO_INTERNAL_TESTERS", "ACCEPT_EXISTING_INVITATION",
                    "EXPORT_COMPLIANCE_REQUIRES_ACTION", "INTERNAL_STATE_REQUIRES_ACTION", "OWNER_STATE_REQUIRES_ACTION"):
                return 3
            if time.monotonic() >= deadline:
                return 3
            time.sleep(min(options.poll_seconds, max(0, deadline - time.monotonic())))
    except AccessError as error:
        print("TestFlight access: " + str(error), file=sys.stderr)
        return 2
    except Exception as error:
        # No traceback/exception text: API errors and third-party errors may contain secrets/PII.
        print("TestFlight access: operation failed (" + type(error).__name__ + ").", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
