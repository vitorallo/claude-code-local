# ccrouter

A small Python router that lets Claude Code use OpenAI-compatible LLM providers — NVIDIA's free Nemotron tier,
Mistral's Codestral, Groq, OpenRouter, anything with `/v1/chat/completions` — and moves to another provider when one
hits a limit, is overloaded, or is too slow.

```
Claude Code ──Anthropic /v1/messages──▶ ccrouter (127.0.0.1:8787) ──OpenAI /v1/chat/completions──▶ provider
```

Claude Code only speaks Anthropic's API; almost every hosted provider speaks OpenAI's. ccrouter translates between
the two (tools and streaming included), and `cclocal --ccrouter` runs it for the length of a Claude Code session.

Three source files (`ccrouter.py` the router, `translate.py` the translation, `ccroutermgmt.py` the manager), its own
venv. Why it exists and what it deliberately doesn't do: [PRD.md](PRD.md). Build plan and task list: [PLAN.md](PLAN.md).

**Contents:** [Quick start](#quick-start) · [Get API keys](#get-api-keys) · [Run it](#run-it-cclocal---ccrouter) ·
[ccroutermgmt](#ccroutermgmt) · [Config file](#config-file-reference) · [Command reference](#command-reference) ·
[How profiles rotate](#how-profiles-rotate) · [Logs](#logs) · [HTTP endpoints](#http-endpoints) ·
[Translation](#what-the-translation-handles) · [Providers](#providers) · [Troubleshooting](#troubleshooting) · [Tests](#tests)

---

## Quick start

1. **Install.** `./install.sh` in the repo root (Apple-Silicon Mac). It creates `ccrouter/.venv`, copies
   `config.yaml.example` to `config.yaml`, and installs the `cclocal` and `ccroutermgmt` commands.
   Already installed? `git pull && ./install.sh`.
2. **Get one or two free API keys** — [NVIDIA](#nvidia-nemotron-3-super) and/or [Mistral](#mistral-codestral).
3. **Paste them in.** Run `ccroutermgmt`. On the **Profiles** tab select a row marked **needs key (k)**, press `k`,
   paste, Enter. Press `t` to test: you want two `ok` lines. The router doesn't need to be running for any of this.
4. **Start Claude Code.** `cclocal --ccrouter`, choose the profile in the menu, Enter. No Anthropic account or
   login is needed. The very first start of Claude Code shows a theme picker and security notes (Enter), then
   "Quick safety check: Is this a project you created or one you trust?" with **No, exit** pre-selected — press ↓ to
   **Yes, I trust this folder**, then Enter.

The config a fresh install starts with — the recommended pair:

| # | Profile | Provider · model | Speed (2026-09-14) | Notes |
|---|---|---|---|---|
| 1 | `nvidia-nemotron-super` | NVIDIA · `nvidia/nemotron-3-super-120b-a12b` | ~0.5 s text, ~1.2 s tool call | Free developer tier, ~40 requests/min |
| 2 | `mistral-codestral` | Mistral · `codestral-latest` | ~0.3 s text, ~2.1 s tool call | Coding model, free Experiment plan (trains on your data) |
| 3 | `nvidia-nemotron-ultra` (disabled) | NVIDIA · `nvidia/nemotron-3-ultra-550b-a55b` | ~65 s queue per request | Stronger, too slow on the free tier for interactive use |

Profiles whose key still contains the `xxxx` placeholder are skipped, so you can start with just one key.

> **Privacy.** With ccrouter your prompts, and whatever code Claude Code reads, go to the provider. Mistral's free
> plan uses it for training. Keep client or work code on a local model (`cclocal` without `--ccrouter`).

---

## Get API keys

An API key is a password for programs. Keep it out of chats, screenshots and git; ccrouter stores it only in the
gitignored, owner-only `config.yaml` and never writes it to a log.

### NVIDIA (Nemotron 3 Super)

1. Sign in at [build.nvidia.com](https://build.nvidia.com) — a free NVIDIA account, no credit card.
2. Open [build.nvidia.com/settings/api-keys](https://build.nvidia.com/settings/api-keys) → **Generate API Key**.
3. Copy it; it starts with `nvapi-`.

Free developer tier: about 40 requests per minute plus starting credits. The same key works for every model on
`integrate.api.nvidia.com` (Super, Ultra, Lightning, Kimi, Gemma…).

### Mistral (Codestral)

1. Sign up at [console.mistral.ai](https://console.mistral.ai) and verify your phone number (no credit card).
2. Under **Billing**, choose the free **Experiment** plan — keys don't work until a plan is selected.
3. **API Keys → Create new key**, copy it (it's shown once).

Experiment plan: rate-limited (~1 request/s, generous monthly tokens), all models including Codestral, and it opts
you into data training.

### Other providers

`ccroutermgmt` → **Add provider** lists 14 providers from [`providers.yaml`](providers.yaml), each with where to
get a key. Some need none — see [Providers](#providers).

---

## Run it: `cclocal --ccrouter`

```bash
cclocal --ccrouter        # menu: choose a profile
cclocal --ccrouter 2      # start on profile 2
cclocal --ccrouter R      # start on a random profile
```

**The menu** lists usable profiles (enabled, with a real key) with model, recent median response time from
`logs/requests.jsonl`, and key. `↑/↓` + `Enter` start · `r` random · `Esc` or `q` cancel. It says how many profiles
are hidden because they're disabled or still need a key. With exactly one usable profile it starts straight away;
without a terminal (scripts) it uses profile 1.

**What `cclocal` does in this mode:**

- Checks `ccrouter/.venv` and `ccrouter/config.yaml` exist and the config loads; refuses if port 8787 is taken
  (each session runs its own router).
- Starts `ccrouter.py serve --profile … --port 8787 --parent-pid <cclocal>`, output in `ccrouter/logs/stdout.log`,
  and waits for `/health`.
- Reads the active profile's context window and output cap from `/v1/models`: Claude Code gets
  `CLAUDE_CODE_MAX_CONTEXT_TOKENS` = 85 % of `context`, and `CLAUDE_CODE_MAX_OUTPUT_TOKENS` = the smallest of 32000,
  a quarter of the context, and `max_output`.
- Leaves prompt caching on (no `DISABLE_PROMPT_CACHING`), passes `--no-chrome`, and limits Claude Code to 8 built-in
  tools, like every `cclocal` mode.
- Stops the router when Claude Code exits — also on Ctrl+C, `kill`, or a closed terminal; if `cclocal` is killed
  outright, the router notices its parent is gone within ~2 s and exits.

Other `cclocal` flags that apply: `--server` (keep the router running and print the Claude Code command instead of
launching it), `--out-tokens N`, `--effort LEVEL`, `--chrome` (keep Claude in Chrome's browser tools), `--mcp` and
`--mcp-config FILE` (below).

### MCP tools (Playwright, Context7, …)

By default `cclocal` gives Claude Code **no MCP tools** — only 8 built-in ones — so a request like "troubleshoot it
with Playwright" gets the answer *"I don't have the capability to use Playwright"*: the model was never offered it.
Turn them on per session:

```bash
cclocal --ccrouter --mcp                                  # your usual MCP servers and plugins (claude mcp list)
cclocal --ccrouter --mcp-config ../mcp-playwright.json    # only the servers in that file
```

The first time an MCP tool runs, Claude Code asks for permission. What to expect from the providers:

| Limit | What happens | What to do |
|---|---|---|
| **Tool names ≤ 64 characters**, letters/digits/`_`/`-` only (NVIDIA, Mistral and other OpenAI-style APIs) | ccrouter shortens longer or oddly named MCP tools (hash suffix) and maps the model's calls back to the real names | Nothing — handled |
| **Images** — screenshot tools return images; Nemotron Super and Codestral are text-only | ccrouter replaces each image with a short note unless the profile has `vision: true` | Ask for Playwright's `browser_snapshot` (text page tree); set `vision: true` only for a model that can see |
| **Tokens** — every tool definition is re-sent with every request (Playwright ≈ 20 tools) | Slower requests; free-tier token quotas (Groq's daily cap, OpenRouter's) run out sooner | Load just the server you need with `--mcp-config` |
| **Tool count and schemas** — some providers cap tools per request or reject unusual JSON-schema constructs | A 400 from the provider on every request after enabling MCP | Check the Live log / `ccrouter.log` for the provider's message; trim the servers |
| **Model skill** — smaller models choose tools poorly | Wrong tool, or tools ignored | Prefer the stronger profile for tool-heavy work |

MCP servers run on your Mac, but what they return — page contents, files — is sent to the provider like any other
prompt.

---

## ccroutermgmt

```bash
ccroutermgmt              # installed by install.sh; or ./ccrouter/ccroutermgmt
```

A full-screen settings and monitoring app. **It works whether or not the router is running.** The top bar says
which: `router running … active profile N`, or `router not running` — in which case it's simply a config editor and
everything is saved for the next `cclocal --ccrouter`. If `config.yaml` doesn't exist yet, it's created on the first
save.

Click the tab names (the mouse works everywhere) or use the keyboard.

**Everywhere:** `q` quit · `r` reload the config from disk · `Ctrl+P` command palette.

### Profiles tab

Columns: `#` (the number `--ccrouter N` uses), state (`● active`, `on`, `off`, `cooling Ns`, `used up`), name, model,
key (masked, or **needs key (k)**), base_url.

| Key | Action |
|---|---|
| `↑` `↓` | select a profile |
| `k` | set the API key (hidden input; replaces `api_key_env` if one was set) |
| `t` | test: a text request and a streaming tool-call request straight to the provider; results in the box below |
| `e` | switch the profile on/off (`enabled: false`) |
| `a` | make it the active profile *now* in the running router (next request goes there) |
| `shift+↑` / `shift+↓` | swap with the profile above/below — changes their numbers |
| `x` then `x` again within 3 s | delete |

### Add provider tab

The left table is the catalog in `providers.yaml`: provider, key (`needed`, `NO KEY`, `any string`), free tier,
terms-of-use rating. Selecting a row shows its endpoint, where to get a key, and notes from our own tests.

1. Pick a model from the list, **or** type any model id, **or** paste the key and press **Fetch models** to load the
   provider's live list.
2. Paste the API key (leave empty for `NO KEY` providers; `any string` providers get a dummy one).
3. **Add as new profile** — it's appended with the next free number and the provider's context, output cap and
   extra settings. You're taken to Profiles with it selected: press `t`.

### Live log tab

Follows `logs/ccrouter.log` as the router works. Green: a request that returned 2xx · yellow: warnings (e.g. a
provider said overloaded) · magenta: `rotate profile 1 -> 2` · red: errors and 4xx/5xx. The filter box takes a
case-insensitive regex, e.g. `rotate|503`, `stop=tool_use`, `cached=[1-9]`, `p2 `.

### Saving

Every change writes `config.yaml` at once (owner-only, `0600`; the previous version is kept as `config.yaml.bak`)
and, if the router is running, hot-reloads it. The file is rewritten by the app, so hand-written comments aren't
kept. If the change leaves the config unusable, the running router keeps its old profiles and you get a warning.

### Other ways to run it

| Command | What it does |
|---|---|
| `ccroutermgmt pick --out FILE` | Only the profile menu; writes `1`, `2`, … or `R` to FILE. Exit code 130 if cancelled. This is what `cclocal --ccrouter` runs |
| `CCROUTER_CONFIG=/path/to/config.yaml ccroutermgmt` | Manage a different config file |

---

## Config file reference

`ccrouter/config.yaml` — created from `config.yaml.example` by `install.sh`, gitignored, owner-only. Edit it with
`ccroutermgmt` or any text editor (spaces, not tabs), then check it with `.venv/bin/python ccrouter.py test`.

```yaml
listen:
  host: 127.0.0.1
  port: 8787
log:
  level: info
  bodies: true
  bodies_keep: 100
profiles:
  1:
    name: nvidia-nemotron-super
    base_url: https://integrate.api.nvidia.com/v1
    api_key: nvapi-...
    model: nvidia/nemotron-3-super-120b-a12b
    context: 1000000
    max_output: 16384
    first_token_timeout: 30
    extra_body:
      chat_template_kwargs: {enable_thinking: false, force_nonempty_content: true}
  2:
    name: mistral-codestral
    base_url: https://api.mistral.ai/v1
    api_key: ...
    model: codestral-latest
    context: 128000
```

### Top level

| Key | Default | Meaning |
|---|---|---|
| `listen.host` | `127.0.0.1` | Address the router listens on. Keep it local: the admin endpoints have no auth |
| `listen.port` | `8787` | Port for `ccrouter.py serve` without `--port`. `cclocal` always uses 8787, and `ccroutermgmt` looks for the router on this port |
| `log.level` | `info` | `debug`, `info` or `warning` |
| `log.dir` | `ccrouter/logs` | Where logs go |
| `log.bodies` | `true` | Save the full request/response of every call in `logs/bodies/` |
| `log.bodies_keep` | `100` | How many body files to keep (newest) |
| `profiles` | — | Numbered profiles; the numbers are the YAML keys |

### Profile fields

| Field | Required | Default | Meaning |
|---|---|---|---|
| `base_url` | yes | — | Everything before `/chat/completions`, e.g. `https://api.mistral.ai/v1` |
| `model` | yes | — | The provider's model id |
| `name` | no | `profile-N` | Label in menus and logs |
| `api_key` | no | none | The key. A value containing `xxxx` counts as the template placeholder and the profile is skipped |
| `api_key_env` | no | — | Read the key from this environment variable instead; the router won't start if it's unset |
| `enabled` | no | `true` | `false` keeps the profile but never uses it (not validated either) |
| `context` | no | `128000` | Context window advertised to Claude Code, which auto-compacts at 85 % of it |
| `max_output` | no | none | Clamp for Claude Code's `max_tokens`; also caps Claude Code's output budget at launch |
| `first_token_timeout` | no | `45` | Seconds to wait for the first byte before rotating — only when another profile is available |
| `timeout` | no | `600` | Seconds allowed between streamed chunks before the request fails |
| `extra_body` | no | — | Merged into every request sent upstream (e.g. `chat_template_kwargs` to turn thinking off) |
| `vision` | no | `false` | `true` if the model can read images; otherwise images (screenshots from tools, pasted pictures) are replaced by a short note, since text-only models reject them |

Profiles without a key are sent with no `Authorization` header (keyless providers). YAML anchors (`&key` / `*key`)
work for sharing a key or `extra_body` between profiles; `ccroutermgmt` expands them when it saves.

---

## Command reference

### `cclocal` (ccrouter-related flags)

| Flag | Meaning |
|---|---|
| `--ccrouter` | Start ccrouter and Claude Code; choose the profile in a menu |
| `--ccrouter N` | …starting on profile N |
| `--ccrouter R` | …starting on a random usable profile |
| `--server` | Keep the router up and print the Claude Code command instead of launching it (Ctrl+C stops it) |
| `--out-tokens N` | Override Claude Code's output-token budget |
| `--effort LEVEL` | Effort Claude Code asks for: `low` (default), `medium`, `xhigh`, `unset` |
| `--chrome` | Keep the Claude in Chrome browser tools (off by default: ~22 tools, ~14k tokens per request) |
| `--mcp` | Load your usual MCP servers and plugins — see [MCP tools](#mcp-tools-playwright-context7-) |
| `--mcp-config FILE` | Load only the MCP servers in FILE (e.g. `mcp-playwright.json` in the repo root) |

### `ccrouter.py`

Run with the venv: `ccrouter/.venv/bin/python ccrouter/ccrouter.py …`

| Command | Options | What it does |
|---|---|---|
| *(global)* | `--config PATH` (default `ccrouter/config.yaml`) | Which config file to use |
| `serve` | `--profile N\|R` (default `1`) · `--port P` (default `listen.port`) · `--parent-pid PID` | Run the router. `--parent-pid` makes it exit when that process disappears |
| `list` | — | Usable profiles with masked keys; skipped ones on stderr |
| `test` | `[N]` (default: all usable) | Text probe + streaming tool-call probe per profile; exit code 1 if any fails |

### `ccroutermgmt`

| Command | What it does |
|---|---|
| `ccroutermgmt` | The management app |
| `ccroutermgmt pick --out FILE` | The profile menu only |
| env `CCROUTER_CONFIG` | Config file to manage (default `ccrouter/config.yaml`) |

---

## How profiles rotate

- The router starts on the chosen profile and **stays there**.
- When a request fails, that profile cools down, the router moves to the next usable profile (next number up,
  wrapping; random with `R`) and **retries the same request**. Claude Code never sees the failure. Three triggers:

  | Trigger | Detected as | Cooldown |
  |---|---|---|
  | **Limit** | HTTP 429 or 402, or a 400/403 mentioning quota, credit, rate limit or `DEGRADED` | `Retry-After`, else 60 s; credit/quota exhaustion = rest of the session |
  | **Overloaded** | HTTP 503/529 or "overloaded" — including NVIDIA's 200-then-503 first stream chunk | 30 s |
  | **Slow** | nothing back within the profile's `first_token_timeout` (default 45 s) | 120 s |

  "Slow" only applies when another profile is available; a profile on its own is waited on as long as it takes.
  An abandoned slow request is closed when it eventually answers.
- If every profile is cooling down after a limit, Claude Code gets an Anthropic `rate_limit_error`; after an
  overload it gets the provider's 503. Either way it retries on its own.
- Other errors (401, 500, unreachable) don't rotate; they reach Claude Code as normal API errors.
- A connection the provider dropped while idle (NVIDIA does this) is retried once on a fresh one.
- `ccroutermgmt` → `a` switches the active profile by hand at any time.

What this can't fix: a provider that is slow for everyone. On NVIDIA's free tier (2026-09-14) Nemotron 3 **Super**
answered in ~0.5 s while **Ultra** queued ~65 s on every request — hence Super first and Ultra disabled.

---

## Logs

Everything lands in `ccrouter/logs/` (gitignored). Keys are never written; the log shows them masked (`nvapi-…u-tZ`).

| File | What |
|---|---|
| `ccrouter.log` | Human log, rotating 5 MB × 5: startup, profiles, rotations, one line per request, upstream error bodies, config reloads |
| `requests.jsonl` | One JSON line per request: profile, model, status, `ttft_ms`, `total_ms`, input/cached/output tokens, `stop_reason`, rotations, errors |
| `bodies/<id>.json` | Full incoming request, each upstream attempt, assembled response. Newest `log.bodies_keep` kept |
| `stdout.log` | Raw process output when started by `cclocal` (tracebacks land here) |

A request line in `ccrouter.log` reads:

```
req_2212daccf95b POST /v1/messages p1 nvidia/nemotron-3-super-120b-a12b stream=True msgs=2 tools=8 -> 200 stop=end_turn in=6028 cached=0 out=17 1402ms
```

`p1` profile · `msgs` conversation length · `tools` tools offered · `-> 200` status · `stop` why the model stopped
(`tool_use` = it called a tool) · `in` / `cached` / `out` tokens · total time.

```bash
tail -f logs/ccrouter.log                  # or ccroutermgmt → Live log
jq -c '{profile, status, stop_reason, total_ms, output_tokens}' logs/requests.jsonl | tail
```

---

## HTTP endpoints

The router listens on `127.0.0.1` only.

| Method · path | Used by | What |
|---|---|---|
| `GET /health` | `cclocal` | `{"status": "healthy", "profile", "name", "model"}` |
| `GET /v1/models` | `cclocal` | Active profile as model `ccrouter`, with `upstream_model`, `max_model_len`, `max_output_tokens` |
| `POST /v1/messages` | Claude Code | Anthropic Messages API, streaming and not |
| `POST /v1/messages/count_tokens` | Claude Code | Rough estimate (characters / 4) |
| `GET /admin/status` | ccroutermgmt | Active profile, usable profiles, cooldowns |
| `POST /admin/reload` | ccroutermgmt | Re-read the config file; 400 (and no change) if it isn't usable |
| `POST /admin/activate` | ccroutermgmt | Body `{"profile": N}`: make N active now |

---

## What the translation handles

- System prompt (string or blocks), minus Claude Code's per-request billing-header line.
- Tools and `tool_choice`; `tool_use` → `tool_calls`; `tool_result` → `role: tool`, including error flags and
  images (lifted into a following user message).
- Tool results regrouped right after the assistant turn that asked for them, missing ones filled with a
  placeholder, orphans dropped — OpenAI-style servers reject the request otherwise.
- Tool ids hashed to 9 alphanumerics (NVIDIA rejects anything else); deterministic, so calls and results still pair.
- Tool names longer than 64 characters or with characters outside `A-Z a-z 0-9 _ -` (possible with MCP tools) are
  shortened with a hash suffix for the provider and mapped back in the response.
- Images are sent as `image_url` parts only for profiles with `vision: true`; otherwise replaced by a note.
- Streaming: text streams through; tool calls are buffered and emitted whole once their JSON is validated.
  Malformed arguments are passed on as an obviously invalid input rather than dropped, so the model sees the error
  and retries instead of a `Write` silently never happening. `ping` events keep the stream alive meanwhile.
- A provider error arriving as the first chunk of a 200 stream becomes a real HTTP error before anything reaches
  Claude Code, so it can trigger rotation.
- `finish_reason` → `stop_reason`; usage; reasoning tokens counted and logged but not shown.
- Prompt caching: Anthropic's `cache_control` markers mean nothing to OpenAI-style providers, but many cache a
  repeated prompt prefix on their own. The translation keeps that prefix stable: the billing-header line is
  stripped, and system messages Claude Code puts mid-conversation stay in place (as `<system-reminder>` user text)
  instead of being merged into the top prompt. Cached tokens a provider reports come back as
  `cache_read_input_tokens` and show as `cached=` in the log (NVIDIA: 4,320 of 9,406 tokens cached on a repeat).
- Thinking blocks from earlier turns are dropped (other providers can't verify Anthropic signatures).

---

## Providers

[`providers.yaml`](providers.yaml) is the catalog behind **Add provider**: 14 OpenAI-compatible providers with
endpoint, whether a key is needed and where to get one, free tier, terms-of-use rating, suggested models and our
probe notes — NVIDIA, Groq, Mistral, OpenRouter, Ollama Cloud, Requesty, SiliconFlow, Zhipu GLM, and keyless ones.
Sourced from OmniRoute's catalog (2026-09). Add a provider to the file and it shows up in the app.

By hand: copy a profile, set `base_url`, `model`, key and `context`, then `ccrouter.py test N`. The tool-call probe
is the one that matters — Claude Code is useless without tool calling.

Providers that need **no registration or key**, and what happened when we tried them (2026-09-14):

| Provider | base_url | Result |
|---|---|---|
| ovhcloud | `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1` | Works, but anonymous is 2 requests/min per IP per model — 429 almost immediately. Last-resort fallback only |
| kilo-gateway | `https://api.kilo.ai/api/gateway` | Not probed. Its free models **train on your prompts** |
| opencode-zen | `https://opencode.ai/zen/v1` | Not probed. Rated "avoid" for terms of use |
| uncloseai | `https://hermes.ai.unturf.com/v1` | The catalog's model id returned 404; ids change, use Fetch models |
| llm7 | `https://api.llm7.io/v1` | Not probed. Needs any key string |
| pollinations | `https://gen.pollinations.ai/v1` | **Not keyless any more**: 401 "A valid API key is required" |

AI Horde is keyless too but has no tool calling. The other "keyless" OmniRoute entries are web scrapers or OAuth flows.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ccroutermgmt: command not found` | Open a new terminal, run `./ccrouter/ccroutermgmt` from the repo, or re-run `./install.sh` |
| **needs key (k)** in red, or `skipped: … placeholder` | That profile's key is still the template's `xxxx` — select it in ccroutermgmt, press `k`, paste |
| `config error: … put a real key in config.yaml` | No profile has a real key yet — same fix |
| `t` shows `FAIL HTTP 401` or `403` | Wrong key. Mistral: choose the Experiment plan under Billing first |
| `t` shows `FAIL HTTP 429` | Free quota or rate limit — wait, or add a second profile so the router can fail over |
| `port 8787 is already in use` | Another `cclocal --ccrouter` session is running; each session runs its own router |
| Every turn takes a minute | You're on Nemotron **Ultra** (~65 s free queue). Use Super, or switch live with ccroutermgmt → `a` |
| `Waiting for API response · will retry in 4m` | The provider kept failing (e.g. 503 overloaded) and Claude Code is backing off. With a second usable profile the router fails over instead — check the Live log tab |
| ccroutermgmt says "router not running" but it is | That router predates the admin endpoints — restart `cclocal --ccrouter` |
| `rate_limit_error: every profile has hit its limit` | All profiles cooling down. Add another profile, or wait the time in the message |
| `response exceeded the N output token maximum` | The file being written is larger than `max_output` allows; raise it if the provider allows, or ask for the file in parts |
| Model answers but never calls tools | That model/provider doesn't support tool calling — `ccrouter.py test N` shows it |
| "I don't have the capability to use Playwright" (or any MCP tool) | The tools aren't loaded — start with `cclocal --ccrouter --mcp` (or `--mcp-config FILE`) |
| Every request fails with a 400 after adding `--mcp` | A provider limit on tool count or schemas — read the error in the Live log, load fewer servers with `--mcp-config` |
| Anything else | `ccrouter/logs/stdout.log` (startup errors, tracebacks) and `ccrouter/logs/ccrouter.log` |

---

## Tests

```bash
.venv/bin/python -m unittest discover -s tests
```

Translation golden cases, plus end-to-end rotation against a fake upstream: limit, overload and slow-start
failover, all-limited `rate_limit_error`, 5xx not rotating, admin status/activate/reload, disabled and placeholder
profiles, keys never logged.
