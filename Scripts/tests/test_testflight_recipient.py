import contextlib
import copy
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
        self.tester_apps = {"tester1": [dict(type="apps", id=tf.APP_ID)]}
        self.expired = False
        self.invitation_error = False
        self.membership_state_override = None
        self.honor_app_filter = False
        self.creation_state = "INVITED"
        self.creation_error = None
        self.creation_readback = True
        self.processing_state = "VALID"
        self.internal_state = "IN_BETA_TESTING"

    def listing(self, path, params=None):
        self.calls.append(("GET", path, params))
        if path == "/v1/apps": return [resource("apps", tf.APP_ID, bundleId=tf.BUNDLE_ID)]
        if path == "/v1/users": return self.users
        if path == "/v1/users/user1/relationships/visibleApps": return self.visible
        if path == "/v1/betaTesters":
            if self.honor_app_filter:
                return [p for p in self.people if any(a.get("id") == params.get("filter[apps]")
                    for a in self.tester_apps.get(p["id"], []))]
            return self.people
        for tester, apps in self.tester_apps.items():
            if path == f"/v1/betaTesters/{tester}/relationships/apps": return apps
        if path == f"/v1/apps/{tf.APP_ID}/betaGroups": return self.groups
        if path == "/v1/builds": return [resource("builds", "build1", version=tf.BUILD_NUMBER, processingState=self.processing_state, expired=self.expired)]
        if path == f"/v1/betaGroups/{tf.GROUP_ID}/betaTesters": return self.members
        if path == f"/v1/betaGroups/{tf.GROUP_ID}/relationships/builds": return self.assigned
        raise AssertionError("Unexpected API read")

    def request(self, method, path, params=None, body=None):
        self.calls.append((method, path, body))
        if method == "GET" and path == f"/v1/apps/{tf.APP_ID}": return {"data": resource("apps", tf.APP_ID, name="DayTape", bundleId=tf.BUNDLE_ID)}
        if method == "GET" and path == "/v1/builds/build1": return {"data": resource("builds", "build1", version=tf.BUILD_NUMBER, processingState=self.processing_state, buildAudienceType="INTERNAL_ONLY", expired=self.expired)}
        if method == "GET" and path == "/v1/builds/build1/buildBetaDetail": return {"data": resource("buildBetaDetails", "d1", internalBuildState=self.internal_state, externalBuildState="READY_FOR_BETA_SUBMISSION")}
        if method == "POST" and path == "/v1/betaTesters":
            person = resource("betaTesters", "created1", email=body["data"]["attributes"]["email"], state=self.creation_state)
            if self.creation_readback:
                self.people.append(person); self.members.append(copy.deepcopy(person))
                self.tester_apps["created1"] = [dict(type="apps", id=tf.APP_ID)]
            if self.creation_error == "network": raise tf.AccessError("private creation detail " + self.target)
            if self.creation_error == "conflict": raise tf.APIError(409, ["ENTITY_ERROR.ATTRIBUTE.INVALID"])
            return {"data": person}
        if method == "POST" and path == f"/v1/betaGroups/{tf.GROUP_ID}/relationships/betaTesters":
            identity = body["data"][0]["id"]
            person = next(copy.deepcopy(p) for p in self.people if p["id"] == identity)
            if self.membership_state_override is not None: person["attributes"]["state"] = self.membership_state_override
            self.members.append(person)
            return {}
        if method == "POST" and path == "/v1/betaTesterInvitations":
            if self.invitation_error: raise tf.AccessError("untrusted detail " + self.target)
            identity = body["data"]["relationships"]["betaTester"]["data"]["id"]
            for person in self.people + self.members:
                if person["id"] == identity: person["attributes"]["state"] = "INVITED"
            return {}
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
        query = next(c[2] for c in api.calls if c[1] == "/v1/betaTesters")
        self.assertEqual(query["filter[apps]"], tf.APP_ID)

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
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            status = tf.main(["--email", api.target], {"TF_INVITATION_EMAIL": api.target}, lambda: api)
        self.assertEqual(status, 2); self.assertNotIn(api.target, output.getvalue())

    def test_exact_email_duplicates_are_disambiguated_only_by_verified_app_relationship(self):
        api = FakeASC()
        second = resource("betaTesters", "tester2", email=api.target, state="ACCEPTED")
        api.people.append(second)
        api.tester_apps["tester1"] = [dict(type="apps", id="anotherApp")]
        api.tester_apps["tester2"] = [dict(type="apps", id=tf.APP_ID)]
        api.members = [second]
        report = tf.inspect_recipient(api, api.target)
        self.assertEqual(report["target_tester_candidate_count"], 2)
        self.assertEqual(report["target_tester_count"], 1)
        self.assertEqual(report["target_tester_id"], "tester2")
        self.assertTrue(report["ready"])
        api.tester_apps["tester1"] = [dict(type="apps", id=tf.APP_ID)]
        report = tf.invite_internal(api, api.target)
        self.assertEqual(report["reason"], "TARGET_TESTER_AMBIGUOUS")
        self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_missing_tester_wrong_scope_or_missing_app_access_never_create_or_mutate(self):
        for configure in [lambda a: a.people.clear(),
                          lambda a: a.tester_apps.update(tester1=[]),
                          lambda a: a.users[0]["attributes"].update(allAppsVisible=False),
                          lambda a: a.users[0]["attributes"].update(roles=["SALES"]),
                          lambda a: a.users.clear()]:
            api = FakeASC(); api.visible = []; configure(api)
            report = tf.invite_internal(api, api.target)
            self.assertFalse(report["eligible"] and report["ready"])
            self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_invited_accepted_installed_and_revoked_are_never_reinvited(self):
        for state in ["INVITED", "ACCEPTED", "INSTALLED", "REVOKED"]:
            api = FakeASC(); api.people[0]["attributes"]["state"] = state
            report = tf.invite_internal(api, api.target)
            self.assertFalse(report["invitation_attempted"])
            self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_adds_only_exact_existing_target_then_invites_not_invited_once(self):
        api = FakeASC(); api.people[0]["attributes"]["state"] = "NOT_INVITED"; api.members = []
        api.people.append(resource("betaTesters", "unrelated", email="someone@example.test", state="NOT_INVITED"))
        report = tf.invite_internal(api, api.target)
        self.assertTrue(report["membership_added"]); self.assertTrue(report["invitation_attempted"])
        self.assertEqual(report["target_tester_state"], "INVITED")
        self.assertEqual(report["reason"], "ACCEPT_EXISTING_INVITATION")
        mutations = [c for c in api.calls if c[0] != "GET"]
        self.assertEqual(mutations, [
            ("POST", f"/v1/betaGroups/{tf.GROUP_ID}/relationships/betaTesters", {"data": [{"type": "betaTesters", "id": "tester1"}]}),
            ("POST", "/v1/betaTesterInvitations", {"data": {"type": "betaTesterInvitations", "relationships": {
                "app": {"data": {"type": "apps", "id": tf.APP_ID}},
                "betaTester": {"data": {"type": "betaTesters", "id": "tester1"}}}}})])
        self.assertNotIn(api.target, json.dumps(report))

    def test_prior_invited_state_never_resends_even_if_new_membership_is_lagging(self):
        api = FakeASC(); api.people[0]["attributes"]["state"] = "INVITED"; api.members = []
        api.membership_state_override = "NOT_INVITED"
        report = tf.invite_internal(api, api.target)
        self.assertFalse(report["invitation_attempted"])
        self.assertEqual(sum(c[0] == "POST" for c in api.calls), 1)

    def test_invitation_failure_is_not_retried_or_leaked(self):
        api = FakeASC(); api.people[0]["attributes"]["state"] = "NOT_INVITED"; api.invitation_error = True
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = tf.main(["--mode", "invite-internal"], {"TF_INVITATION_EMAIL": api.target}, lambda: api)
        self.assertEqual(result, 3); self.assertNotIn(api.target, output.getvalue())
        self.assertEqual(json.loads(output.getvalue())["reason"], "INVITATION_RESULT_UNCONFIRMED")
        self.assertEqual(sum(c[0] == "POST" for c in api.calls), 1)

    def test_unknown_or_expired_build_cannot_mutate(self):
        for value, reason in [(None, "BUILD_EXPIRY_UNKNOWN"), (True, "BUILD_EXPIRED")]:
            api = FakeASC(); api.expired = value; api.people[0]["attributes"]["state"] = "NOT_INVITED"
            report = tf.invite_internal(api, api.target)
            self.assertEqual(report["reason"], reason)
            self.assertTrue(all(c[0] == "GET" for c in api.calls))


class RecipientCreationTests(unittest.TestCase):
    def missing_app_tester(self):
        api = FakeASC()
        api.members = []; api.honor_app_filter = True
        api.people = [resource("betaTesters", "foreign1", email=api.target, state="NOT_INVITED"),
                      resource("betaTesters", "foreign2", email=api.target, state="ACCEPTED")]
        api.tester_apps = {"foreign1": [dict(type="apps", id="otherApp1")],
                           "foreign2": [dict(type="apps", id="otherApp2")]}
        return api

    def test_explicit_invite_creates_only_selected_address_and_existing_internal_group(self):
        api = self.missing_app_tester()
        report = tf.invite_internal(api, api.target)
        mutations = [c for c in api.calls if c[0] != "GET"]
        self.assertEqual(mutations, [("POST", "/v1/betaTesters", {"data": {
            "type": "betaTesters", "attributes": {"email": api.target},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": tf.GROUP_ID}]}}
        }})])
        self.assertTrue(report["tester_creation_attempted"])
        self.assertTrue(report["tester_creation_confirmed"])
        self.assertEqual(report["target_tester_id"], "created1")
        self.assertEqual(report["target_tester_state"], "INVITED")
        self.assertEqual(report["reason"], "ACCEPT_EXISTING_INVITATION")
        self.assertTrue(report["target_group_member"])
        self.assertFalse(report["invitation_attempted"])
        self.assertNotIn(api.target, json.dumps(report))
        post_index = next(i for i, c in enumerate(api.calls) if c[0] == "POST")
        self.assertTrue(all(c[0] == "GET" for c in api.calls[post_index + 1:]))
        api.calls = []
        tf.invite_internal(api, api.target)
        self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_creation_requires_all_current_user_app_group_build_and_zero_scope_proofs(self):
        cases = [lambda a: a.users.clear(),
                 lambda a: a.users.extend(copy.deepcopy(a.users)),
                 lambda a: a.users[0]["attributes"].update(roles=["SALES"]),
                 lambda a: (a.users[0]["attributes"].update(allAppsVisible=False), a.visible.clear()),
                 lambda a: a.groups.clear(), lambda a: a.assigned.clear(),
                 lambda a: setattr(a, "expired", None), lambda a: setattr(a, "expired", True),
                 lambda a: setattr(a, "processing_state", "PROCESSING"),
                 lambda a: setattr(a, "internal_state", "MISSING_EXPORT_COMPLIANCE"),
                 # Inconsistent server filtering must not turn an unrelated global record into a new one.
                 lambda a: setattr(a, "honor_app_filter", False)]
        for configure in cases:
            api = self.missing_app_tester(); configure(api)
            report = tf.invite_internal(api, api.target)
            self.assertFalse(report["tester_creation_attempted"])
            self.assertTrue(all(c[0] == "GET" for c in api.calls))

    def test_creation_conflict_or_lost_response_only_reads_back_and_never_invites(self):
        for failure, reason in [("network", "TESTER_CREATION_RESULT_UNCONFIRMED"),
                                ("conflict", "TESTER_CREATION_CONFLICT_RECHECKED")]:
            api = self.missing_app_tester(); api.creation_error = failure; api.creation_state = "NOT_INVITED"
            report = tf.invite_internal(api, api.target)
            self.assertEqual(report["reason"], reason); self.assertFalse(report["ready"])
            self.assertEqual(report["target_tester_state"], "NOT_INVITED")
            self.assertFalse(report["invitation_attempted"])
            mutations = [c for c in api.calls if c[0] != "GET"]
            self.assertEqual(len(mutations), 1); self.assertEqual(mutations[0][1], "/v1/betaTesters")
            post_index = next(i for i, c in enumerate(api.calls) if c[0] == "POST")
            self.assertTrue(all(c[0] == "GET" for c in api.calls[post_index + 1:]))
            self.assertNotIn(api.target, json.dumps(report))

    def test_successful_create_without_authoritative_readback_is_waiting_not_invited(self):
        api = self.missing_app_tester(); api.creation_readback = False
        report = tf.invite_internal(api, api.target)
        self.assertEqual(report["reason"], "TARGET_TESTER_CREATION_WAITING")
        self.assertFalse(report["tester_creation_confirmed"]); self.assertFalse(report["ready"])
        self.assertFalse(report["invitation_attempted"])
        self.assertEqual(sum(c[0] == "POST" for c in api.calls), 1)

    def test_confirmed_not_invited_new_tester_has_one_explicit_app_and_tester_invitation(self):
        api = self.missing_app_tester(); api.creation_state = "NOT_INVITED"
        report = tf.invite_internal(api, api.target)
        self.assertTrue(report["tester_creation_confirmed"]); self.assertTrue(report["invitation_attempted"])
        mutations = [c for c in api.calls if c[0] != "GET"]
        self.assertEqual([c[1] for c in mutations], ["/v1/betaTesters", "/v1/betaTesterInvitations"])
        invitation = mutations[1][2]["data"]["relationships"]
        self.assertEqual(invitation, {"app": {"data": {"type": "apps", "id": tf.APP_ID}},
                                     "betaTester": {"data": {"type": "betaTesters", "id": "created1"}}})
        self.assertEqual(report["target_tester_state"], "INVITED")

    def test_inspect_zero_app_tester_is_read_only_even_when_creation_would_be_eligible(self):
        api = self.missing_app_tester()
        report = tf.inspect_recipient(api, api.target)
        self.assertEqual(report["reason"], "TARGET_TESTER_NOT_FOUND")
        self.assertTrue(all(c[0] == "GET" for c in api.calls))


if __name__ == "__main__": unittest.main()
