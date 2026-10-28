import base64
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "testflight_access.py"
spec = importlib.util.spec_from_file_location("testflight_access", SCRIPT)
tf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf)


def resource(kind, identity, **attrs):
    return {"type": kind, "id": identity, "attributes": attrs}


def options(**kwargs):
    values = dict(mode="check", bundle_id="com.aimanjack.daytape", build_number="42.1",
        marketing_version="0.5.0", internal_group_id=None, tester_id=[], declare_exempt=False)
    values.update(kwargs)
    return SimpleNamespace(**values)


class FakeASC:
    def __init__(self):
        self.calls = []
        self.build = resource("builds", "build1", version="42.1", processingState="VALID", expired=False,
            usesNonExemptEncryption=False)
        self.state = "IN_BETA_TESTING"
        self.groups = [resource("betaGroups", "g1", name="Internal", isInternalGroup=True, hasAccessToAllBuilds=False)]
        self.people = {"g1": [resource("betaTesters", "tester1", state="INSTALLED")]}
        self.assigned = {"g1": [dict(type="builds", id="build1")]}
        self.users = [resource("users", "user1", username="owner@example.com", roles=["ACCOUNT_HOLDER", "ADMIN"], allAppsVisible=True)]
        self.users_denied = False

    def listing(self, path, params=None):
        self.calls.append(("GET", path, params))
        if path == "/v1/apps":
            return [resource("apps", "app1", bundleId="com.aimanjack.daytape")]
        if path == "/v1/builds":
            return [] if self.build is None else [self.build]
        if path == "/v1/apps/app1/betaGroups":
            return self.groups
        if path == "/v1/users":
            if self.users_denied:
                raise tf.APIError(403)
            return self.users
        for gid, people in self.people.items():
            if path == f"/v1/betaGroups/{gid}/betaTesters":
                return people
            if path == f"/v1/betaGroups/{gid}/relationships/builds":
                return self.assigned.get(gid, [])
        raise AssertionError("Unexpected API read")

    def request(self, method, path, params=None, body=None):
        self.calls.append((method, path, body))
        if method == "GET" and path == "/v1/builds/build1/buildBetaDetail":
            return {"data": resource("buildBetaDetails", "detail1", internalBuildState=self.state)}
        if method == "PATCH":
            self.build["attributes"]["usesNonExemptEncryption"] = body["data"]["attributes"]["usesNonExemptEncryption"]
            return {"data": self.build}
        if method == "POST" and path.endswith("/relationships/betaGroups"):
            gid = body["data"][0]["id"]
            self.assigned[gid] = [dict(type="builds", id="build1")]
            return {}
        if method == "POST" and path.endswith("/relationships/betaTesters"):
            gid = path.split("/")[3]
            self.people[gid] += [resource("betaTesters", t["id"], state="ACCEPTED") for t in body["data"]]
            return {}
        raise AssertionError("Unexpected API mutation")


class TestFlightAccessTests(unittest.TestCase):
    def test_inventory_needs_no_build_and_never_logs_full_identity(self):
        api = FakeASC()
        api.build = None
        api.groups[0]["attributes"]["name"] = "owner@example.com internal"
        report = tf.inspect_inventory(api, options(mode="inspect"))
        self.assertEqual(report["account_holder_count"], 1)
        self.assertEqual(report["role_counts"]["ACCOUNT_HOLDER"], 1)
        self.assertEqual(report["groups"][0]["tester_count"], 1)
        self.assertNotIn("owner@example.com", json.dumps(report))
        self.assertTrue(all(method == "GET" and path != "/v1/builds" for method, path, _ in api.calls))

    def test_users_denied_is_not_misreported_as_zero_owners(self):
        api = FakeASC(); api.users_denied = True
        report = tf.inspect_inventory(api, options())
        self.assertFalse(report["users_readable"])
        self.assertIsNone(report["account_holder_count"])

    def test_processed_but_unassigned_build_is_not_ready_and_check_cannot_mutate(self):
        api = FakeASC(); api.assigned["g1"] = []
        report = tf.inspect_access(api, options())
        self.assertFalse(report["ready"])
        self.assertEqual(report["reason"], "BUILD_NOT_ASSIGNED")
        self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_ensure_assigns_only_existing_internal_group_and_next_pass_confirms(self):
        api = FakeASC(); api.assigned["g1"] = []
        report = tf.inspect_access(api, options(mode="ensure"))
        self.assertEqual(report["reason"], "BUILD_ASSIGNED_WAITING")
        mutations = [c for c in api.calls if c[0] != "GET"]
        self.assertEqual(mutations, [("POST", "/v1/builds/build1/relationships/betaGroups",
            {"data": [{"type": "betaGroups", "id": "g1"}]})])
        self.assertTrue(tf.inspect_access(api, options(mode="ensure"))["ready"])

    def test_empty_group_and_unaccepted_invitation_cannot_report_installable(self):
        api = FakeASC(); api.people["g1"] = []
        self.assertEqual(tf.inspect_access(api, options(mode="ensure"))["reason"], "NO_INTERNAL_TESTERS")
        self.assertTrue(all(c[0] == "GET" for c in api.calls))
        api.people["g1"] = [resource("betaTesters", "tester1", state="INVITED")]
        self.assertEqual(tf.inspect_access(api, options())["reason"], "ACCEPT_EXISTING_INVITATION")

    def test_processing_and_internal_ready_are_distinct_from_testing(self):
        api = FakeASC(); api.build["attributes"]["processingState"] = "PROCESSING"
        self.assertEqual(tf.inspect_access(api, options())["reason"], "PROCESSING")
        api.build["attributes"]["processingState"] = "VALID"; api.state = "READY_FOR_BETA_TESTING"
        self.assertEqual(tf.inspect_access(api, options())["reason"], "WAITING_FOR_INTERNAL_TESTING")

    def test_compliance_requires_explicit_authorization_and_only_fills_nil(self):
        api = FakeASC(); api.state = "MISSING_EXPORT_COMPLIANCE"
        api.build["attributes"]["usesNonExemptEncryption"] = None
        report = tf.inspect_access(api, options(mode="ensure"))
        self.assertEqual(report["reason"], "EXPORT_COMPLIANCE_REQUIRES_ACTION")
        self.assertTrue(all(c[0] == "GET" for c in api.calls))
        tf.inspect_access(api, options(mode="ensure", declare_exempt=True))
        self.assertIs(api.build["attributes"]["usesNonExemptEncryption"], False)
        self.assertEqual(sum(c[0] == "PATCH" for c in api.calls), 1)
        tf.inspect_access(api, options(mode="ensure", declare_exempt=True))
        self.assertEqual(sum(c[0] == "PATCH" for c in api.calls), 1)
        api.build["attributes"]["usesNonExemptEncryption"] = True
        with self.assertRaises(tf.AccessError):
            tf.inspect_access(api, options(mode="ensure", declare_exempt=True))

    def test_unknown_tester_is_not_invited(self):
        api = FakeASC()
        with self.assertRaises(tf.AccessError):
            tf.inspect_access(api, options(mode="ensure", tester_id=["unknown"]))
        self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_existing_internal_tester_can_be_reused_but_never_created(self):
        api = FakeASC()
        api.groups.append(resource("betaGroups", "g2", name="Second", isInternalGroup=True, hasAccessToAllBuilds=True))
        api.people["g2"] = []
        tf.inspect_access(api, options(mode="ensure", internal_group_id="g2", tester_id=["tester1"]))
        mutations = [c for c in api.calls if c[0] != "GET"]
        self.assertEqual(mutations[0][1], "/v1/betaGroups/g2/relationships/betaTesters")
        self.assertTrue(all(c[1] != "/v1/betaTesters" for c in mutations))

    def test_ambiguous_internal_group_or_explicit_external_group_is_rejected(self):
        groups = [resource("betaGroups", "one", isInternalGroup=True), resource("betaGroups", "two", isInternalGroup=True),
            resource("betaGroups", "external", isInternalGroup=False)]
        members = {"one": [{}], "two": [{}]}
        with self.assertRaises(tf.AccessError): tf.choose_group(groups, members)
        with self.assertRaises(tf.AccessError): tf.choose_group(groups, members, "external")
        self.assertEqual(tf.choose_group(groups, members, "one")["id"], "one")

    def test_api_origin_pagination_redirects_and_error_messages_are_bounded(self):
        for url in ["https://attacker.invalid/v1/apps", "http://api.appstoreconnect.apple.com/v1/apps", "//attacker.invalid/v1/apps"]:
            with self.assertRaises(tf.AccessError): tf.trusted_url(url)
        self.assertEqual(tf.trusted_url("/v1/apps"), tf.ORIGIN + "/v1/apps")
        self.assertIsNone(tf.NoRedirect().redirect_request(None, None, 302, "", {}, "https://attacker.invalid"))
        self.assertNotIn("owner@example.com", str(tf.APIError(400, ["owner@example.com", "INVALID_REQUEST"])))
        with self.assertRaises(tf.AccessError): tf.ASC({})  # Refuses local credentials before parsing any key.

    def test_foreign_pagination_link_is_rejected_before_a_second_request(self):
        api = object.__new__(tf.ASC)
        calls = []
        def request(method, path, params=None):
            calls.append(path)
            return {"data": [], "links": {"next": "https://attacker.invalid/v1/users"}}
        api.request = request
        with self.assertRaises(tf.AccessError):
            api.listing("/v1/users")
        self.assertEqual(calls, ["/v1/users"])

    def test_jwt_is_es256_and_contains_only_the_required_short_lived_claims(self):
        from cryptography.hazmat.primitives import serialization, hashes
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        key = ec.generate_private_key(ec.SECP256R1())
        pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
        env = dict(GITHUB_ACTIONS="true", GITHUB_REF="refs/heads/main", GITHUB_REPOSITORY="qianquandong/WatchingU",
            APP_STORE_CONNECT_API_KEY_ID="KEY1234567", APP_STORE_CONNECT_API_ISSUER_ID="issuer",
            APP_STORE_CONNECT_API_PRIVATE_KEY_BASE64=base64.b64encode(pem).decode())
        token = tf.ASC(env).token()
        header, payload, encoded = token.split(".")
        claims = json.loads(base64.urlsafe_b64decode(payload + "=="))
        self.assertEqual(claims["aud"], "appstoreconnect-v1")
        self.assertLess(claims["exp"] - claims["iat"], 1200)
        sig = base64.urlsafe_b64decode(encoded + "==")
        self.assertEqual(len(sig), 64)
        r, s = int.from_bytes(sig[:32], "big"), int.from_bytes(sig[32:], "big")
        key.public_key().verify(utils.encode_dss_signature(r, s), (header + "." + payload).encode(), ec.ECDSA(hashes.SHA256()))


if __name__ == "__main__":
    unittest.main()
