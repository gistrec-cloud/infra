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


class Probes(unittest.TestCase):
    def test_quiet_alert_probe_stays_out_of_uptime_history(self):
        probes, _ = ss.probes([
            alarm("clear_transcript_bot_healthcheck", "CLEAR", "httpcheck_cleartranscript.request_status"),
            alarm("clear_transcript_bot_failure_spike", "CRITICAL",
                  "httpcheck_clear_transcript_bot_failure_spike.request_status"),
        ])
        self.assertEqual([p["chart"] for p in probes], ["httpcheck_cleartranscript.request_status"])


class Statuses(unittest.TestCase):
    def test_removed_alarm_is_no_data_not_a_crash(self):
        for status in ("REMOVED", "RAISED", ""):
            got = ss.known_status(status)
            self.assertEqual((got, ss.RANK[got], ss.CLS[got]), ("UNDEFINED", 1, "nodata"))
        for status in ss.RANK:
            self.assertEqual(ss.known_status(status), status)
            self.assertIn(status, ss.CLS)

    def test_build_survives_removed(self):
        alarms = {"a": dict(id=1, name="val_id_health_down", chart="httpcheck_val_id_health.request_status",
                            status="REMOVED", last_updated=2_000_000_000, last_status_change=2_000_000_000,
                            source="line=10,file=/etc/netdata/health.d/val-id.conf", value_string="-", info="i",
                            summary="", units="ok", recipient="botcrit")}

        def get(path):
            if path.endswith("/api/v1/info"):
                return {"mirrored_hosts": ["russia-03"]}
            if "/api/v1/alarms" in path:
                return {"alarms": alarms}
            raise OSError("no network in tests")

        cfg = {"parent": "russia-03", "prod": ["val-id"], "hosts": {}, "required": {}, "sentry": {}}
        with mock.patch.object(ss, "get", get), mock.patch.object(ss.time, "time", lambda: 2_000_000_000), \
                mock.patch.object(ss, "restart", lambda *a: None), mock.patch.object(ss, "history", lambda *a: {}):
            snap = ss.build(cfg)
        val, = [p for p in snap["projects"] if p["name"] == "val-id"]
        self.assertEqual((val["worst"], val["outage"]), ("UNDEFINED", False))


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


class MissingProject(unittest.TestCase):
    """prod без алармов на паренте: простой, но не сразу после рестарта парента."""
    CFG = dict(parent="russia-03", prod=["lost"], hosts={}, sentry={})

    def build(self, uptime):
        def get(path):
            if path == "/api/v1/info":
                return {"mirrored_hosts": ["russia-03"]}
            if "netdata.uptime" in path:
                if uptime is None:
                    raise OSError("no chart")
                return {"data": [[1, uptime]]}
            return {"alarms": {}}
        with mock.patch.object(ss, "get", get):
            snap = ss.build(self.CFG)
        (p,) = snap["projects"]
        return p, snap["summary"], ss.public(snap)["projects"][0]["dot"]

    def test_outage_when_parent_is_long_up(self):
        p, summary, dot = self.build(86_400)
        self.assertEqual((p["worst"], p["outage"], summary["outage"], dot), ("CRITICAL", True, 1, "outage"))

    def test_no_data_right_after_parent_restart(self):
        p, summary, dot = self.build(120)
        self.assertEqual((p["worst"], p["outage"], dot), ("UNINITIALIZED", False, "nodata"))
        self.assertEqual((summary["outage"], summary["crit"], summary["major"]), (0, 0, False))
        self.assertIn("just restarted", p["alarms"][0]["info"])

    def test_unknown_uptime_keeps_outage(self):
        p, _, dot = self.build(None)
        self.assertEqual((p["worst"], p["outage"], dot), ("CRITICAL", True, "outage"))


class Projects(unittest.TestCase):
    def src(self, name):
        return f"line=1,file=/etc/netdata/health.d/{name}.conf"

    def test_askads_deployments_are_separate_rows(self):
        cases = [
            ("askads_health_down", "httpcheck_askads_ru.request_status", self.src("askads_ru"), "askads-ru"),
            ("askads_mcp_down", "httpcheck_askads_mcp_ru.request_status", self.src("askads_ru"), "askads-ru"),
            ("askads_health_down", "httpcheck_askads_cloud.request_status", self.src("askads_cloud"), "askads-cloud"),
            ("askads_mcp_down", "httpcheck_askads_mcp_cloud.request_status", self.src("askads_cloud"), "askads-cloud"),
            ("pm2_app_down", "app.pm2_askads-ru_processes", self.src("pm2"), "askads-ru"),
            ("pm2_app_down", "app.pm2_askads-cloud_processes", self.src("pm2"), "askads-cloud"),
            ("askads_direct_api_down", "httpcheck_askads_direct_ru.request_status", self.src("askads_ru"),
             "Yandex Direct API"),
        ]
        groups = {}
        for name, chart, source, want in cases:
            got = ss.project_of(dict(name=name, chart=chart, source=source))
            self.assertEqual(got, want, (name, chart))
            groups.setdefault(got, []).append(name)
        ss.merge_prefixes(groups)
        self.assertEqual(sorted(groups), ["Yandex Direct API", "askads-cloud", "askads-ru"])

    def test_askads_alarm_files_name_one_deployment_each(self):
        health = os.path.join(FILES, "..", "..", "..", "files", "netdata", "health.d")
        self.assertFalse(os.path.exists(os.path.join(health, "askads.conf")))
        for name, own, other in (("askads_ru", "_ru", "_cloud"), ("askads_cloud", "_cloud", "_ru")):
            with open(os.path.join(health, name + ".conf")) as f:
                jobs = [w for line in f if line.startswith("chart labels:")
                        for w in line.split("_collect_job=", 1)[1].split()]
            self.assertTrue(jobs)
            for job in jobs:
                self.assertTrue(job.endswith(own), (name, job))
                self.assertFalse(job.endswith(other), (name, job))


if __name__ == "__main__":
    unittest.main()
