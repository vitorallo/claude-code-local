"""End-to-end: a fake OpenAI upstream, a real ccrouter server, real HTTP."""

import json
import logging
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import ccrouter  # noqa: E402

ccrouter.log.addHandler(logging.NullHandler())
ccrouter.log.propagate = False


class FakeUpstream(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.seen.append((self.path, self.headers.get("Authorization"), body))
        if self.path.startswith("/slow"):
            time.sleep(1.5)  # then answers normally
        if self.path.startswith("/limited"):
            data = b'{"error": {"message": "Rate limit exceeded"}}'
            self.send_response(429)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path.startswith("/broken"):
            data = b'{"error": "internal"}'
            self.send_response(500)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path.startswith("/flaky") and self.server.flaky_failures > 0:
            self.server.flaky_failures -= 1  # overloaded a set number of times, then fine
            data = b'{"error": {"message": "Service temporarily overloaded", "code": 503}}'
            self.send_response(503)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        elif self.path.startswith("/overloaded"):
            # 200 header, then the error as the first chunk — what NVIDIA does
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(b'data: {"error": {"message": "Service temporarily overloaded", "code": 503}}\n\n')
        elif body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for chunk in ({"choices": [{"index": 0, "delta": {"content": "hi"}}]},
                          {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
                          {"choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 1}}):
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            data = json.dumps({"choices": [{"finish_reason": "stop", "message": {"content": "hi"}}],
                               "usage": {"prompt_tokens": 5, "completion_tokens": 1}}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)


def serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


class RotationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream = ThreadingHTTPServer(("127.0.0.1", 0), FakeUpstream)
        cls.upstream.seen = []
        cls.upstream.flaky_failures = 0
        cls.upstream_url = serve(cls.upstream)
        ccrouter.OVERLOAD_RETRY_DELAYS = (0.05, 0.05, 0.05)  # keep the tests fast

    @classmethod
    def tearDownClass(cls):
        cls.upstream.shutdown()

    def start_router(self, paths, start=1, extra=None):
        self.tmp = tempfile.TemporaryDirectory()
        config = ccrouter.parse_config({
            "log": {"dir": self.tmp.name, "bodies": True, "bodies_keep": 2},
            "profiles": {i + 1: {"name": f"p{i + 1}", "base_url": f"{self.upstream_url}/{p}/v1",
                                 "model": f"model-{i + 1}", "api_key": f"key-{i + 1}-secretvalue", **(extra or {})}
                         for i, p in enumerate(paths)}})
        self.router_server = ccrouter.make_server(config, start, False, host="127.0.0.1", port=0)
        self.url = serve(self.router_server)
        self.logdir = Path(self.tmp.name)

    def tearDown(self):
        self.router_server.shutdown()
        self.router_server.server_close()
        self.tmp.cleanup()

    def requests_log(self, expect=1):
        # The router writes its log after the response goes out, so wait for
        # the record, then take the write lock so any body pruning is finished.
        path = self.logdir / "requests.jsonl"
        deadline = time.time() + 5
        while time.time() < deadline:
            lines = path.read_text().splitlines() if path.exists() else []
            if len(lines) >= expect:
                break
            time.sleep(0.02)
        with self.router_server.app.write_lock:
            return [json.loads(line) for line in path.read_text().splitlines()]

    def post(self, stream=False):
        body = {"model": "claude-x", "max_tokens": 100, "stream": stream,
                "messages": [{"role": "user", "content": "hello"}]}
        return httpx.post(self.url + "/v1/messages?beta=true", json=body, timeout=10)

    def test_health_and_models(self):
        self.start_router(["ok"])
        self.assertEqual(httpx.get(self.url + "/health").json()["status"], "healthy")
        model = httpx.get(self.url + "/v1/models").json()["data"][0]
        self.assertEqual((model["id"], model["upstream_model"]), ("ccrouter", "model-1"))
        self.assertIn("max_model_len", model)

    def test_rotates_on_limit_and_stays(self):
        self.start_router(["limited", "ok"])
        resp = self.post(stream=True)
        self.assertEqual(resp.status_code, 200)
        self.assertIn("event: message_stop", resp.text)
        self.assertIn('"text": "hi"', resp.text)
        self.assertEqual(self.router_server.app.router.active, 2)
        entry = self.requests_log()[-1]
        self.assertEqual((entry["profile"], entry["rotations"][0]["from"], entry["stop_reason"]), (2, 1, "end_turn"))
        # second request goes straight to profile 2
        before = len(self.upstream.seen)
        self.assertEqual(self.post().json()["content"][0]["text"], "hi")
        self.assertTrue(self.upstream.seen[before][0].startswith("/ok"))
        self.assertEqual(self.upstream.seen[before][1], "Bearer key-2-secretvalue")

    def test_all_limited_returns_anthropic_rate_limit_error(self):
        self.start_router(["limited", "limited2"])
        resp = self.post()
        self.assertEqual(resp.status_code, 429)
        self.assertEqual(resp.json()["error"]["type"], "rate_limit_error")

    def test_server_errors_do_not_rotate(self):
        self.start_router(["broken", "ok"])
        resp = self.post()
        self.assertEqual(resp.status_code, 500)
        self.assertEqual(resp.json()["type"], "error")
        self.assertEqual(self.router_server.app.router.active, 1)

    def test_overloaded_first_chunk_rotates(self):
        self.start_router(["overloaded", "ok"])
        resp = self.post(stream=True)
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(self.router_server.app.router.active, 2)
        self.assertEqual(self.requests_log()[-1]["rotations"][0]["reason"], "overloaded")

    def test_overloaded_with_nowhere_to_go_is_retried_then_a_real_http_error(self):
        self.start_router(["overloaded"])
        before = len(self.upstream.seen)
        resp = self.post(stream=True)
        self.assertEqual(resp.status_code, 503)
        self.assertEqual(resp.json()["type"], "error")
        self.assertEqual(len(self.upstream.seen) - before, 1 + len(ccrouter.OVERLOAD_RETRY_DELAYS))

    def test_brief_overload_is_absorbed_by_retrying_the_same_profile(self):
        self.upstream.flaky_failures = 2
        self.start_router(["flaky"])
        resp = self.post(stream=True)
        self.assertEqual(resp.status_code, 200)
        self.assertIn("event: message_stop", resp.text)
        reasons = [r["reason"] for r in self.requests_log()[-1]["rotations"]]
        self.assertEqual(reasons, ["overloaded, retry 1 after 0.05s", "overloaded, retry 2 after 0.05s"])

    def test_slow_start_rotates_when_another_profile_exists(self):
        self.start_router(["slow", "ok"], extra={"first_token_timeout": 0.5})
        started = time.time()
        resp = self.post(stream=True)
        self.assertEqual(resp.status_code, 200)
        self.assertLess(time.time() - started, 1.4)  # didn't wait out the 1.5s upstream
        self.assertEqual(self.router_server.app.router.active, 2)
        self.assertEqual(self.requests_log()[-1]["rotations"][0]["reason"], "slow")

    def test_slow_start_waits_when_there_is_no_alternative(self):
        self.start_router(["slow"], extra={"first_token_timeout": 0.5})
        resp = self.post(stream=True)
        self.assertEqual(resp.status_code, 200)
        self.assertIn("event: message_stop", resp.text)

    def test_admin_status_activate_and_reload(self):
        self.start_router(["ok", "ok"])
        self.assertEqual(httpx.get(self.url + "/admin/status").json()["active"], 1)
        self.assertEqual(httpx.post(self.url + "/admin/activate", json={"profile": 2}).json()["active"], 2)
        self.assertEqual(httpx.post(self.url + "/admin/activate", json={"profile": 9}).status_code, 404)
        path = self.logdir / "config.yaml"
        path.write_text(yaml.safe_dump({"profiles": {
            1: {"base_url": f"{self.upstream_url}/ok/v1", "model": "m1"},
            2: {"enabled": False, "base_url": "https://x/v1", "model": "m2"}}}))
        self.router_server.app.config_path = path
        status = httpx.post(self.url + "/admin/reload").json()
        self.assertEqual((status["active"], [p["num"] for p in status["profiles"]]), (1, [1]))
        path.write_text(yaml.safe_dump({"profiles": {1: {"enabled": False, "base_url": "https://x/v1", "model": "m"}}}))
        self.assertEqual(httpx.post(self.url + "/admin/reload").status_code, 400)  # keeps the old set
        self.assertEqual(httpx.get(self.url + "/admin/status").json()["active"], 1)

    def test_logs_never_contain_keys_and_bodies_are_pruned(self):
        self.start_router(["ok"])
        for _ in range(3):
            self.post()
        self.requests_log(expect=3)
        self.assertEqual(len(list((self.logdir / "bodies").glob("*.json"))), 2)
        for path in self.logdir.rglob("*"):
            if path.is_file():
                self.assertNotIn("secretvalue", path.read_text())


class ConfigTests(unittest.TestCase):
    def test_placeholder_key_rejected(self):
        with self.assertRaises(ccrouter.ConfigError):
            ccrouter.parse_config({"profiles": {1: {"base_url": "https://x/v1", "model": "m", "api_key": "nvapi-xxxx"}}})

    def test_placeholder_profile_skipped_when_others_are_usable(self):
        config = ccrouter.parse_config({"profiles": {
            1: {"name": "nv", "base_url": "https://x/v1", "model": "m", "api_key": "nvapi-xxxx"},
            2: {"base_url": "https://y/v1", "model": "m2", "api_key": "real-key-123456"}}})
        self.assertEqual(list(config["profiles"]), [2])
        self.assertIn("placeholder", config["skipped"][0])

    def test_disabled_profiles_are_skipped_without_validation(self):
        config = ccrouter.parse_config({"profiles": {
            1: {"enabled": False, "base_url": "https://x/v1", "model": "m", "api_key": "nvapi-xxxx"},
            2: {"base_url": "https://y/v1", "model": "m2"}}})
        self.assertEqual(list(config["profiles"]), [2])
        with self.assertRaises(ccrouter.ConfigError):
            ccrouter.parse_config({"profiles": {1: {"enabled": False, "base_url": "https://x/v1", "model": "m"}}})

    def test_keyless_profile_allowed_and_pick_start(self):
        config = ccrouter.parse_config({"profiles": {2: {"base_url": "https://x/v1", "model": "m"}}})
        self.assertIsNone(config["profiles"][2]["api_key"])
        self.assertEqual(ccrouter.pick_start(config["profiles"], "R"), (2, True))
        with self.assertRaises(ccrouter.ConfigError):
            ccrouter.pick_start(config["profiles"], "1")


if __name__ == "__main__":
    unittest.main()
