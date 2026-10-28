#!/usr/bin/env python3
"""Inspect the explicitly selected DayTape recipient without exposing identity.

The address is accepted only from TF_INVITATION_EMAIL, never a command argument.
This script never creates an ASC user, changes roles, creates a tester or submits review.
"""
from __future__ import annotations
import argparse
import json
import os
import re
import sys
from testflight_access import ASC, APIError, AccessError, attributes, find_app, find_build, identifier, masked_identity, safe_name

APP_ID = "6825198699"
BUNDLE_ID = "com.aimanjack.daytape"
BUILD_NUMBER = "5.1"
MARKETING_VERSION = "0.5.0"
GROUP_ID = "d43af501-25bb-4009-9a88-ac6cad53ef36"
ELIGIBLE_ROLES = {"ACCOUNT_HOLDER", "ADMIN", "APP_MANAGER", "DEVELOPER", "MARKETING"}
STATES = {"NOT_INVITED", "INVITED", "ACCEPTED", "INSTALLED", "REVOKED"}


def target_address(env):
    value = env.get("TF_INVITATION_EMAIL", "").strip()
    if (len(value) > 254 or not re.fullmatch(r"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\.[A-Za-z]{2,63}", value)
            or any(c.isspace() for c in value) or ".." in value):
        raise AccessError("TARGET_EMAIL_INVALID")
    return value


def exact_email(resource, field, target):
    value = attributes(resource).get(field)
    return isinstance(value, str) and value.casefold() == target.casefold()


def safe_state(value):
    return value if isinstance(value, str) and re.fullmatch(r"[A-Z][A-Z0-9_]{0,79}", value) else "UNKNOWN"


def inspect_recipient(api, target, build_number=BUILD_NUMBER, marketing=MARKETING_VERSION, group_id=GROUP_ID):
    if (build_number, marketing, group_id) != (BUILD_NUMBER, MARKETING_VERSION, GROUP_ID):
        raise AccessError("RECIPIENT_SCOPE_MISMATCH")
    if find_app(api, BUNDLE_ID) != APP_ID:
        raise AccessError("APP_SCOPE_MISMATCH")
    app = api.request("GET", f"/v1/apps/{APP_ID}", params={"fields[apps]": "name,bundleId"}).get("data", {})
    if app.get("id") != APP_ID or attributes(app).get("bundleId") != BUNDLE_ID:
        raise AccessError("APP_SCOPE_MISMATCH")
    report = dict(mode="inspect", app_id=APP_ID, app_name=safe_name(attributes(app).get("name", "")),
        bundle_id=BUNDLE_ID, build_number=BUILD_NUMBER, marketing_version=MARKETING_VERSION, group_id=GROUP_ID,
        target_hint=masked_identity(target), eligible=False, app_visible=False, target_user_count=0,
        target_roles=[], target_tester_count=0, target_group_member=False, build_assigned=False, ready=False)
    reasons = []
    try:
        users = api.listing("/v1/users", {"fields[users]": "roles,username,allAppsVisible", "limit": 200})
        matches = [u for u in users if exact_email(u, "username", target)]
        report.update(users_readable=True, target_user_count=len(matches))
        if len(matches) != 1:
            reasons.append("TARGET_ASC_USER_NOT_FOUND" if not matches else "TARGET_ASC_USER_AMBIGUOUS")
        else:
            user = matches[0]; uid = identifier(user["id"])
            roles = attributes(user).get("roles", [])
            roles = sorted({r for r in roles if isinstance(r, str) and re.fullmatch(r"[A-Z_]{1,40}", r)}) if isinstance(roles, list) else []
            report.update(target_user_id=uid, target_roles=roles)
            all_apps = attributes(user).get("allAppsVisible")
            report["target_all_apps_visible"] = all_apps if isinstance(all_apps, bool) else None
            visible = all_apps is True
            if all_apps is False:
                apps = api.listing(f"/v1/users/{uid}/relationships/visibleApps")
                visible = len([a for a in apps if a.get("type") == "apps" and a.get("id") == APP_ID]) == 1
            report["app_visible"] = visible
            report["eligible"] = bool(ELIGIBLE_ROLES.intersection(roles)) and visible
            if not ELIGIBLE_ROLES.intersection(roles): reasons.append("TARGET_ROLE_NOT_ELIGIBLE")
            elif not visible: reasons.append("TARGET_APP_NOT_VISIBLE")
    except APIError as error:
        report.update(users_readable=False, users_api_status=error.status)
        reasons.append("TARGET_USERS_UNREADABLE")
    people = api.listing("/v1/betaTesters", {"filter[email]": target, "filter[apps]": APP_ID,
        "fields[betaTesters]": "email,state", "limit": 200})
    candidates = [p for p in people if exact_email(p, "email", target)]
    report["target_tester_candidate_count"] = len(candidates)
    report["tester_query_app_filtered"] = True
    matched = []
    tester_scope_readable = True
    for candidate in candidates:
        try:
            apps = api.listing(f"/v1/betaTesters/{identifier(candidate['id'])}/relationships/apps")
            associations = [a for a in apps if a.get("type") == "apps" and a.get("id") == APP_ID]
            if len(associations) == 1: matched.append(candidate)
            elif len(associations) > 1: reasons.append("TARGET_TESTER_APP_SCOPE_AMBIGUOUS")
        except APIError as error:
            tester_scope_readable = False
            report["tester_scope_api_status"] = error.status
    report["tester_app_scope_readable"] = tester_scope_readable
    if not tester_scope_readable:
        reasons.append("TARGET_TESTER_APP_SCOPE_UNREADABLE")
        matched = []
    report["target_tester_count"] = len(matched)
    if len(matched) == 1:
        report.update(target_tester_id=identifier(matched[0]["id"]), target_tester_state=safe_state(attributes(matched[0]).get("state")))
    else:
        reasons.append("TARGET_TESTER_NOT_FOUND" if not matched else "TARGET_TESTER_AMBIGUOUS")
    groups = api.listing(f"/v1/apps/{APP_ID}/betaGroups", {"fields[betaGroups]": "isInternalGroup,hasAccessToAllBuilds", "limit": 200})
    groups = [g for g in groups if g.get("id") == GROUP_ID and attributes(g).get("isInternalGroup") is True]
    report["internal_group_valid"] = len(groups) == 1
    build = find_build(api, APP_ID, BUILD_NUMBER, MARKETING_VERSION)
    if build is None:
        reasons.append("BUILD_NOT_FOUND")
    else:
        bid = identifier(build["id"])
        detail = api.request("GET", f"/v1/builds/{bid}", params={"fields[builds]": "version,processingState,buildAudienceType,expired"}).get("data", {})
        if detail.get("id") != bid or attributes(detail).get("version") != BUILD_NUMBER:
            raise AccessError("BUILD_SCOPE_MISMATCH")
        testing = api.request("GET", f"/v1/builds/{bid}/buildBetaDetail").get("data", {})
        report.update(build_id=bid, processing_state=safe_state(attributes(detail).get("processingState")),
            build_audience_type=safe_state(attributes(detail).get("buildAudienceType")),
            internal_build_state=safe_state(attributes(testing).get("internalBuildState")),
            external_build_state=safe_state(attributes(testing).get("externalBuildState")))
        expired = attributes(detail).get("expired", attributes(build).get("expired"))
        report["build_expired"] = expired if isinstance(expired, bool) else None
        if expired is True: reasons.append("BUILD_EXPIRED")
        elif expired is not False: reasons.append("BUILD_EXPIRY_UNKNOWN")
    if len(groups) != 1:
        reasons.append("TARGET_INTERNAL_GROUP_INVALID")
    else:
        members = api.listing(f"/v1/betaGroups/{GROUP_ID}/betaTesters", {"fields[betaTesters]": "email,state", "limit": 200})
        members = [p for p in members if exact_email(p, "email", target)]
        if len(members) > 1:
            reasons.append("TARGET_GROUP_MEMBER_AMBIGUOUS")
        elif len(members) == 1:
            member = members[0]
            if member.get("id") != report.get("target_tester_id"):
                reasons.append("TARGET_GROUP_IDENTITY_MISMATCH")
            else:
                report.update(target_group_member=True, target_tester_state=safe_state(attributes(member).get("state")))
        assigned = api.listing(f"/v1/betaGroups/{GROUP_ID}/relationships/builds", {"limit": 200})
        report["build_assigned"] = bool(report.get("build_id")) and any(b.get("id") == report["build_id"] for b in assigned)
    report["blocking_reasons"] = reasons
    report["reason"] = reasons[0] if reasons else readiness_reason(report)
    report["ready"] = report["reason"] == "TARGET_INTERNAL_TESTING_AVAILABLE"
    return report


def invite_internal(api, target, build_number=BUILD_NUMBER, marketing=MARKETING_VERSION, group_id=GROUP_ID):
    """Only add this existing eligible recipient and make at most one invitation request."""
    actions = dict(mode="invite-internal", membership_added=False, invitation_attempted=False,
                   invitation_request_accepted=None)
    report = inspect_recipient(api, target, build_number, marketing, group_id)
    report.update(actions)
    if report["blocking_reasons"] or report.get("eligible") is not True:
        return report
    initial_state = report.get("target_tester_state")
    if initial_state not in STATES or initial_state == "REVOKED":
        report.update(ready=False, reason="TARGET_TESTER_REVOKED" if initial_state == "REVOKED" else "TARGET_TESTER_STATE_UNKNOWN")
        return report
    if report.get("build_expired") is not False or report.get("processing_state") != "VALID":
        report.update(ready=False, reason="BUILD_NOT_PROCESSED")
        return report
    if not report.get("build_assigned"):
        report.update(ready=False, reason="BUILD_NOT_ASSIGNED")
        return report
    if report.get("internal_build_state") != "IN_BETA_TESTING":
        report.update(ready=False, reason="WAITING_FOR_INTERNAL_TESTING")
        return report
    tester_id = identifier(report["target_tester_id"])
    if not report["target_group_member"]:
        try:
            api.request("POST", f"/v1/betaGroups/{GROUP_ID}/relationships/betaTesters",
                body={"data": [{"type": "betaTesters", "id": tester_id}]})
        except APIError as error:
            report.update(ready=False, reason="TARGET_GROUP_ASSIGNMENT_FAILED", mutation_api_status=error.status)
            return report
        except AccessError:
            report.update(ready=False, reason="TARGET_GROUP_ASSIGNMENT_UNCONFIRMED")
            return report
        actions["membership_added"] = True
        report = inspect_recipient(api, target, build_number, marketing, group_id)
        report.update(actions)
        if report["blocking_reasons"] or report.get("eligible") is not True:
            return report
        if not report["target_group_member"] or report.get("target_tester_id") != tester_id:
            report.update(ready=False, reason="TARGET_GROUP_ASSIGNMENT_WAITING")
            return report
        if (report.get("build_expired") is not False or report.get("processing_state") != "VALID"
                or not report.get("build_assigned") or report.get("internal_build_state") != "IN_BETA_TESTING"):
            report.update(ready=False, reason="INVITATION_PRECONDITION_CHANGED")
            return report
    # Do not resend a known invitation, including when membership propagation
    # momentarily reports NOT_INVITED after the earlier global INVITED state.
    if initial_state in {"INVITED", "ACCEPTED", "INSTALLED"}:
        if initial_state == "INVITED": report.update(ready=False, reason="ACCEPT_EXISTING_INVITATION")
        return report
    state = report.get("target_tester_state")
    if state != "NOT_INVITED":
        return report
    actions["invitation_attempted"] = True
    report.update(actions)
    try:
        # ASC.request explicitly disables network/status retry for this endpoint.
        api.request("POST", "/v1/betaTesterInvitations", body={"data": {
            "type": "betaTesterInvitations", "relationships": {
                "app": {"data": {"type": "apps", "id": APP_ID}},
                "betaTester": {"data": {"type": "betaTesters", "id": tester_id}}
            }}})
    except APIError as error:
        report.update(ready=False, reason="INVITATION_REQUEST_FAILED", mutation_api_status=error.status,
                      invitation_request_accepted=False)
        return report
    except AccessError:
        report.update(ready=False, reason="INVITATION_RESULT_UNCONFIRMED")
        return report
    actions["invitation_request_accepted"] = True
    report = inspect_recipient(api, target, build_number, marketing, group_id)
    report.update(actions)
    if not report["blocking_reasons"] and report.get("target_tester_state") == "NOT_INVITED":
        report.update(ready=False, reason="INVITATION_AWAITING_CONFIRMATION")
    return report


def readiness_reason(report):
    state = report.get("target_tester_state")
    if state not in STATES: return "TARGET_TESTER_STATE_UNKNOWN"
    if state == "REVOKED": return "TARGET_TESTER_REVOKED"
    if not report.get("target_group_member"): return "TARGET_NOT_IN_INTERNAL_GROUP"
    if not report.get("build_assigned"): return "BUILD_NOT_ASSIGNED"
    if state == "NOT_INVITED": return "TARGET_NOT_INVITED"
    if state == "INVITED": return "ACCEPT_EXISTING_INVITATION"
    if report.get("processing_state") != "VALID": return "BUILD_NOT_PROCESSED"
    if report.get("internal_build_state") != "IN_BETA_TESTING": return "WAITING_FOR_INTERNAL_TESTING"
    return "TARGET_INTERNAL_TESTING_AVAILABLE"


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # Unknown argv may itself be a pasted identity. Never echo it.
        raise AccessError("RECIPIENT_ARGUMENTS_INVALID")


def main(argv=None, env=os.environ, api_factory=ASC):
    parser = SafeArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["inspect", "invite-internal"], default="inspect")
    parser.add_argument("--build-number", default=BUILD_NUMBER)
    parser.add_argument("--marketing-version", default=MARKETING_VERSION)
    parser.add_argument("--internal-group-id", default=GROUP_ID)
    try:
        options = parser.parse_args(argv)
        target = target_address(env)
        api = api_factory()
        operation = inspect_recipient if options.mode == "inspect" else invite_internal
        report = operation(api, target, options.build_number, options.marketing_version, options.internal_group_id)
        print(json.dumps(report, ensure_ascii=True, sort_keys=True), flush=True)
        return 0 if options.mode == "inspect" or report["ready"] else 3
    except APIError as error:
        print(json.dumps({"ready": False, "reason": "ASC_API_ERROR", "http_status": error.status}), file=sys.stderr)
        return 2
    except AccessError as error:
        code = str(error)
        print(json.dumps({"ready": False, "reason": code if re.fullmatch(r"[A-Z_]{1,80}", code) else "ASC_ACCESS_ERROR"}), file=sys.stderr)
        return 2
    except Exception:
        print(json.dumps({"ready": False, "reason": "RECIPIENT_OPERATION_FAILED"}), file=sys.stderr)
        return 2


if __name__ == "__main__": sys.exit(main())
