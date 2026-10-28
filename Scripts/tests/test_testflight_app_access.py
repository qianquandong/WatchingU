import importlib.util
from pathlib import Path
import sys
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("testflight_app_access", SCRIPTS / "testflight_app_access.py")
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)


class FakeASC:
    target = "tester@example.test"
    def __init__(self):
        self.calls = []
        self.roles = ["DEVELOPER"]
        self.apps = {"previous_app"}
        self.username = self.target
        self.expired = False

    def listing(self, path, params=None):
        self.calls.append(("GET", path, params))
        if path == "/v1/apps":
            return [dict(id=tf.APP_ID, attributes=dict(bundleId=tf.BUNDLE_ID))]
        if path == "/v1/builds":
            return [dict(id="build1", attributes=dict(version=tf.BUILD_NUMBER, processingState="VALID", expired=self.expired))]
        if path == "/v1/users":
            return [dict(id=tf.USER_ID, attributes=dict(username=self.username, roles=self.roles, allAppsVisible=False))]
        if path.endswith("/relationships/visibleApps"):
            return [dict(type="apps", id=a) for a in sorted(self.apps)]
        raise AssertionError("Unexpected read")

    def request(self, method, path, params=None, body=None):
        self.calls.append((method, path, body))
        assert method == "POST" and path == f"/v1/users/{tf.USER_ID}/relationships/visibleApps"
        assert body == {"data": [{"type": "apps", "id": tf.APP_ID}]}
        self.apps.add(tf.APP_ID)
        return {}


class SingleAppAccessTests(unittest.TestCase):
    def test_default_is_read_only_and_does_not_log_identity(self):
        api = FakeASC()
        report = tf.single_app_access(api, api.target)
        self.assertEqual(report["reason"], "AWAITING_EXPLICIT_APP_ACCESS_APPROVAL")
        self.assertTrue(all(c[0] == "GET" for c in api.calls))
        self.assertNotIn(api.target, str(report))

    def test_apply_appends_only_one_app_and_preserves_previous_scope(self):
        api = FakeASC()
        report = tf.single_app_access(api, api.target, apply=True)
        self.assertEqual(api.apps, {"previous_app", tf.APP_ID})
        self.assertEqual(report["reason"], "SINGLE_APP_ACCESS_CONFIRMED")
        self.assertEqual(len([c for c in api.calls if c[0] != "GET"]), 1)

    def test_existing_access_is_not_rewritten(self):
        api = FakeASC(); api.apps.add(tf.APP_ID)
        tf.single_app_access(api, api.target, apply=True)
        self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_changed_identity_role_or_unknown_expiry_prevents_writes(self):
        for name, value in [("username", "other@example.test"), ("roles", ["ADMIN"]), ("expired", None)]:
            api = FakeASC(); setattr(api, name, value)
            with self.assertRaises(tf.AccessError):
                tf.single_app_access(api, api.target, apply=True)
            self.assertTrue(all(c[0] == "GET" for c in api.calls))


if __name__ == "__main__": unittest.main()
