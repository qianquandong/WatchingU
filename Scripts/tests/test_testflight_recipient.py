import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("testflight_recipient", SCRIPTS / "testflight_recipient.py")
tf = importlib.util.module_from_spec(spec); spec.loader.exec_module(tf)


def resource(kind, identity, **attrs): return dict(type=kind, id=identity, attributes=attrs)


class FakeASC:
    target = "recipient@example.test"
    def __init__(self):
        self.calls = []
        self.users = [resource("users", "user1", username=self.target.upper(), roles=["DEVELOPER"], allAppsVisible=True)]
        self.people = [resource("betaTesters", "tester1", email=self.target, state="ACCEPTED")]
        self.members = list(self.people)
        self.visible = [dict(type="apps", id=tf.APP_ID)]
        self.assigned = [dict(type="builds", id="build1")]
        self.groups = [resource("betaGroups", tf.GROUP_ID, isInternalGroup=True)]

    def listing(self, path, params=None):
        self.calls.append(("GET", path, params))
        if path == "/v1/apps": return [resource("apps", tf.APP_ID, bundleId=tf.BUNDLE_ID)]
        if path == "/v1/users": return self.users
        if path == "/v1/users/user1/relationships/visibleApps": return self.visible
        if path == "/v1/betaTesters": return self.people
        if path == f"/v1/apps/{tf.APP_ID}/betaGroups": return self.groups
        if path == "/v1/builds": return [resource("builds", "build1", version=tf.BUILD_NUMBER, processingState="VALID", expired=False)]
        if path == f"/v1/betaGroups/{tf.GROUP_ID}/betaTesters": return self.members
        if path == f"/v1/betaGroups/{tf.GROUP_ID}/relationships/builds": return self.assigned
        raise AssertionError("Unexpected API read")

    def request(self, method, path, params=None, body=None):
        self.calls.append((method, path, body))
        if method != "GET": raise AssertionError("Inspect must be read only")
        if path == f"/v1/apps/{tf.APP_ID}": return {"data": resource("apps", tf.APP_ID, name="DayTape", bundleId=tf.BUNDLE_ID)}
        if path == "/v1/builds/build1": return {"data": resource("builds", "build1", version=tf.BUILD_NUMBER, processingState="VALID", buildAudienceType="INTERNAL_ONLY")}
        if path == "/v1/builds/build1/buildBetaDetail": return {"data": resource("buildBetaDetails", "d1", internalBuildState="IN_BETA_TESTING", externalBuildState="READY_FOR_BETA_SUBMISSION")}
        raise AssertionError("Unexpected API request")


class RecipientInspectTests(unittest.TestCase):
    def test_inspect_is_get_only_exact_target_and_has_no_complete_identity(self):
        api = FakeASC(); api.users.append(resource("users", "other", username="other@example.test", roles=["ADMIN"], allAppsVisible=True))
        report = tf.inspect_recipient(api, api.target)
        self.assertTrue(report["eligible"]); self.assertTrue(report["ready"])
        self.assertEqual(report["target_user_id"], "user1")
        self.assertEqual(report["build_audience_type"], "INTERNAL_ONLY")
        self.assertNotIn(api.target, json.dumps(report)); self.assertNotIn("other@example.test", json.dumps(report))
        self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_limited_app_visibility_must_be_proved(self):
        api = FakeASC(); api.users[0]["attributes"]["allAppsVisible"] = False
        self.assertTrue(tf.inspect_recipient(api, api.target)["eligible"])
        api.visible = []
        report = tf.inspect_recipient(api, api.target)
        self.assertFalse(report["eligible"]); self.assertEqual(report["reason"], "TARGET_APP_NOT_VISIBLE")

    def test_missing_and_duplicate_users_or_testers_fail_closed(self):
        for field in ["users", "people"]:
            for duplicate in [False, True]:
                api = FakeASC(); values = getattr(api, field)
                setattr(api, field, values * 2 if duplicate else [])
                report = tf.inspect_recipient(api, api.target)
                self.assertFalse(report["ready"])
                self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_cli_invalid_email_and_scope_do_not_echo_input(self):
        api = FakeASC(); output = io.StringIO()
        with contextlib.redirect_stderr(output):
            status = tf.main(["--build-number", "wrong"], {"TF_INVITATION_EMAIL": api.target}, lambda: api)
        self.assertEqual(status, 2); self.assertNotIn(api.target, output.getvalue())
        self.assertIn("RECIPIENT_SCOPE_MISMATCH", output.getvalue())
        self.assertEqual(api.calls, [])


if __name__ == "__main__": unittest.main()
