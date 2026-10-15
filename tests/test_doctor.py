#!/usr/bin/env python3
"""Offline checks of the client connection doctor embedded in aws-optimize.sh: which connections
it resets and why, the ss parser, and that each connection counts once (no server, no proxy).

    python3 tests/test_doctor.py
"""
import os
import re
import subprocess
import types
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
SRC = open(os.path.join(HERE, "..", "aws-optimize.sh"), encoding="utf-8").read()
CODE = re.search(r"cat <<'CONN_DOCTOR_PY'\n(.*?)\nCONN_DOCTOR_PY\n", SRC, re.S).group(1)
D = types.ModuleType("doctor")
exec(compile(CODE, "aws-optimize-doctor", "exec"), D.__dict__)


def conn(ino, ip, port=443, **info):
    return dict({"l": "203.0.113.5", "lp": port, "p": ip, "pp": 40000 + ino, "pid": 1, "fd": ino, "ino": ino,
                 "lastrcv": 100, "lastsnd": 100}, **info)


def stuck(ino, ip, **kw):
    return conn(ino, ip, unacked=4, lastack=15000, backoff=3, lastrcv=15000, lastsnd=200, **kw)


class PickTests(unittest.TestCase):
    def setUp(self):
        self.d = D.Doctor()
        self.d.prev = {1, 2, 3, 4, 5, 6}          # a look has been taken before

    def test_stuck_connection_of_a_live_client_is_reset(self):
        got = self.d.pick([stuck(1, "5.200.235.142"), conn(2, "5.200.235.142", lastrcv=800)], {})
        self.assertEqual([(s["ino"], w) for s, w in got], [(1, "stuck/alive")])

    def test_stuck_connection_with_no_sign_of_its_client_waits_for_its_timeout(self):
        self.assertEqual(self.d.pick([stuck(1, "5.200.235.142")], {}), [])

    def test_a_new_connection_means_the_old_stuck_one_is_dead(self):
        got = self.d.pick([stuck(1, "5.1.1.1"), conn(9, "5.1.1.1", lastrcv=20000)], {})
        self.assertEqual([w for _, w in got], ["stuck/new-conn"])

    def test_unanswered_syns_two_looks_running_mean_trying_and_failing(self):
        self.assertEqual(self.d.pick([stuck(1, "5.1.1.1")], {"5.1.1.1": 1}), [])
        self.d.prev = {1}
        self.assertEqual([w for _, w in self.d.pick([stuck(1, "5.1.1.1")], {"5.1.1.1": 1})], ["stuck/failing"])

    def test_idle_both_ways_is_reset_and_one_way_is_not(self):
        got = self.d.pick([conn(1, "5.1.1.1", lastrcv=301000, lastsnd=301000),
                           conn(2, "5.1.1.1", lastrcv=301000, lastsnd=1000)], {})
        self.assertEqual([(s["ino"], w) for s, w in got], [(1, "idle")])

    def test_idle_zero_is_off(self):
        d = D.Doctor(idle_s=0)
        self.assertEqual(d.pick([conn(1, "5.1.1.1", lastrcv=10 ** 7, lastsnd=10 ** 7)], {}), [])

    def test_a_connection_counts_once(self):
        c = [conn(1, "5.1.1.1", lastrcv=301000, lastsnd=301000)]
        self.assertEqual(len(self.d.once(c, {})), 1)
        self.assertEqual(self.d.once(c, {}), [])   # still there (shadow): not again


LISTEN = """LISTEN 0 4096 *:443 *:* users:(("xray",pid=7,fd=3))
LISTEN 0 4096 127.0.0.1:62789 0.0.0.0:* users:(("xray",pid=7,fd=4))
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=9,fd=3))
"""
EST = """0 0 [::ffff:203.0.113.5]:443 [::ffff:5.200.235.142]:49255 users:(("xray",pid=7,fd=55)) uid:0 ino:111 sk:1 <->
\t bbr rto:1600 backoff:3 rtt:90/20 unacked:4 lastsnd:200 lastrcv:15000 lastack:15000
0 0 203.0.113.5:22 5.1.1.1:5000 users:(("sshd",pid=9,fd=4)) uid:0 ino:222 sk:2 <->
\t rtt:30/1 lastsnd:1 lastrcv:1 lastack:1
0 0 127.0.0.1:443 127.0.0.1:6000 users:(("xray",pid=7,fd=56)) uid:0 ino:333 sk:3 <->
\t rtt:1/1
"""


class ParserTests(unittest.TestCase):
    def setUp(self):
        self.real = subprocess.run

        def fake(cmd, **kw):
            out = LISTEN if "-Htlpn" in cmd else EST if "-tinpeH" in cmd else ""
            return subprocess.CompletedProcess(cmd, 0, out, "")
        D.subprocess.run = fake

    def tearDown(self):
        D.subprocess.run = self.real

    def test_only_the_proxys_public_ports(self):
        self.assertEqual(D.listen_ports(), {443})

    def test_client_connections_with_tcp_info(self):
        s = D.sockets({443})
        self.assertEqual(len(s), 1)                 # not sshd, not loopback
        self.assertEqual((s[0]["p"], s[0]["lp"], s[0]["ino"]), ("5.200.235.142", 443, 111))
        self.assertEqual((s[0]["backoff"], s[0]["unacked"], s[0]["lastack"]), (3, 4, 15000))


if __name__ == "__main__":
    unittest.main(verbosity=1)
