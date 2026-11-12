"""alarm-telegram: чаты проектов. Без сети: api() подменён.

Запуск: python3 -m unittest discover -s ansible/roles/netdata/tests -v"""
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from unittest import mock

FILES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "files")
sys.path.insert(0, FILES)
os.environ["ALARM_LIB_DIR"] = FILES


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(FILES, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


at = load("alarm_telegram", "alarm-telegram.py")
import alarmroutes  # noqa: E402

OWNER = "111"
PROJECT = "-1009"
ROUTES = {
    "owner_chats": [OWNER],
    "status_json": "",
    "routes": [{"name": "val-id", "chats": [PROJECT], "pm2": ["val-id-api", "val-id-worker"],
                "prefix": "val_id", "required": [], "probes": {"val_id_health": "https://val-id.ru/healthz"}}],
}
PM2_DOWN = dict(name="pm2_app_down", chart="app.pm2_val-id-api_processes", src="line=14,file=/etc/netdata/health.d/pm2.conf",
                summary="pm2 app pm2_val-id-api is down", info="pm2 app pm2_val-id-api has had no running processes",
                alarm_id="7", host="russia-03", value_string="0 processes")


class Fake:
    """Подмена api(): журнал вызовов, сбой по чату."""

    def __init__(self, fail=()):
        self.calls, self.fail, self.n, self.sent = [], set(fail), 100, {}

    def __call__(self, method, **p):
        if p.get("chat_id") in self.fail:
            raise OSError("telegram down")
        self.calls.append((method, p))
        if method == "sendMessage":
            self.n += 1
            self.sent[p["chat_id"]] = self.n
            return {"message_id": self.n}
        return {}

    def to(self, chat):
        return [(m, p) for m, p in self.calls if p["chat_id"] == chat]


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        at.STATE_DIR = os.path.join(self.tmp.name, "state")
        self.routes = os.path.join(self.tmp.name, "routes.json")
        self.write_routes(ROUTES)

    def write_routes(self, cfg):
        with open(self.routes, "w") as f:
            json.dump(cfg, f)

    def run_alarm(self, fake, status, when, **alarm):
        envs = {"ALARM_ROUTES": self.routes, "status": status, "when": str(when), "TELEGRAM_BOT_TOKEN": "t", **alarm}
        err = io.StringIO()
        with mock.patch.dict(os.environ, envs), mock.patch.object(at, "api", fake), redirect_stderr(err):
            with self.assertRaises(SystemExit) as ex:
                with mock.patch.object(sys, "argv", ["alarm-telegram", OWNER]):
                    at.main()
        return ex.exception.code, err.getvalue()


class ProjectChats(Base):
    def test_pm2_down_goes_to_project_chat(self):
        fake = Fake()
        code, _ = self.run_alarm(fake, "CRITICAL", 1_700_000_000, **PM2_DOWN)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.to(OWNER)), 1)
        (method, p), = fake.to(PROJECT)
        self.assertEqual(method, "sendMessage")
        self.assertIn("val-id</b> недоступен — процесс val-id-api не запущен", p["text"])
        self.assertIn("🕒 Началось:", p["text"])
        # без ноды, чарта и ссылки на netdata, без «·»
        for leak in ("russia-03", "app.pm2_", "href", "·"):
            self.assertNotIn(leak, p["text"])
        # чат владельца — прежний текст с нодой и чартом
        self.assertIn("russia-03 is critical", fake.to(OWNER)[0][1]["text"])

    def test_health_probe_names_url(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, name="val_id_health_down",
                       chart="httpcheck_val_id_health.request_status", alarm_id="9", host="russia-03",
                       src="line=10,file=/etc/netdata/health.d/val-id.conf")
        self.assertIn("не отвечает https://val-id.ru/healthz", fake.to(PROJECT)[0][1]["text"])

    def test_metric_alarm_stays_with_owner(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, name="val_id_chz_auth_failing",
                       chart="prometheus_val_id.znakhub_chz_errors_last_hour-kind=auth", alarm_id="8",
                       host="russia-03", src="line=25,file=/etc/netdata/health.d/val-id.conf")
        self.assertEqual(len(fake.to(OWNER)), 1)
        self.assertEqual(fake.to(PROJECT), [])

    def test_other_project_stays_with_owner(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, name="pm2_app_down", chart="app.pm2_jobs_processes",
                       alarm_id="5", host="finland-01", src="line=14,file=/etc/netdata/health.d/pm2.conf")
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, name="jobs_health_down",
                       chart="httpcheck_jobs.request_status", alarm_id="6", host="russia-03",
                       src="line=3,file=/etc/netdata/health.d/jobs.conf")
        self.assertEqual(len(fake.to(OWNER)), 2)
        self.assertEqual(fake.to(PROJECT), [])

    def test_clear_edits_project_message(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, **PM2_DOWN)
        project_id = fake.sent[PROJECT]
        self.assertNotEqual(project_id, fake.sent[OWNER])
        self.run_alarm(fake, "WARNING", 1_700_000_100, **PM2_DOWN)
        self.assertEqual(len(fake.to(PROJECT)), 1, "WARNING чат проекта не трогает")
        self.run_alarm(fake, "CLEAR", 1_700_003_700, **PM2_DOWN)
        method, p = fake.to(PROJECT)[-1]
        self.assertEqual((method, p["message_id"]), ("editMessageText", project_id))
        self.assertIn("снова работает", p["text"])
        self.assertIn("Было: процесс val-id-api не запущен", p["text"])
        self.assertIn("✅ Восстановлено:", p["text"])
        self.assertIn("⏱ Длилось: 1 ч 2 мин", p["text"])
        # у владельца своё сообщение и своё редактирование
        self.assertEqual(fake.to(OWNER)[-1][1]["message_id"], fake.sent[OWNER])
        # эпизоды обоих чатов закрыты
        self.assertEqual(os.listdir(at.STATE_DIR), [".lock"])

    def test_clear_without_episode_is_silent_for_project(self):
        fake = Fake()
        self.run_alarm(fake, "CLEAR", 1_700_000_000, non_clear_duration="60", **PM2_DOWN)
        self.assertEqual(len(fake.to(OWNER)), 1)  # владельцу — тихое «решено», как раньше
        self.assertEqual(fake.to(PROJECT), [])

    def test_empty_routes_behaves_as_before(self):
        for cfg in ({"owner_chats": [OWNER], "status_json": "", "routes": []}, None):
            if cfg is None:
                os.remove(self.routes)
            else:
                self.write_routes(cfg)
            fake = Fake()
            code, err = self.run_alarm(fake, "CRITICAL", 1_700_000_000, **PM2_DOWN)
            self.assertEqual((code, err), (0, ""))
            self.assertEqual([p["chat_id"] for _, p in fake.calls], [OWNER])

    def test_project_failure_keeps_owner(self):
        fake = Fake(fail={PROJECT})
        code, err = self.run_alarm(fake, "CRITICAL", 1_700_000_000, **PM2_DOWN)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.to(OWNER)), 1)
        self.assertIn("val-id -1009", err)

    def test_owner_failure_is_visible_and_project_still_sent(self):
        fake = Fake(fail={OWNER})
        code, _ = self.run_alarm(fake, "CRITICAL", 1_700_000_000, **PM2_DOWN)
        self.assertEqual(code, 1)
        self.assertEqual(len(fake.to(PROJECT)), 1)

    def test_owner_chat_listed_as_project_chat_not_doubled(self):
        cfg = json.loads(json.dumps(ROUTES))
        cfg["routes"][0]["chats"] = [OWNER]
        self.write_routes(cfg)
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, **PM2_DOWN)
        self.assertEqual(len(fake.calls), 1)


class Routing(unittest.TestCase):
    routes = ROUTES["routes"] + [{"name": "val", "chats": ["-1"], "pm2": [], "prefix": "val"}]

    def test_longest_key_wins(self):
        r = alarmroutes.route_for(self.routes, "val_id_health_down", "httpcheck_val_id_health.request_status")
        self.assertEqual(r["name"], "val-id")

    def test_src_formats(self):
        for src in ("line=3,file=/etc/netdata/health.d/val-id.conf", "3@/etc/netdata/health.d/val-id.conf"):
            r = alarmroutes.route_for(ROUTES["routes"], "something_down", "x.y", src)
            self.assertEqual(r["name"], "val-id")

    def test_required_extends_simple(self):
        route = dict(ROUTES["routes"][0], required=["val_id_worker_stalled"])
        self.assertTrue(alarmroutes.is_simple(route, "val_id_worker_stalled"))
        self.assertTrue(alarmroutes.is_simple(route, "pm2_app_down"))
        self.assertFalse(alarmroutes.is_simple(route, "val_id_exports_failing"))

    def test_loopback_probe_url_hidden(self):
        route = {"probes": {"jobs": "http://127.0.0.1:8097/healthz"}}
        self.assertEqual(alarmroutes.cause(route, "jobs_health_down", "httpcheck_jobs.request_status"),
                         "не отвечает проверка здоровья")

    def test_required_regex_matches_status_page(self):
        with open(os.path.join(FILES, "status-snapshot.py")) as f:
            m = re.search(r"^REQUIRED = r'(.+)'$", f.read(), re.M)
        self.assertEqual(m.group(1), alarmroutes.REQUIRED)


if __name__ == "__main__":
    unittest.main()
