import http.client
import os
import unittest

import live_fixtures


class FullFixtureTests(unittest.TestCase):
    def test_readiness_requires_a_complete_endpoint(self):
        with self.pipe(b"http://127.0.0.1:42") as stream, self.assertRaisesRegex(RuntimeError, "complete endpoint"):
            live_fixtures.loopback_endpoint(stream, "http", "")
        with self.pipe(b"ws://127.0.0.1:42/ws\n") as stream:
            self.assertEqual(live_fixtures.loopback_endpoint(stream, "ws", "/ws"), "ws://127.0.0.1:42/ws")

    def test_readiness_rejects_different_path_or_host(self):
        for endpoint in (b"http://127.0.0.1:42/stats\n", b"http://localhost:42\n"):
            with self.subTest(endpoint=endpoint), self.pipe(endpoint) as stream:
                with self.assertRaisesRegex(RuntimeError, "unexpected loopback"):
                    live_fixtures.loopback_endpoint(stream, "http", "")

    def test_redirect_fixture_uses_distinct_ports_and_records_replay(self):
        fixture = live_fixtures.RedirectFixture()
        with live_fixtures.redirect_server(fixture) as fixture.base, live_fixtures.redirect_server(fixture) as fixture.cross:
            self.assertNotEqual(fixture.base, fixture.cross)
            connection = http.client.HTTPConnection(fixture.base.removeprefix("http://"), timeout=2)
            try:
                connection.request("POST", "/redirect/307?same", b"private-input", {"X-Project-Key": "test-only-key"})
                response = connection.getresponse()
                self.assertEqual(response.status, 307)
                self.assertEqual(response.headers["Location"], fixture.base + "/target")
                response.read()
                connection.request("GET", "/target")
                self.assertEqual(connection.getresponse().read(), b'["GET"]')
            finally:
                connection.close()
        with self.assertRaisesRegex(RuntimeError, "1 source requests and 1 replays"):
            fixture.verify()

    @staticmethod
    def pipe(body):
        read, write = os.pipe()
        with os.fdopen(write, "wb") as stream:
            stream.write(body)
        return os.fdopen(read, "rb")
