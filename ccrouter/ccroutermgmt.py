#!/usr/bin/env python3
"""ccroutermgmt — manage ccrouter from a full-screen terminal UI.

  Profiles      enable/disable, make active in the running router, test, set key,
                reorder, delete. Every change is saved to config.yaml and hot-reloaded
                into a running router.
  Add provider  pick a provider from providers.yaml, fetch its live model list,
                paste a key, add it as a new profile.
  Live log      follows logs/ccrouter.log as the router works, with a regex filter.

Run it as `ccroutermgmt` (installed by install.sh) or
`ccrouter/.venv/bin/python3 ccrouter/ccroutermgmt.py`.
Set CCROUTER_CONFIG to manage a config file other than ccrouter/config.yaml.
"""

import collections
import json
import os
import re
import sys
import time
from pathlib import Path

import httpx
import yaml
from rich.text import Text
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import (Button, DataTable, Footer, Header, Input, Label, RichLog, Select, Static,
                             TabbedContent, TabPane)

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ccrouter  # noqa: E402

CONFIG = Path(os.environ.get("CCROUTER_CONFIG") or HERE / "config.yaml")
CATALOG = HERE / "providers.yaml"
HEADER = ("# ccrouter config — contains real keys. Gitignored; keep it chmod 600.\n"
          "# Written by ccroutermgmt (comments are not preserved; the previous version is in config.yaml.bak).\n\n")


# --------------------------------------------------------------------------
# Config file and router helpers
# --------------------------------------------------------------------------

def load_raw():
    if not CONFIG.exists():
        return {"listen": {"host": "127.0.0.1", "port": ccrouter.DEFAULT_PORT},
                "log": {"level": "info", "bodies": True, "bodies_keep": 100}, "profiles": {}}
    data = yaml.safe_load(CONFIG.read_text()) or {}
    data["profiles"] = {int(k): v for k, v in (data.get("profiles") or {}).items()}
    return data


def _write_private(path, text):
    """Write a file that is 0600 from the moment it exists (it holds API keys)."""
    path.unlink(missing_ok=True)  # O_CREAT's mode only applies to a new file
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)


def save_raw(data):
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    if CONFIG.exists():
        _write_private(CONFIG.with_name(CONFIG.name + ".bak"), CONFIG.read_text())
    data = dict(data, profiles=dict(sorted(data.get("profiles", {}).items())))
    tmp = CONFIG.with_name(CONFIG.name + ".tmp")
    _write_private(tmp, HEADER + yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=120))
    tmp.replace(CONFIG)


def log_dir(data):
    return Path((data.get("log") or {}).get("dir") or HERE / "logs")


def router_url(data):
    return f"http://127.0.0.1:{(data.get('listen') or {}).get('port', ccrouter.DEFAULT_PORT)}"


def router_status(url):
    """The running router's state, or None if it isn't running (or is an older
    build without the admin endpoints — restart it to get live control)."""
    try:
        reply = httpx.get(url + "/admin/status", timeout=1)
        return reply.json() if reply.status_code == 200 else None
    except (httpx.HTTPError, ValueError):
        return None


def load_catalog():
    if not CATALOG.exists():
        return []
    return (yaml.safe_load(CATALOG.read_text()) or {}).get("providers") or []


def key_label(profile):
    if "xxxx" in str(profile.get("api_key", "")):
        return Text("needs key (k)", style="bold red")
    if profile.get("api_key"):
        return ccrouter.mask(str(profile["api_key"]))
    if profile.get("api_key_env"):
        return f"${profile['api_key_env']}"
    return "(none)"


# --------------------------------------------------------------------------
# Widgets
# --------------------------------------------------------------------------

class KeyScreen(ModalScreen):
    """Ask for a secret; dismisses with the string, or None on Esc."""

    CSS = """
    KeyScreen { align: center middle; }
    #key-box { width: 80; height: auto; border: thick $primary; padding: 1 2; background: $surface; }
    #key-box Label { margin-bottom: 1; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, prompt):
        super().__init__()
        self.prompt = prompt

    def compose(self) -> ComposeResult:
        with Vertical(id="key-box"):
            yield Label(self.prompt)
            yield Input(password=True, id="secret")
            yield Label("Enter to save · Esc to cancel")

    def on_input_submitted(self, event: Input.Submitted):
        self.dismiss(event.value.strip() or None)

    def action_cancel(self):
        self.dismiss(None)


class ProfileTable(DataTable):
    BINDINGS = [
        Binding("e", "app.toggle_profile", "On/off"),
        Binding("a", "app.activate_profile", "Make active"),
        Binding("t", "app.test_profile", "Test"),
        Binding("k", "app.set_key", "Set key"),
        Binding("shift+up", "app.move_profile(-1)", "Move up"),
        Binding("shift+down", "app.move_profile(1)", "Move down"),
        Binding("x", "app.delete_profile", "Delete"),
    ]


class Manager(App):
    TITLE = "ccroutermgmt"
    SUB_TITLE = str(CONFIG)
    CSS = """
    #status { height: 1; padding: 0 1; background: $boost; }
    .help { color: $text-muted; padding: 0 1; height: auto; }
    #profile-table { height: 1fr; }
    #probe { height: 12; border: round $primary-darken-2; }
    #catalog { width: 50%; height: 1fr; }
    #provider-form { width: 50%; padding: 0 1; }
    #provider-form Label { margin-top: 1; }
    #provider-info { height: auto; }
    .buttons { height: auto; margin-top: 1; }
    .buttons Button { margin-right: 1; }
    #logview { height: 1fr; border: round $primary-darken-2; }
    """
    BINDINGS = [Binding("q", "quit", "Quit"), Binding("r", "refresh", "Refresh")]

    def __init__(self):
        super().__init__()
        self.data = load_raw()
        self.catalog = load_catalog()
        self.provider = None
        self.delete_armed = (None, 0.0)
        self.log_pos = 0
        self.log_lines = collections.deque(maxlen=5000)
        self.log_filter = None

    # -- layout ------------------------------------------------------------

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("", id="status")
        with TabbedContent(initial="profiles"):
            with TabPane("Profiles", id="profiles"):
                yield Static("e on/off · a make active now · t test · k set key · shift+↑/↓ reorder · x delete. "
                             "Saved to config.yaml and reloaded into a running router.", classes="help")
                yield ProfileTable(id="profile-table", cursor_type="row", zebra_stripes=True)
                yield RichLog(id="probe", wrap=True, markup=False)
            with TabPane("Add provider", id="add"):
                with Horizontal():
                    yield DataTable(id="catalog", cursor_type="row", zebra_stripes=True)
                    with VerticalScroll(id="provider-form"):
                        yield Static("Pick a provider on the left.", id="provider-info")
                        yield Label("Model")
                        yield Select([], id="model-select", prompt="choose a model")
                        yield Input(placeholder="…or type any model id", id="model-input")
                        yield Label("API key")
                        yield Input(placeholder="paste the key (leave empty for keyless providers)",
                                    password=True, id="key-input")
                        with Horizontal(classes="buttons"):
                            yield Button("Fetch models", id="fetch-models")
                            yield Button("Add as new profile", id="add-profile", variant="primary")
                        yield Static("", id="add-result")
            with TabPane("Live log", id="log"):
                yield Input(placeholder="filter (regex), e.g.  rotate|503|ERROR   or   stop=tool_use", id="log-filter")
                yield RichLog(id="logview", wrap=False, markup=False, max_lines=5000)
        yield Footer()

    def on_mount(self):
        table = self.query_one("#profile-table", DataTable)
        table.add_columns("#", "state", "name", "model", "key", "base_url")
        catalog = self.query_one("#catalog", DataTable)
        catalog.add_columns("provider", "key", "free tier", "ToS")
        for p in self.catalog:
            auth = {"key": "needed", "none": "NO KEY", "any": "any string"}.get(p.get("auth"), p.get("auth", ""))
            catalog.add_row(p.get("name", p["id"]), auth, p.get("free", ""), p.get("tos", ""), key=p["id"])
        self.refresh_profiles()
        self.start_log_tail()
        self.set_interval(3, self.refresh_profiles)
        self.set_interval(0.5, self.poll_log)

    def action_refresh(self):
        self.data = load_raw()
        self.refresh_profiles()

    # -- profiles tab --------------------------------------------------------

    def refresh_profiles(self):
        status = router_status(router_url(self.data))
        active = status["active"] if status else None
        cooldowns = {p["num"]: p["cooldown_s"] for p in (status or {}).get("profiles", [])}
        table = self.query_one("#profile-table", DataTable)
        row = table.cursor_row
        table.clear()
        for num, p in sorted(self.data.get("profiles", {}).items()):
            enabled = p.get("enabled", True) is not False
            state = Text("● active", style="bold green") if num == active else (
                Text("on", style="green") if enabled else Text("off", style="dim"))
            cooldown = cooldowns.get(num)
            if cooldown is not None:
                state.append(" (used up)" if cooldown == "session" else f" (cooling {cooldown}s)", style="yellow")
            table.add_row(str(num), state, p.get("name", ""), p.get("model", ""), key_label(p),
                          p.get("base_url", ""), key=str(num))
        if table.row_count:
            table.move_cursor(row=min(max(row, 0), table.row_count - 1))
        bar = self.query_one("#status", Static)
        if status:
            name = next((p["name"] for p in status["profiles"] if p["num"] == active), "?")
            bar.update(Text.assemble(("router ", "bold"), ("running", "bold green"),
                                     f" on {router_url(self.data)} · active profile {active} ({name})"))
        else:
            bar.update(Text.assemble(("router ", "bold"), ("not running", "bold yellow"),
                                     " — start it with  cclocal --ccrouter  (changes still save to config.yaml)"))

    def selected(self):
        table = self.query_one("#profile-table", DataTable)
        if not table.row_count:
            return None
        return int(table.coordinate_to_cell_key(table.cursor_coordinate).row_key.value)

    def save(self, message):
        save_raw(self.data)
        note, severity, usable = message, "information", True
        try:
            parsed = ccrouter.parse_config(self.data)
            if parsed["skipped"]:
                note, severity = f"{message} · still needs a key: {'; '.join(parsed['skipped'])}", "warning"
        except ccrouter.ConfigError as e:
            note, severity, usable = f"{message} — but the config isn't usable yet: {e}", "warning", False
        url = router_url(self.data)
        if usable and router_status(url) is not None:
            try:
                reply = httpx.post(url + "/admin/reload", timeout=3)
                if reply.status_code == 200:
                    note += " · router reloaded"
                else:
                    note, severity = f"{note} · router kept its old config: {reply.json()['error']['message']}", "warning"
            except httpx.HTTPError as e:
                note, severity = f"{note} · reload failed: {e}", "warning"
        self.notify(note, severity=severity)
        self.refresh_profiles()

    def action_toggle_profile(self):
        num = self.selected()
        if num is None:
            return
        profile = self.data["profiles"][num]
        if profile.get("enabled", True) is False:
            profile.pop("enabled", None)
            self.save(f"profile {num} enabled")
        else:
            profile["enabled"] = False
            self.save(f"profile {num} disabled")

    def action_activate_profile(self):
        num = self.selected()
        if num is None:
            return
        url = router_url(self.data)
        if router_status(url) is None:
            self.notify(f"router isn't running — start it on this profile with  cclocal --ccrouter {num}",
                        severity="warning")
            return
        reply = httpx.post(url + "/admin/activate", json={"profile": num}, timeout=3)
        if reply.status_code == 200:
            self.notify(f"profile {num} is now active — the next request goes there")
        else:
            self.notify(reply.json()["error"]["message"], severity="error")
        self.refresh_profiles()

    def action_set_key(self):
        num = self.selected()
        if num is None:
            return

        def apply(secret):
            if secret:
                profile = self.data["profiles"][num]
                profile["api_key"] = secret
                profile.pop("api_key_env", None)
                self.save(f"key set for profile {num}")
        self.push_screen(KeyScreen(f"API key for profile {num} ({self.data['profiles'][num].get('name', '')})"), apply)

    def action_move_profile(self, delta):
        num = self.selected()
        if num is None:
            return
        numbers = sorted(self.data["profiles"])
        index = numbers.index(num) + delta
        if not 0 <= index < len(numbers):
            return
        other = numbers[index]
        profiles = self.data["profiles"]
        profiles[num], profiles[other] = profiles[other], profiles[num]
        self.save(f"profiles {num} and {other} swapped (numbers are what --ccrouter N uses)")
        table = self.query_one("#profile-table", DataTable)
        table.move_cursor(row=index)

    def action_delete_profile(self):
        num = self.selected()
        if num is None:
            return
        armed, when = self.delete_armed
        if armed != num or time.time() - when > 3:
            self.delete_armed = (num, time.time())
            self.notify(f"press x again to delete profile {num}", severity="warning", timeout=3)
            return
        self.delete_armed = (None, 0.0)
        del self.data["profiles"][num]
        self.save(f"profile {num} deleted")

    def action_test_profile(self):
        num = self.selected()
        if num is not None:
            self.run_probe(num, dict(self.data["profiles"][num]))

    @work(thread=True, exclusive=True)
    def run_probe(self, num, raw):
        probe = self.query_one("#probe", RichLog)
        write = lambda text: self.call_from_thread(probe.write, text)  # noqa: E731
        raw.pop("enabled", None)
        try:
            profile = ccrouter.parse_config({"profiles": {num: raw}})["profiles"][num]
        except ccrouter.ConfigError as e:
            write(Text(f"profile {num}: {e}", style="red"))
            return
        write(Text(f"testing profile {num} — {profile['name']} ({profile['model']}) …", style="bold"))
        with httpx.Client() as client:
            for label, ok, ms, detail in ccrouter.probe_profile(client, profile):
                write(Text.assemble(f"  {label:<12} ", ("ok  " if ok else "FAIL", "green" if ok else "bold red"),
                                    f"  {ms / 1000:.1f}s  {detail}"))

    # -- add provider tab ------------------------------------------------------

    @on(DataTable.RowHighlighted, "#catalog")
    def show_provider(self, event: DataTable.RowHighlighted):
        self.provider = next((p for p in self.catalog if p["id"] == event.row_key.value), None)
        if not self.provider:
            return
        p = self.provider
        auth = {"key": "API key needed", "none": "no registration, no key", "any": "any key string works"}.get(
            p.get("auth"), p.get("auth", ""))
        info = Text()
        info.append(f"{p.get('name', p['id'])}\n", style="bold")
        info.append(f"{p['base_url']}\n", style="cyan")
        info.append(f"{auth} · {p.get('free', '')} · ToS: {p.get('tos', '?')}\n")
        if p.get("key_url"):
            info.append(f"keys: {p['key_url']}\n", style="dim")
        if p.get("notes"):
            info.append(f"\n{p['notes']}\n", style="yellow")
        self.query_one("#provider-info", Static).update(info)
        self.query_one("#model-select", Select).set_options([(m, m) for m in p.get("models") or []])
        self.query_one("#model-input", Input).value = ""
        self.query_one("#add-result", Static).update("")

    @on(Button.Pressed, "#fetch-models")
    def fetch_models(self):
        if not self.provider:
            self.notify("pick a provider first", severity="warning")
            return
        self.query_one("#add-result", Static).update("fetching models…")
        self.load_models(self.provider, self.query_one("#key-input", Input).value.strip())

    @work(thread=True, exclusive=True)
    def load_models(self, provider, key):
        headers = {"Authorization": f"Bearer {key or 'unused'}"} if key or provider.get("auth") == "any" else {}
        result = self.query_one("#add-result", Static)
        try:
            reply = httpx.get(provider["base_url"] + "/models", headers=headers, timeout=15)
            reply.raise_for_status()
            ids = sorted(m["id"] for m in reply.json().get("data", []) if m.get("id"))
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as e:
            self.call_from_thread(result.update, Text(f"couldn't fetch models: {e}", style="red"))
            return
        select = self.query_one("#model-select", Select)
        self.call_from_thread(select.set_options, [(m, m) for m in ids[:500]])
        self.call_from_thread(result.update, Text(f"{len(ids)} models from {provider['base_url']}/models", style="green"))

    @on(Button.Pressed, "#add-profile")
    def add_profile(self):
        p = self.provider
        result = self.query_one("#add-result", Static)
        if not p:
            result.update(Text("pick a provider first", style="red"))
            return
        typed = self.query_one("#model-input", Input).value.strip()
        chosen = self.query_one("#model-select", Select).value
        model = typed or (chosen if isinstance(chosen, str) else "")
        key = self.query_one("#key-input", Input).value.strip()
        if not model:
            result.update(Text("choose or type a model", style="red"))
            return
        if p.get("auth") == "key" and not key:
            result.update(Text(f"{p.get('name', p['id'])} needs an API key — {p.get('key_url', '')}", style="red"))
            return
        profile = {"name": f"{p['id']}-{model.split('/')[-1]}"[:48], "base_url": p["base_url"]}
        if key or p.get("auth") == "any":
            profile["api_key"] = key or "unused"
        profile["model"] = model
        for field in ("context", "max_output", "extra_body"):
            if p.get(field):
                profile[field] = p[field]
        number = max(self.data["profiles"], default=0) + 1
        self.data["profiles"][number] = profile
        self.query_one("#key-input", Input).value = ""
        self.save(f"added {profile['name']} as profile {number}")
        result.update(Text(f"added as profile {number} — test it on the Profiles tab (t)", style="green"))
        self.query_one(TabbedContent).active = "profiles"
        table = self.query_one("#profile-table", DataTable)
        table.move_cursor(row=table.row_count - 1)
        table.focus()

    # -- live log tab ------------------------------------------------------------

    def start_log_tail(self):
        path = log_dir(self.data) / "ccrouter.log"
        view = self.query_one("#logview", RichLog)
        if not path.exists():
            view.write(Text(f"{path} doesn't exist yet — it appears when the router first starts.", style="dim"))
            return
        size = path.stat().st_size
        self.log_pos = max(0, size - 60_000)  # start with the recent tail
        self.poll_log(skip_partial=self.log_pos > 0)

    def poll_log(self, skip_partial=False):
        path = log_dir(self.data) / "ccrouter.log"
        if not path.exists():
            return
        size = path.stat().st_size
        if size < self.log_pos:  # rotated
            self.log_pos = 0
        if size == self.log_pos:
            return
        with open(path, "r", errors="replace") as f:
            f.seek(self.log_pos)
            if skip_partial:
                f.readline()
            chunk = f.read()
            self.log_pos = f.tell()
        view = self.query_one("#logview", RichLog)
        for line in chunk.splitlines():
            if not line.strip():
                continue
            self.log_lines.append(line)
            if self.log_filter is None or self.log_filter.search(line):
                view.write(self.styled(line))

    @staticmethod
    def styled(line):
        style = ""
        if " ERROR " in line:
            style = "bold red"
        elif "rotate profile" in line:
            style = "bold magenta"
        elif " WARNING " in line:
            style = "yellow"
        elif re.search(r"-> 2\d\d ", line):
            style = "green"
        elif re.search(r"-> [45]\d\d ", line):
            style = "red"
        return Text(line, style=style)

    @on(Input.Changed, "#log-filter")
    def filter_log(self, event: Input.Changed):
        try:
            self.log_filter = re.compile(event.value, re.IGNORECASE) if event.value else None
        except re.error:
            return  # keep the last valid filter while typing
        view = self.query_one("#logview", RichLog)
        view.clear()
        for line in self.log_lines:
            if self.log_filter is None or self.log_filter.search(line):
                view.write(self.styled(line))


# --------------------------------------------------------------------------
# Profile picker (cclocal --ccrouter with no profile number)
# --------------------------------------------------------------------------

PICK_CANCELLED = 130


def recent_speed(data):
    """Median total time of recent successful requests, per upstream model."""
    path = log_dir(data) / "requests.jsonl"
    times = collections.defaultdict(list)
    if path.exists():
        with open(path, "rb") as f:
            f.seek(max(0, path.stat().st_size - 400_000))
            for line in f.read().decode(errors="replace").splitlines()[1:]:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                if record.get("status") == 200 and record.get("total_ms"):
                    times[record.get("model")].append(record["total_ms"])
    return {model: (sorted(ms)[len(ms) // 2], len(ms)) for model, ms in times.items()}


class Picker(App):
    """A small inline menu: choose which profile the router starts on."""

    CSS = """
    Screen:inline { height: auto; }
    #pick-box { height: auto; border: round $primary; padding: 0 1; }
    #pick-table { height: auto; max-height: 16; }
    .help { color: $text-muted; }
    """
    BINDINGS = [Binding("escape", "cancel", "Cancel"), Binding("q", "cancel", "Cancel"),
                Binding("r", "choose('R')", "Random")]

    def __init__(self, rows, disabled, out):
        super().__init__()
        self.rows, self.disabled, self.out = rows, disabled, out

    def compose(self) -> ComposeResult:
        with Vertical(id="pick-box"):
            yield Static(Text("ccrouter — which provider profile?", style="bold"))
            yield DataTable(id="pick-table", cursor_type="row", zebra_stripes=True)
            hint = "↑/↓ move · Enter start · r random · Esc cancel · add providers and keys with ccroutermgmt"
            if self.disabled:
                hint += f" · hidden: {self.disabled}"
            yield Static(hint, classes="help")

    def on_mount(self):
        table = self.query_one("#pick-table", DataTable)
        table.add_columns("#", "name", "model", "speed", "key")  # key last: it's what gets cut on narrow terminals
        for row in self.rows:
            table.add_row(*row[1:], key=row[0])
        table.add_row("R", "random", "start on a random profile", "", "", key="R")
        table.focus()

    def on_data_table_row_selected(self, event: DataTable.RowSelected):
        self.action_choose(event.row_key.value)

    def action_choose(self, value):
        self.out.write_text(value)
        self.exit(value)

    def action_cancel(self):
        self.exit(None, return_code=PICK_CANCELLED)


def pick(out):
    """Write the chosen profile ("1", "2", …, or "R") to `out`. Exit code 130 if cancelled."""
    data = load_raw()
    speeds = recent_speed(data)
    profiles = sorted(data.get("profiles", {}).items())
    enabled = {n: p for n, p in profiles if p.get("enabled", True) is not False}
    needs_key = [n for n, p in enabled.items() if "xxxx" in str(p.get("api_key", ""))]
    usable = {n: p for n, p in enabled.items() if n not in needs_key}
    if not usable:
        print("ccrouter: no usable profiles — run ccroutermgmt to add a provider or set a key", file=sys.stderr)
        return 1
    if len(usable) == 1:
        out.write_text(str(next(iter(usable))))
        return 0
    rows = []
    for num, p in usable.items():
        speed, _count = speeds.get(p.get("model"), (None, 0))
        shown = f"~{speed / 1000:.1f}s" if speed else Text("no data", style="dim")
        rows.append((str(num), str(num), p.get("name", ""), p.get("model", ""), shown, key_label(p)))
    notes = []
    if len(profiles) > len(enabled):
        notes.append(f"{len(profiles) - len(enabled)} disabled")
    if needs_key:
        notes.append(f"{len(needs_key)} still need a key (ccroutermgmt → k)")
    app = Picker(rows, ", ".join(notes), out)
    app.run(inline=True)
    return app.return_code or 0


def main():
    import argparse
    parser = argparse.ArgumentParser(prog="ccroutermgmt", description="Manage ccrouter profiles and watch its log.")
    sub = parser.add_subparsers(dest="command")
    picker = sub.add_parser("pick", help="small menu to choose a profile; used by cclocal --ccrouter")
    picker.add_argument("--out", required=True, help="file the chosen profile is written to")
    args = parser.parse_args()
    if args.command == "pick":
        sys.exit(pick(Path(args.out)))
    Manager().run()


if __name__ == "__main__":
    main()
