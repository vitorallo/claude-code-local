#!/usr/bin/env python3
"""ccrouter — route Claude Code to free or paid OpenAI-compatible LLM providers.

Claude Code talks Anthropic /v1/messages to this process; it translates to
OpenAI /v1/chat/completions and forwards to the active profile in config.yaml.
It stays on one profile until a request fails for hitting a limit (429, 402,
quota/credit errors), then rotates to another profile and retries that request.

    ccrouter.py serve [--profile N|R] [--port P]
    ccrouter.py list
    ccrouter.py test [N]
"""

import argparse
import itertools
import json
import logging
import logging.handlers
import math
import os
import random
import re
import signal
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import httpx
import yaml

import translate as tr

HERE = Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE / "config.yaml"
DEFAULT_PORT = 8787

log = logging.getLogger("ccrouter")

# A failed request counts as "hit the limit" (so we rotate) when it matches these.
LIMIT_STATUS = {402, 429}
LIMIT_TEXT = re.compile(r"quota|credit|rate.?limit|too many requests|exceeded|degraded", re.IGNORECASE)
# ...and the profile is treated as used up for the whole session when it matches these.
EXHAUSTED_TEXT = re.compile(r"credit|quota|insufficient|balance|payment", re.IGNORECASE)
DEFAULT_COOLDOWN = 60


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

class ConfigError(Exception):
    pass


def mask(key):
    if not key:
        return "(no key)"
    return key[:6] + "…" + key[-4:] if len(key) > 12 else "****"


def parse_config(data):
    data = data or {}
    profiles = {}
    for number, raw in (data.get("profiles") or {}).items():
        try:
            n = int(number)
        except (TypeError, ValueError):
            raise ConfigError(f"profile key {number!r} must be a number")
        if not isinstance(raw, dict):
            raise ConfigError(f"profile {n}: expected a mapping")
        for field in ("base_url", "model"):
            if not raw.get(field):
                raise ConfigError(f"profile {n}: missing {field}")
        if not str(raw["base_url"]).startswith(("http://", "https://")):
            raise ConfigError(f"profile {n}: base_url must start with http:// or https://")
        key = raw.get("api_key")
        if not key and raw.get("api_key_env"):
            key = os.environ.get(raw["api_key_env"])
            if not key:
                raise ConfigError(f"profile {n}: environment variable {raw['api_key_env']} is not set")
        if key and "xxxx" in key:
            raise ConfigError(f"profile {n}: api_key is still the placeholder — put your real key in config.yaml")
        profiles[n] = {
            "num": n,
            "name": raw.get("name") or f"profile-{n}",
            "base_url": str(raw["base_url"]).rstrip("/"),
            "api_key": key or None,
            "model": raw["model"],
            "context": int(raw.get("context") or 128000),
            "max_output": int(raw["max_output"]) if raw.get("max_output") else None,
            "extra_body": raw.get("extra_body") or {},
            "timeout": float(raw.get("timeout") or 600),
        }
    if not profiles:
        raise ConfigError("no profiles defined")
    listen = data.get("listen") or {}
    logcfg = data.get("log") or {}
    return {
        "host": listen.get("host", "127.0.0.1"),
        "port": int(listen.get("port", DEFAULT_PORT)),
        "log_dir": Path(logcfg.get("dir") or HERE / "logs"),
        "log_level": str(logcfg.get("level", "info")).upper(),
        "bodies": bool(logcfg.get("bodies", True)),
        "bodies_keep": int(logcfg.get("bodies_keep", 100)),
        "profiles": dict(sorted(profiles.items())),
    }


def load_config(path):
    path = Path(path)
    if not path.exists():
        raise ConfigError(f"{path} not found — cp config.example.yaml config.yaml and add your key")
    return parse_config(yaml.safe_load(path.read_text()))


def setup_logging(log_dir, level):
    log_dir.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)-5s %(message)s")
    file_handler = logging.handlers.RotatingFileHandler(log_dir / "ccrouter.log", maxBytes=5_000_000, backupCount=5)
    file_handler.setFormatter(fmt)
    console = logging.StreamHandler(sys.stderr)
    console.setFormatter(fmt)
    log.handlers[:] = [file_handler, console]
    log.setLevel(getattr(logging, level, logging.INFO))


# --------------------------------------------------------------------------
# Profile selection
# --------------------------------------------------------------------------

class Router:
    """Holds the active profile. Every request goes to it; rotation only
    happens when a request fails for hitting a limit."""

    def __init__(self, profiles, start, random_mode):
        self.profiles = profiles
        self.random_mode = random_mode
        self.active = start
        self.cooldown_until = {}
        self.lock = threading.Lock()

    def current(self):
        with self.lock:
            return self.profiles[self.active]

    @staticmethod
    def is_limit(status, text):
        return status in LIMIT_STATUS or (status in (400, 403) and bool(LIMIT_TEXT.search(text)))

    def rotate(self, failed, status, text, retry_after=None):
        """Mark `failed` as limited and return the profile to retry on, or None."""
        with self.lock:
            now = time.time()
            if status == 402 or EXHAUSTED_TEXT.search(text):
                self.cooldown_until[failed] = math.inf
            else:
                self.cooldown_until[failed] = now + (retry_after or DEFAULT_COOLDOWN)
            if self.active != failed and self.cooldown_until.get(self.active, 0) <= now:
                return self.profiles[self.active]  # another request already rotated
            available = [n for n in self.profiles if n != failed and self.cooldown_until.get(n, 0) <= now]
            if not available:
                return None
            if self.random_mode:
                chosen = random.choice(available)
            else:
                chosen = min(available, key=lambda n: (n <= failed, n))  # next number up, wrapping
            log.warning("rotate profile %d -> %d (HTTP %d: %s)", failed, chosen, status, text[:200].replace("\n", " "))
            self.active = chosen
            return self.profiles[chosen]

    def soonest_available(self):
        with self.lock:
            until = min(self.cooldown_until.values(), default=0)
        return None if math.isinf(until) else max(0, int(until - time.time()))


# --------------------------------------------------------------------------
# Upstream calls
# --------------------------------------------------------------------------

def upstream_headers(profile, stream):
    headers = {"Content-Type": "application/json", "User-Agent": "ccrouter/0.1",
               "Accept": "text/event-stream" if stream else "application/json"}
    if profile["api_key"]:
        headers["Authorization"] = f"Bearer {profile['api_key']}"
    return headers


def send_upstream(client, profile, request):
    timeout = httpx.Timeout(connect=15, read=profile["timeout"], write=60, pool=30)
    req = client.build_request("POST", profile["base_url"] + "/chat/completions", json=request,
                               headers=upstream_headers(profile, request.get("stream")), timeout=timeout)
    return client.send(req, stream=True)


def retry_after_seconds(response):
    value = response.headers.get("retry-after", "")
    return int(value) if value.isdigit() else None


def first_stream_chunk(response):
    """Read a 200 stream up to its first data chunk before answering Claude Code.

    NVIDIA sometimes answers 200 and then sends {"error": {"code": 503, ...}}
    as the first chunk ("Service temporarily overloaded"). Catching it here,
    before our own 200 goes out, lets it be handled like any HTTP error:
    rotation on limits, or a real 5xx that Claude Code retries by itself.
    Returns (lines iterator including what was read, error or None).
    """
    lines = response.iter_lines()
    seen = []
    for line in lines:
        seen.append(line)
        if not line.startswith("data:"):
            continue
        try:
            chunk = json.loads(line[5:])
        except json.JSONDecodeError:
            break
        if isinstance(chunk, dict) and chunk.get("error"):
            return None, chunk["error"]
        break
    return itertools.chain(seen, lines), None


def stream_error_status(error):
    code = error.get("code") if isinstance(error, dict) else None
    try:
        code = int(code)
    except (TypeError, ValueError):
        return 502
    return code if 400 <= code < 600 else 502


# --------------------------------------------------------------------------
# HTTP server
# --------------------------------------------------------------------------

class App:
    def __init__(self, config, router):
        self.config = config
        self.router = router
        self.client = httpx.Client()
        self.write_lock = threading.Lock()
        self.bodies_dir = config["log_dir"] / "bodies"
        config["log_dir"].mkdir(parents=True, exist_ok=True)
        if config["bodies"]:
            self.bodies_dir.mkdir(parents=True, exist_ok=True)

    def record(self, entry, bodies):
        with self.write_lock:
            with open(self.config["log_dir"] / "requests.jsonl", "a") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
            if not self.config["bodies"]:
                return
            (self.bodies_dir / f"{entry['id']}.json").write_text(json.dumps(bodies, ensure_ascii=False, indent=1))
            files = sorted(self.bodies_dir.glob("*.json"), key=lambda p: p.stat().st_mtime)
            for old in files[:-self.config["bodies_keep"]]:
                old.unlink(missing_ok=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "ccrouter/0.1"

    @property
    def app(self):
        return self.server.app

    def log_message(self, fmt, *args):
        log.debug("http %s", fmt % args)

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        profile = self.app.router.current()
        if path == "/health":
            self.send_json(200, {"status": "healthy", "profile": profile["num"], "name": profile["name"],
                                 "model": profile["model"]})
        elif path == "/v1/models":
            self.send_json(200, {"object": "list", "data": [{
                "id": "ccrouter", "object": "model", "owned_by": profile["name"],
                "upstream_model": profile["model"], "max_model_len": profile["context"],
                "max_output_tokens": profile["max_output"] or 32000}]})
        else:
            log.info("404 GET %s", self.path)
            self.send_json(404, tr.error_body(404, f"no route for GET {path}"))

    def do_POST(self):
        path = self.path.split("?")[0]
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError) as e:
            log.error("bad request body on %s: %s", path, e)
            return self.send_json(400, tr.error_body(400, f"invalid JSON body: {e}"))
        if path == "/v1/messages":
            self.messages(body)
        elif path == "/v1/messages/count_tokens":
            self.send_json(200, {"input_tokens": tr.estimate_tokens(body)})
        else:
            log.info("404 POST %s", self.path)
            self.send_json(404, tr.error_body(404, f"no route for POST {path}"))

    # -- /v1/messages ------------------------------------------------------

    def messages(self, body):
        app = self.app
        started = time.time()
        stream = bool(body.get("stream"))
        client_model = body.get("model") or "ccrouter"
        entry = {"id": "req_" + uuid.uuid4().hex[:12], "time": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                 "stream": stream, "client_model": client_model, "n_messages": len(body.get("messages") or []),
                 "n_tools": len(body.get("tools") or []), "max_tokens": body.get("max_tokens"), "rotations": []}
        bodies = {"anthropic_request": body, "attempts": []}
        profile = app.router.current()
        try:
            for _ in range(len(app.router.profiles) + 1):
                entry.update(profile=profile["num"], profile_name=profile["name"], model=profile["model"])
                request = tr.to_openai(body, profile["model"], profile["max_output"], profile["extra_body"])
                attempt = {"profile": profile["num"], "openai_request": request}
                bodies["attempts"].append(attempt)
                try:
                    response = send_upstream(app.client, profile, request)
                except httpx.HTTPError as e:
                    entry.update(status=502, error=f"upstream unreachable: {e!r}")
                    log.error("%s profile %d unreachable: %r", entry["id"], profile["num"], e)
                    return self.send_json(502, tr.error_body(502, f"ccrouter: {profile['name']} unreachable: {e}"))

                status, text, lines = response.status_code, None, None
                if status >= 400:
                    text = response.read().decode(errors="replace")
                    response.close()
                elif stream:
                    lines, stream_error = first_stream_chunk(response)
                    if stream_error is not None:
                        response.close()
                        status, text = stream_error_status(stream_error), json.dumps(stream_error, ensure_ascii=False)

                if text is not None:
                    attempt.update(status=status, error=text)
                    log.warning("%s profile %d HTTP %d: %s", entry["id"], profile["num"], status, text[:500])
                    if app.router.is_limit(status, text):
                        entry["rotations"].append({"from": profile["num"], "status": status})
                        nxt = app.router.rotate(profile["num"], status, text, retry_after_seconds(response))
                        if nxt:
                            profile = nxt
                            continue
                        wait = app.router.soonest_available()
                        message = f"ccrouter: every profile has hit its limit ({text[:300]})"
                        if wait is not None:
                            message += f" — next one frees up in ~{wait}s"
                        entry.update(status=429, error=text[:1000])
                        return self.send_json(429, tr.error_body(429, message))
                    entry.update(status=status, error=text[:1000])
                    return self.send_json(status, tr.error_body(status, f"{profile['name']}: {text[:1000]}"))

                entry["status"] = 200
                if stream:
                    self.relay_stream(lines, response, client_model, entry, attempt)
                else:
                    self.relay_json(response, client_model, entry, attempt)
                return
        except (BrokenPipeError, ConnectionResetError):
            entry["error"] = "client disconnected"
            log.info("%s client disconnected", entry["id"])
        except Exception as e:  # never kill the server thread silently
            entry.update(status=500, error=repr(e))
            log.exception("%s internal error", entry["id"])
            try:
                self.send_json(500, tr.error_body(500, f"ccrouter internal error: {e!r}"))
            except OSError:
                pass
        finally:
            entry["total_ms"] = int((time.time() - started) * 1000)
            log.info("%s %s p%s %s stream=%s msgs=%d tools=%d -> %s stop=%s in=%s out=%s %dms%s",
                     entry["id"], "POST /v1/messages", entry.get("profile"), entry.get("model"), stream,
                     entry["n_messages"], entry["n_tools"], entry.get("status"), entry.get("stop_reason"),
                     entry.get("input_tokens"), entry.get("output_tokens"), entry["total_ms"],
                     f" rotations={entry['rotations']}" if entry["rotations"] else "")
            app.record(entry, bodies)

    def relay_json(self, response, client_model, entry, attempt):
        try:
            upstream = json.loads(response.read())
        finally:
            response.close()
        attempt["response"] = upstream
        message = tr.from_openai(upstream, client_model)
        entry.update(stop_reason=message["stop_reason"], **message["usage"])
        self.send_json(200, message)

    def relay_stream(self, lines, response, client_model, entry, attempt):
        translator = tr.StreamTranslator(client_model)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        began = time.time()
        last_write = began
        try:
            for line in lines:
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    log.warning("%s unparseable stream line: %s", entry["id"], data[:200])
                    continue
                if chunk.get("error"):
                    raise RuntimeError(f"provider error mid-stream: {chunk['error']}")
                events = translator.feed(chunk)
                if "ttft_ms" not in entry and any(e["type"] != "message_start" for e in events):
                    entry["ttft_ms"] = int((time.time() - began) * 1000)
                if not events and time.time() - last_write > 5:
                    events = [{"type": "ping"}]  # keep Claude Code's stream alive while tool args buffer
                for event in events:
                    self.wfile.write(tr.sse(event))
                if events:
                    self.wfile.flush()
                    last_write = time.time()
            for event in translator.close():
                self.wfile.write(tr.sse(event))
            self.wfile.flush()
        except (httpx.HTTPError, RuntimeError) as e:
            entry.update(status=502, error=f"stream failed: {e}")
            log.error("%s stream failed: %s", entry["id"], e)
            self.wfile.write(tr.sse({"type": "error", **tr.error_body(502, f"ccrouter: {e}")}))
            self.wfile.flush()
        finally:
            response.close()
            message = translator.message()
            attempt["response"] = message
            entry.update(stop_reason=message["stop_reason"], finish_reason=message["finish_reason"],
                         reasoning_chars=message["reasoning_chars"], **message["usage"])
            bad = [b["name"] for b in message["content"] if b.get("type") == "tool_use" and "_ccrouter_error" in b["input"]]
            if bad:
                entry["invalid_tool_args"] = bad
                log.warning("%s invalid JSON tool arguments from provider for %s", entry["id"], bad)


def make_server(config, start, random_mode, host=None, port=None):
    router = Router(config["profiles"], start, random_mode)
    server = ThreadingHTTPServer((host or config["host"], config["port"] if port is None else port), Handler)
    server.daemon_threads = True
    server.app = App(config, router)
    return server


def pick_start(profiles, choice):
    if str(choice).upper() == "R":
        return random.choice(list(profiles)), True
    n = int(choice)
    if n not in profiles:
        raise ConfigError(f"profile {n} not in config (have: {', '.join(map(str, profiles))})")
    return n, False


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def cmd_serve(args, config):
    setup_logging(config["log_dir"], config["log_level"])
    start, random_mode = pick_start(config["profiles"], args.profile)
    try:
        server = make_server(config, start, random_mode, port=args.port)
    except OSError as e:
        log.error("cannot listen on %s:%s: %s", config["host"], args.port or config["port"], e)
        return 1
    host, port = server.server_address[:2]
    log.info("ccrouter listening on http://%s:%d  (log dir %s)", host, port, config["log_dir"])
    for p in config["profiles"].values():
        log.info("  profile %d  %-24s %-40s %s  %s", p["num"], p["name"], p["model"], mask(p["api_key"]), p["base_url"])
    log.info("active profile %d (%s)%s", start, config["profiles"][start]["name"],
             " — picked at random" if random_mode else "")

    def stop(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)

    if args.parent_pid:
        def watch_parent():
            while True:
                time.sleep(2)
                try:
                    os.kill(args.parent_pid, 0)
                except ProcessLookupError:
                    log.warning("parent process %d is gone — shutting down", args.parent_pid)
                    server.shutdown()
                    return
                except PermissionError:
                    pass  # exists, owned by someone else
        threading.Thread(target=watch_parent, daemon=True).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        log.info("ccrouter stopped")
    return 0


def cmd_list(args, config):
    for p in config["profiles"].values():
        print(f"{p['num']:>3}  {p['name']:<26} {p['model']:<42} {mask(p['api_key']):<14} {p['base_url']}")
    return 0


def cmd_test(args, config):
    numbers = [int(args.number)] if args.number else list(config["profiles"])
    client = httpx.Client()
    failures = 0
    probes = [
        ("text", {"model": "test", "max_tokens": 64, "stream": False,
                  "messages": [{"role": "user", "content": "Reply with exactly one word: pong"}]}),
        ("tool+stream", {"model": "test", "max_tokens": 512, "stream": True,
                         "messages": [{"role": "user", "content": "What is the weather in Rome? Use the tool."}],
                         "tools": [{"name": "get_weather", "description": "Get the current weather for a city",
                                    "input_schema": {"type": "object", "properties": {"city": {"type": "string"}},
                                                     "required": ["city"]}}]}),
    ]
    for n in numbers:
        profile = config["profiles"].get(n)
        if not profile:
            print(f"profile {n}: not in config")
            return 2
        print(f"profile {n} — {profile['name']} ({profile['model']})")
        for label, body in probes:
            started = time.time()
            request = tr.to_openai(body, profile["model"], profile["max_output"], profile["extra_body"])
            try:
                response = send_upstream(client, profile, request)
            except httpx.HTTPError as e:
                print(f"  {label:<12} FAIL  unreachable: {e}")
                failures += 1
                continue
            if response.status_code >= 400:
                print(f"  {label:<12} FAIL  HTTP {response.status_code}: {response.read().decode(errors='replace')[:300]}")
                response.close()
                failures += 1
                continue
            if body["stream"]:
                translator = tr.StreamTranslator("test")
                chunks, other = 0, []
                for line in response.iter_lines():
                    if line.startswith("data:") and line[5:].strip() != "[DONE]":
                        chunk = json.loads(line[5:])
                        chunks += 1
                        if chunk.get("error"):
                            other.append(f"error chunk: {chunk['error']}")
                        translator.feed(chunk)
                    elif line.strip() and not line.startswith("data:"):
                        other.append(line[:200])
                translator.close()
                message = translator.message()
                if not chunks or other:
                    print(f"  {label:<12} note  {chunks} data chunks; other lines: {other[:3]}")
            else:
                message = tr.from_openai(json.loads(response.read()), "test")
            response.close()
            ms = int((time.time() - started) * 1000)
            tools = [b for b in message["content"] if b["type"] == "tool_use"]
            text = "".join(b.get("text", "") for b in message["content"] if b["type"] == "text").strip()
            ok = (tools and tools[0]["input"].get("city")) if label.startswith("tool") else bool(text)
            failures += 0 if ok else 1
            shown = f"tool_use {tools[0]['name']}({json.dumps(tools[0]['input'])})" if tools else repr(text[:80])
            print(f"  {label:<12} {'ok  ' if ok else 'FAIL'}  {ms}ms  stop={message['stop_reason']}  "
                  f"usage={message['usage']}  {shown}")
    return 1 if failures else 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="ccrouter", description="Route Claude Code to OpenAI-compatible LLM providers.")
    parser.add_argument("--config", default=str(DEFAULT_CONFIG), help="config file (default: ccrouter/config.yaml)")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve", help="run the router")
    serve.add_argument("--profile", default="1", help="profile number to start on, or R for random (default 1)")
    serve.add_argument("--port", type=int, help=f"listen port (default from config, else {DEFAULT_PORT})")
    serve.add_argument("--parent-pid", type=int, help="exit when this process disappears (set by cclocal)")
    sub.add_parser("list", help="show configured profiles (keys masked)")
    test = sub.add_parser("test", help="send a text and a tool-call probe to one profile or all")
    test.add_argument("number", nargs="?")
    args = parser.parse_args(argv)
    try:
        config = load_config(args.config)
        return {"serve": cmd_serve, "list": cmd_list, "test": cmd_test}[args.command](args, config)
    except ConfigError as e:
        print(f"ccrouter: config error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
