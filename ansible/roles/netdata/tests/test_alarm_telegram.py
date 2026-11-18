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
        # чат владельца — свой текст с нодой и чартом
        owner = fake.to(OWNER)[0][1]["text"]
        self.assertIn("russia-03, с", owner)
        self.assertIn("app.pm2_val-id-api_processes", owner)
        self.assertNotIn("·", owner)

    def test_health_probe_names_url(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, name="val_id_health_down",
                       chart="httpcheck_val_id_health.request_status", alarm_id="9", host="russia-03",
                       src="line=10,file=/etc/netdata/health.d/val-id.conf")
        self.assertIn("не отвечает https://val-id.ru/healthz", fake.to(PROJECT)[0][1]["text"])

    def test_metric_alarm_stays_with_owner(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", 1_700_000_000, name="val_id_chz_auth_failing",
                       chart="prometheus_val_id.val_id_chz_errors_last_hour-kind=auth", alarm_id="8",
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


MARKER = dict(name="clear_transcript_bot_marker_missing", alarm_id="3", host="finland-01",
              chart="filecheck_clear_transcript_bot_remind_pending.file_/home/gistrec/x_existence_status",
              summary="clear transcript bot marker missing", units="status",
              info="ClearTranscriptBot: нет файла-метки remind_pending", goto_url="https://stats/x",
              src="line=133,file=/etc/netdata/health.d/clear-transcript-bot.conf")
T0 = 1_763_211_180  # 15.11.2025 15:53 МСК


class OwnerText(Base):
    def test_open_episode(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", T0, value_string="0 status", **MARKER)
        self.assertEqual(fake.to(OWNER)[0][1]["text"], "\n".join([
            "🔴 Критично: <b>clear transcript bot marker missing</b>",
            "ClearTranscriptBot: нет файла-метки remind_pending",
            "",
            "finland-01, с 15:53 МСК, ⏳ не решено",
            '<a href="https://stats/x">netdata ↗</a>',
            f"<blockquote expandable>clear_transcript_bot_marker_missing\n{MARKER['chart']}</blockquote>",
        ]))

    def test_clear_one_line_span_and_quiet_status_value(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", T0, value_string="0 status", **MARKER)
        self.run_alarm(fake, "CLEAR", T0 + 540, **MARKER)
        text = fake.to(OWNER)[-1][1]["text"]
        self.assertTrue(text.startswith("✅ Решено: <b>clear transcript bot marker missing</b>\n"))
        self.assertIn("finland-01, 15:53 → 16:02 МСК (9 мин)", text)
        self.assertNotIn("status)", text)

    def test_value_shown_for_real_units(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", T0, value_string="95%", **dict(MARKER, units="%"))
        self.run_alarm(fake, "CLEAR", T0 + 60, **dict(MARKER, units="%"))
        self.assertIn("missing = 95%</b>", fake.to(OWNER)[0][1]["text"])
        self.assertIn("missing (было 95%)</b>", fake.to(OWNER)[-1][1]["text"])

    def test_date_only_across_midnight(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", T0, **MARKER)
        self.run_alarm(fake, "REMOVED", T0 + 86_400, **MARKER)
        text = fake.to(OWNER)[-1][1]["text"]
        self.assertTrue(text.startswith("⚪️ Алерт удалён: "))
        self.assertIn("15.11 15:53 → 16.11 15:53 МСК (1 д)", text)

    def test_downgrade_to_warning(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", T0, **MARKER)
        self.run_alarm(fake, "WARNING", T0 + 420, **MARKER)
        self.assertIn("с 15:53 МСК, снизилось до warning в 16:00, ⏳ не решено", fake.to(OWNER)[-1][1]["text"])


HEALTH = dict(name="val_id_health_down", chart="httpcheck_val_id_health.request_status", alarm_id="9",
              host="russia-03", src="line=10,file=/etc/netdata/health.d/val-id.conf", units="ok",
              info="Valid: https://val-id.ru/healthz не отвечает", goto_url="https://stats/v")


class Sweep(Base):
    """--sweep: CLEAR не пришёл (алармы пересозданы), эпизод закрывает сверка с API."""

    def api_alarm(self, status="CLEAR", changed=T0 + 600, **over):
        return {"9": {**dict(id=9, name=HEALTH["name"], chart=HEALTH["chart"], status=status, source=HEALTH["src"],
                             info=HEALTH["info"], summary="", units="ok", value_string="1 ok",
                             last_status_change=changed, delay_up_to_timestamp=0), **over}}

    def run_sweep(self, fake, alarms, now):
        err = io.StringIO()
        with mock.patch.dict(os.environ, {"ALARM_ROUTES": self.routes, "TELEGRAM_BOT_TOKEN": "t"}), \
                mock.patch.object(at, "api", fake), redirect_stderr(err), \
                mock.patch.object(at, "host_alarms", lambda host: alarms if host == "russia-03" else {}):
            return at.sweep(now), err.getvalue()

    def open_episode(self, fake):
        self.run_alarm(fake, "CRITICAL", T0, value_string="0 ok", **HEALTH)
        self.assertEqual(len(os.listdir(at.STATE_DIR)), 3)  # владелец, проект, .lock

    def test_clear_alarm_closes_both_chats(self):
        fake = Fake()
        self.open_episode(fake)
        failed, err = self.run_sweep(fake, self.api_alarm(), T0 + 600 + at.SWEEP_GRACE)
        self.assertEqual(failed, 0)
        method, p = fake.to(PROJECT)[-1]
        self.assertEqual((method, p["message_id"]), ("editMessageText", fake.sent[PROJECT]))
        self.assertIn("<b>val-id</b> снова работает", p["text"])
        self.assertIn("Было: не отвечает https://val-id.ru/healthz", p["text"])
        self.assertIn("⏱ Длилось: 10 мин", p["text"])
        method, p = fake.to(OWNER)[-1]
        self.assertEqual((method, p["message_id"]), ("editMessageText", fake.sent[OWNER]))
        self.assertTrue(p["text"].startswith("✅ Решено: <b>val id health down (было 0 ok)</b>"))
        self.assertIn("russia-03, 15:53 → 16:03 МСК (10 мин)", p["text"])
        self.assertIn('<a href="https://stats/v">netdata ↗</a>', p["text"])
        self.assertEqual(os.listdir(at.STATE_DIR), [".lock"])
        self.assertEqual(err.count("sweep: closed"), 2)

    def test_not_clear_or_unknown_is_left_alone(self):
        for alarms in (self.api_alarm("CRITICAL"), self.api_alarm("WARNING"), self.api_alarm("UNINITIALIZED"),
                       self.api_alarm("UNDEFINED"), {}):
            fake = Fake()
            self.open_episode(fake)
            sent = len(fake.calls)
            self.assertEqual(self.run_sweep(fake, alarms, T0 + 9000), (0, ""))
            self.assertEqual(len(fake.calls), sent)
            self.assertEqual(len(os.listdir(at.STATE_DIR)), 3)
            for f in os.listdir(at.STATE_DIR):
                os.remove(os.path.join(at.STATE_DIR, f))

    def test_waits_for_regular_clear(self):
        fake = Fake()
        self.open_episode(fake)
        sent = len(fake.calls)
        # свежий CLEAR и CLEAR с ещё не истёкшим delay down — их закроет штатный путь
        self.run_sweep(fake, self.api_alarm(), T0 + 600 + at.SWEEP_GRACE - 1)
        self.run_sweep(fake, self.api_alarm(delay_up_to_timestamp=T0 + 900), T0 + 900 + at.SWEEP_GRACE - 1)
        self.assertEqual(len(fake.calls), sent)
        self.run_sweep(fake, self.api_alarm(delay_up_to_timestamp=T0 + 900), T0 + 900 + at.SWEEP_GRACE)
        self.assertEqual(os.listdir(at.STATE_DIR), [".lock"])

    def test_telegram_down_retries_next_run(self):
        fake = Fake()
        self.open_episode(fake)
        fake.fail = {OWNER, PROJECT}
        failed, err = self.run_sweep(fake, self.api_alarm(), T0 + 9000)
        self.assertEqual(failed, 1, "после первого сетевого сбоя прогон прекращается")
        self.assertEqual(len(os.listdir(at.STATE_DIR)), 3)
        fake.fail = set()
        self.assertEqual(self.run_sweep(fake, self.api_alarm(), T0 + 9120)[0], 0)
        self.assertEqual(os.listdir(at.STATE_DIR), [".lock"])

    def test_regular_clear_still_works_and_sweep_is_noop(self):
        fake = Fake()
        self.open_episode(fake)
        self.run_alarm(fake, "CLEAR", T0 + 600, **HEALTH)
        sent = len(fake.calls)
        self.assertEqual(self.run_sweep(fake, self.api_alarm(), T0 + 9000), (0, ""))
        self.assertEqual(len(fake.calls), sent)

    def test_metric_alarm_closes_owner_only(self):
        fake = Fake()
        metric = dict(HEALTH, name="val_id_chz_auth_failing", chart="prometheus_val_id.x")
        self.run_alarm(fake, "CRITICAL", T0, **metric)
        alarms = self.api_alarm()
        alarms["9"].update(name=metric["name"], chart=metric["chart"])
        self.run_sweep(fake, alarms, T0 + 9000)
        self.assertEqual(fake.to(PROJECT), [])
        self.assertEqual(fake.to(OWNER)[-1][0], "editMessageText")

    def test_no_state_dir(self):
        self.assertEqual(self.run_sweep(Fake(), {}, T0), (0, ""))


class Mute(Base):
    """Конец заглушки: --sweep открывает эпизоды по горящему и снимает файл."""

    PARENT = 'DEFAULT_RECIPIENT_CUSTOM="111|critical"\nrole_recipients_custom[disk]="111"\n'
    CHILD = ('DEFAULT_RECIPIENT_CUSTOM="disabled"\nrole_recipients_custom[fleetcrit]="111|critical"\n'
             'role_recipients_custom[disk]="111"\n')

    def setUp(self):
        super().setUp()
        self.mute = os.path.join(self.tmp.name, "alarm-mute")
        self.conf = os.path.join(self.tmp.name, "notify.conf")
        self.write_conf(self.PARENT)

    def write_conf(self, text):
        with open(self.conf, "w") as f:
            f.write(text)

    def write_mute(self, until):
        with open(self.mute, "w") as f:
            f.write(f"{until}\nребут finland-01\n")

    def alarm(self, status="CRITICAL", **over):
        return {"9": {**dict(id=9, name=HEALTH["name"], chart=HEALTH["chart"], status=status, source=HEALTH["src"],
                             info=HEALTH["info"], summary="", units="ok", value_string="0 ok", recipient="sysadmin",
                             silenced=False, last_status_change=T0), **over}}

    def run_unmute(self, fake, alarms, now, info=None):
        err = io.StringIO()
        envs = {"ALARM_ROUTES": self.routes, "TELEGRAM_BOT_TOKEN": "t", "ALARM_MUTE": self.mute, "NOTIFY_CONF": self.conf}
        hosts = io.BytesIO(json.dumps({"mirrored_hosts": ["russia-03"]}).encode())
        with mock.patch.dict(os.environ, envs), mock.patch.object(at, "api", fake), redirect_stderr(err), \
                mock.patch.object(at.urllib.request, "urlopen", info or (lambda *a, **k: hosts)), \
                mock.patch.object(at, "host_alarms", lambda host: alarms):
            return at.unmute(now), err.getvalue()

    def test_recipients(self):
        self.assertEqual(at.recipients(self.PARENT, "sysadmin"), {"111": True})
        self.assertEqual(at.recipients(self.PARENT, "disk"), {"111": False})
        self.assertEqual(at.recipients(self.CHILD, "sysadmin"), {})
        self.assertEqual(at.recipients(self.CHILD, "fleetcrit"), {"111": True})
        self.assertEqual(at.recipients(self.CHILD, "sysadmin disk"), {"111": False})

    def test_expired_mute_raises_owner_and_project(self):
        fake = Fake()
        self.write_mute(T0 + 600)
        self.assertEqual(self.run_unmute(fake, self.alarm(), T0 + 660)[0], 0)
        owner = fake.to(OWNER)[0][1]["text"]
        self.assertTrue(owner.startswith("🔴 Критично: <b>val id health down"))
        self.assertIn("russia-03, с 15:53 МСК", owner)  # настоящее начало, не конец заглушки
        self.assertIn("<b>val-id</b> недоступен", fake.to(PROJECT)[0][1]["text"])
        self.assertFalse(os.path.exists(self.mute))
        # дальше эпизод закрывается обычным CLEAR
        self.run_alarm(fake, "CLEAR", T0 + 900, **HEALTH)
        self.assertEqual(fake.to(OWNER)[-1][0], "editMessageText")

    def test_active_mute_is_left_alone(self):
        fake = Fake()
        self.write_mute(T0 + 600)
        self.assertEqual(self.run_unmute(fake, self.alarm(), T0 + 599), (0, ""))
        self.assertEqual(fake.calls, [])
        self.assertTrue(os.path.exists(self.mute))

    def test_no_mute_file(self):
        self.assertEqual(self.run_unmute(Fake(), self.alarm(), T0), (0, ""))

    def test_open_critical_episode_not_repeated(self):
        fake = Fake()
        self.run_alarm(fake, "CRITICAL", T0, value_string="0 ok", **HEALTH)
        sent = len(fake.calls)
        self.write_mute(T0 + 600)
        self.run_unmute(fake, self.alarm(), T0 + 660)
        self.assertEqual(len(fake.calls), sent)
        self.assertFalse(os.path.exists(self.mute))

    def test_warning_episode_escalates_by_reply(self):
        fake = Fake()
        self.write_conf('DEFAULT_RECIPIENT_CUSTOM="111"\n')
        self.run_alarm(fake, "WARNING", T0, **HEALTH)
        first = fake.sent[OWNER]
        self.write_mute(T0 + 600)
        self.run_unmute(fake, self.alarm(), T0 + 660)
        method, p = fake.to(OWNER)[-1]
        self.assertEqual(method, "sendMessage")
        self.assertEqual(json.loads(p["reply_parameters"])["message_id"], first)

    def test_warning_only_for_roles_without_critical_filter(self):
        self.write_mute(T0 + 600)
        fake = Fake()
        self.run_unmute(fake, self.alarm("WARNING"), T0 + 660)
        self.assertEqual(fake.calls, [])
        self.write_mute(T0 + 600)
        self.run_unmute(fake, self.alarm("WARNING", recipient="disk"), T0 + 660)
        self.assertTrue(fake.to(OWNER)[0][1]["text"].startswith("⚠️ Внимание"))
        self.assertEqual(fake.to(PROJECT), [])

    def test_child_sends_only_its_roles(self):
        self.write_conf(self.CHILD)
        self.write_mute(T0 + 600)
        fake = Fake()
        self.run_unmute(fake, self.alarm(), T0 + 660)
        self.assertEqual(fake.to(OWNER), [])
        self.write_mute(T0 + 600)
        self.run_unmute(fake, self.alarm(recipient="fleetcrit"), T0 + 660)
        self.assertEqual(len(fake.to(OWNER)), 1)

    def test_silent_and_clear_alarms_skipped(self):
        fake = Fake()
        for a in (self.alarm(recipient="silent"), self.alarm(silenced=True), self.alarm("CLEAR"), self.alarm("UNINITIALIZED")):
            self.write_mute(T0 + 600)
            self.run_unmute(fake, a, T0 + 660)
        self.assertEqual(fake.to(OWNER), [])

    def test_telegram_down_keeps_file_until_tail(self):
        fake = Fake(fail={OWNER, PROJECT})
        self.write_mute(T0 + 600)
        code, err = self.run_unmute(fake, self.alarm(), T0 + 660)
        self.assertEqual(code, 1)
        self.assertIn("telegram down", err)
        self.assertTrue(os.path.exists(self.mute))
        fake.fail = set()
        self.assertEqual(self.run_unmute(fake, self.alarm(), T0 + 780)[0], 0)
        self.assertFalse(os.path.exists(self.mute))

    def test_netdata_down_gives_up_after_tail(self):
        def down(*a, **k):
            raise OSError("connection refused")
        self.write_mute(T0 + 600)
        self.assertEqual(self.run_unmute(Fake(), {}, T0 + 660, info=down)[0], 1)
        self.assertTrue(os.path.exists(self.mute))
        self.run_unmute(Fake(), {}, T0 + 601 + alarmroutes.MUTE_TAIL, info=down)
        self.assertFalse(os.path.exists(self.mute), "заглушка не должна висеть вечно")

    def test_broken_file_is_no_mute(self):
        with open(self.mute, "w") as f:
            f.write("завтра\n")
        self.assertEqual(self.run_unmute(Fake(), self.alarm(), T0), (0, ""))


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
