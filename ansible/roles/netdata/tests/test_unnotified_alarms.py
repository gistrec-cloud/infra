"""unnotified-alarms: заглушка. Без сети и базы: unnotified() и send() подменены.

Запуск: python3 -m unittest discover -s ansible/roles/netdata/tests -v"""
import importlib.util
import json
import os
import tempfile
import time
import unittest
from unittest import mock

FILES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "files")
spec = importlib.util.spec_from_file_location("unnotified_alarms", os.path.join(FILES, "unnotified-alarms.py"))
ua = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ua)

ALARM = dict(id=7, name="x_down", value_string="0", chart="c", info="i")


class Mute(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.mute = os.path.join(self.tmp.name, "alarm-mute")
        self.conf = os.path.join(self.tmp.name, "conf")
        with open(self.conf, "w") as f:
            f.write('DEFAULT_RECIPIENT_CUSTOM="111|critical"\n')
        ua.EPISODES = os.path.join(self.tmp.name, "episodes")
        os.mkdir(ua.EPISODES)
        ua.STATE = os.path.join(self.tmp.name, "seen.json")
        ua.NOTIFY_CONF = self.conf

    def run_main(self, found):
        sent, graces = [], []

        def unnotified(db, now, grace=ua.GRACE):
            graces.append(grace)
            return iter(found)
        with mock.patch.dict(os.environ, {"ALARM_MUTE": self.mute}), mock.patch.object(ua, "unnotified", unnotified), \
                mock.patch.object(ua, "send", lambda conf, text: sent.append(text) or True), \
                mock.patch.object(ua.sqlite3, "connect", lambda *a, **k: None):
            ua.main()
        with open(ua.STATE) as f:
            return sent, graces[0], json.load(f)

    def write_mute(self, until):
        with open(self.mute, "w") as f:
            f.write(f"{int(until)}\nребут\n")

    def test_no_mute_sends(self):
        sent, grace, seen = self.run_main([("T1", "russia-03", ALARM)])
        self.assertEqual((len(sent), grace, seen), (1, ua.GRACE, ["T1"]))

    def test_mute_is_silent_and_marks_seen(self):
        for until in (time.time() + 600, time.time() - 60):  # активна и ждёт досылки
            self.write_mute(until)
            sent, grace, seen = self.run_main([("T1", "russia-03", ALARM)])
            self.assertEqual((sent, grace, seen), ([], 0, ["T1"]))
        os.remove(self.mute)
        self.assertEqual(self.run_main([("T1", "russia-03", ALARM)])[0], [], "после заглушки не повторяется")

    def test_open_episode_counts_as_notified(self):
        """Досылку после заглушки делает alarm-telegram: второй раз не сообщаем."""
        path = os.path.join(ua.EPISODES, "111_russia-03_7")
        with open(path, "w") as f:
            json.dump({"peak": "CRITICAL", "message_id": 1}, f)
        sent, _, seen = self.run_main([("T1", "russia-03", ALARM)])
        self.assertEqual((sent, seen), ([], ["T1"]))
        with open(path, "w") as f:
            json.dump({"peak": "WARNING", "message_id": 1}, f)
        self.assertEqual(len(self.run_main([("T2", "russia-03", ALARM)])[0]), 1)

    def test_forgotten_file_stops_muting(self):
        self.write_mute(time.time() - ua.alarmroutes.MUTE_TAIL - 1)
        self.assertEqual(len(self.run_main([("T1", "russia-03", ALARM)])[0]), 1)


if __name__ == "__main__":
    unittest.main()
