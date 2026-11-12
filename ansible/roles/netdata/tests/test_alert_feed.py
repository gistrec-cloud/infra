"""status-snapshot feed(): данные для команд бота алертов. Без сети."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

FILES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "files")
sys.path.insert(0, FILES)
spec = importlib.util.spec_from_file_location("status_snapshot", os.path.join(FILES, "status-snapshot.py"))
ss = importlib.util.module_from_spec(spec)
with mock.patch.object(sys, "argv", ["status-snapshot"]):
    spec.loader.exec_module(ss)


def alarm(name, status, chart, since=None):
    return dict(name=name, chart=chart, status=status, value="1", info="i", host="russia-03",
                since=since, stock=False)


SNAP = {
    "generated_at": 1_700_000_000,
    "projects": [
        {"name": "val-id", "kind": "prod", "worst": "CRITICAL", "outage": True, "hosts": ["russia-03"],
         "link_host": "russia-03", "sentry": None, "restart": None, "history": {}, "alarms": [
             alarm("val_id_health_down", "CRITICAL", "httpcheck_val_id_health.request_status", 1_699_999_000),
             alarm("pm2_app_down", "CLEAR", "app.pm2_val-id-api_processes"),
             alarm("val_id_chz_auth_failing", "WARNING", "prometheus_val_id.x", 1_699_999_500),
         ]},
        {"name": "jobs", "kind": "prod", "worst": "CLEAR", "outage": False, "hosts": ["finland-01"],
         "link_host": "finland-01", "sentry": None, "restart": None, "history": {},
         "alarms": [alarm("jobs_health_down", "CLEAR", "httpcheck_jobs.request_status")]},
        {"name": "lost", "kind": "prod", "worst": "CRITICAL", "outage": True, "hosts": [],
         "link_host": "russia-03", "sentry": None, "restart": None, "history": {},
         "alarms": [dict(name="project_missing", chart="", status="CRITICAL", host="russia-03", missing=True)]},
    ],
}
ROUTES = {"owner_chats": ["111"], "status_json": "", "routes": [
    {"name": "val-id", "chats": ["-1009:7"], "pm2": ["val-id-api"], "prefix": "val_id", "required": [],
     "probes": {"val_id_health": "https://val-id.ru/healthz"}},
    {"name": "gone", "chats": ["-1005"], "pm2": [], "prefix": "gone", "required": [], "probes": {}},
]}


class Feed(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.routes = os.path.join(tmp.name, "routes.json")
        with open(self.routes, "w") as f:
            json.dump(ROUTES, f)

    def test_project_checks_are_downtime_only_and_named(self):
        out = ss.feed(SNAP, self.routes)
        val, gone = out["chats"]
        self.assertEqual(val["project"], "val-id")
        self.assertEqual(val["chats"], ["-1009:7"])
        self.assertEqual([(c["title"], c["status"]) for c in val["checks"]],
                         [("ответ https://val-id.ru/healthz", "CRITICAL"), ("процесс val-id-api", "CLEAR")])
        self.assertEqual(val["checks"][0]["since"], 1_699_999_000)
        self.assertEqual((gone["found"], gone["checks"]), (False, []))

    def test_no_secrets_nodes_or_charts(self):
        text = json.dumps(ss.feed(SNAP, self.routes), ensure_ascii=False)
        for leak in ("russia-03", "finland-01", "httpcheck_", "app.pm2", "prometheus_", "token", "href"):
            self.assertNotIn(leak, text)

    def test_owner_projects(self):
        out = ss.feed(SNAP, self.routes)
        self.assertEqual(out["owner_chats"], ["111"])
        self.assertEqual(out["generated_at"], 1_700_000_000)
        self.assertEqual([p["name"] for p in out["projects"]], ["val-id", "jobs", "lost"])
        self.assertEqual(out["projects"][2]["alarms"], [{"name": "project_missing", "status": "CRITICAL", "since": None}])

    def test_no_routes_file(self):
        out = ss.feed(SNAP, self.routes + ".missing")
        self.assertEqual((out["chats"], out["owner_chats"]), ([], []))


if __name__ == "__main__":
    unittest.main()
