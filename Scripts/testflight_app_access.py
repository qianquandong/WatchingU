#!/usr/bin/env python3
"""Prepare or apply an explicitly approved, single-app Developer access addition.

Default is GET-only. --apply is for the separately approved access change, not
an invitation shortcut. It never creates users or changes roles/allAppsVisible.
The intended recipient stays in TF_INVITATION_EMAIL, never source or arguments.
"""
import argparse
import json
import os
import sys
from testflight_access import ASC, AccessError, attributes, find_app, find_build, identifier
from testflight_recipient import APP_ID, BUNDLE_ID, BUILD_NUMBER, MARKETING_VERSION, exact_email, target_address

USER_ID = "6a1ea27a-16f4-4bc6-91db-db6ba3e9042e"


def current_scope(api, target):
    if find_app(api, BUNDLE_ID) != APP_ID:
        raise AccessError("APP_SCOPE_MISMATCH")
    build = find_build(api, APP_ID, BUILD_NUMBER, MARKETING_VERSION)
    if not build or attributes(build).get("processingState") != "VALID" or attributes(build).get("expired") is not False:
        raise AccessError("EXACT_TEST_BUILD_NOT_AVAILABLE")
    users = api.listing("/v1/users", {"fields[users]": "username,roles,allAppsVisible", "limit": 200})
    matches = [u for u in users if exact_email(u, "username", target)]
    if len(matches) != 1 or matches[0].get("id") != USER_ID:
        raise AccessError("APP_ACCESS_RECIPIENT_MISMATCH")
    user = matches[0]
    if attributes(user).get("roles") != ["DEVELOPER"] or attributes(user).get("allAppsVisible") is not False:
        raise AccessError("APP_ACCESS_APPROVAL_SCOPE_CHANGED")
    apps = api.listing(f"/v1/users/{USER_ID}/relationships/visibleApps")
    return {identifier(a["id"]) for a in apps}


def single_app_access(api, target, apply=False):
    before = current_scope(api, target)
    report = dict(app_id=APP_ID, user_id=USER_ID, existing_role="DEVELOPER", apply=apply,
                  app_visible=APP_ID in before, roles_changed=False, all_apps_enabled=False,
                  added_app_count=0, previous_app_count=len(before))
    if not apply:
        report["reason"] = "APP_ACCESS_ALREADY_PRESENT" if APP_ID in before else "AWAITING_EXPLICIT_APP_ACCESS_APPROVAL"
        return report
    if APP_ID in before:
        report["reason"] = "APP_ACCESS_ALREADY_PRESENT"
        return report
    # POST appends the one approved app; PATCH would replace the existing list.
    api.request("POST", f"/v1/users/{USER_ID}/relationships/visibleApps",
                body={"data": [{"type": "apps", "id": APP_ID}]})
    after = current_scope(api, target)
    if not before.issubset(after) or APP_ID not in after:
        raise AccessError("APP_ACCESS_WRITE_AWAITING_CONFIRMATION")
    if after - before != {APP_ID}:
        raise AccessError("APP_ACCESS_CONCURRENT_CHANGE_REQUIRES_REVIEW")
    report.update(app_visible=True, added_app_count=1, reason="SINGLE_APP_ACCESS_CONFIRMED")
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Apply the specifically approved access addition")
    args = parser.parse_args(argv)
    try:
        report = single_app_access(ASC(), target_address(os.environ), args.apply)
        print(json.dumps(report, sort_keys=True), flush=True)
        return 0
    except AccessError:
        print('{"reason":"APP_ACCESS_CHECK_OR_WRITE_FAILED","app_id":"' + APP_ID + '"}', file=sys.stderr)
        return 2
    except Exception:
        print('{"reason":"APP_ACCESS_OPERATION_FAILED"}', file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
