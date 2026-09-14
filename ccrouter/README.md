# ccrouter

A small Python router that lets Claude Code use OpenAI-compatible LLM providers — NVIDIA's free Nemotron tier,
Groq, OpenRouter, anything with `/v1/chat/completions` — and rotates to another provider or key when one hits its
limit.

```
Claude Code ──Anthropic /v1/messages──▶ ccrouter (127.0.0.1:8787) ──OpenAI /v1/chat/completions──▶ provider
```

Two source files (`ccrouter.py`, `translate.py`), two dependencies (`httpx`, `PyYAML`), its own venv.
Why it exists and what it deliberately doesn't do: [PRD.md](PRD.md). Build plan and task list: [PLAN.md](PLAN.md).

## Install

`./install.sh` in the repo root does it all. By hand:

```bash
cd ccrouter
uv venv .venv && uv pip install --python .venv/bin/python3 -r requirements.txt
cp config.example.yaml config.yaml && chmod 600 config.yaml   # then put your key in it
```

Get an NVIDIA key at [build.nvidia.com](https://build.nvidia.com/settings/api-keys) (free developer program, no card).

## Use

```bash
cclocal --ccrouter        # profile 1
cclocal --ccrouter 2      # profile 2
cclocal --ccrouter R      # a random profile
```

`cclocal` starts the router, waits for it, points Claude Code at it, and stops it when Claude Code exits. It reads
the profile's context window and output cap from `/v1/models`, so auto-compact and `max_tokens` match the provider.

The router on its own:

```bash
.venv/bin/python ccrouter.py list          # profiles, keys masked
.venv/bin/python ccrouter.py test 1        # text probe + streaming tool-call probe
.venv/bin/python ccrouter.py serve --profile R --port 8787
```

## Config

```yaml
profiles:
  1:
    name: nvidia-nemotron-ultra
    base_url: https://integrate.api.nvidia.com/v1   # everything before /chat/completions
    api_key: nvapi-...          # or api_key_env: NVIDIA_API_KEY, or omit for keyless providers
    model: nvidia/nemotron-3-ultra-550b-a55b
    context: 1000000            # advertised to Claude Code (it compacts at 85%)
    max_output: 16384           # Claude Code's max_tokens is clamped to this
    timeout: 600                # optional, seconds between streamed chunks
    extra_body:                 # optional, merged into every upstream request
      chat_template_kwargs: {enable_thinking: false, force_nonempty_content: true}
```

Profile numbers are the YAML keys. `config.example.yaml` has commented profiles for a second NVIDIA key,
Nemotron Super, Groq, OpenRouter and two keyless providers.

## How profiles rotate

- The router starts on the chosen profile and **stays there**.
- When a request fails for hitting a limit — HTTP 429 or 402, or a 400/403 mentioning quota, credit, rate limit or
  `DEGRADED` — that profile cools down (`Retry-After`, else 60 s; credit/quota exhaustion = rest of the session),
  the router moves to the next profile (next number up, wrapping; random with `R`) and **retries the same request**.
  Claude Code never sees the failure.
- If every profile is cooling down, Claude Code gets an Anthropic `rate_limit_error` and retries on its own.
- Other errors (401, 5xx, timeouts) don't rotate; they reach Claude Code as normal API errors.

## Logs

Everything lands in `ccrouter/logs/` (gitignored). Keys are never written.

| File | What |
|---|---|
| `ccrouter.log` | Human log, rotating 5 MB × 5: startup, profiles, rotations, one line per request, upstream error bodies |
| `requests.jsonl` | One JSON line per request: profile, model, status, `ttft_ms`, `total_ms`, tokens, `stop_reason`, rotations, errors |
| `bodies/<id>.json` | Full incoming request, each upstream attempt, assembled response. Newest `bodies_keep` (100) kept; `log.bodies: false` turns it off |
| `stdout.log` | Raw process output when started by `cclocal` (tracebacks land here) |

```bash
tail -f logs/ccrouter.log
jq -c '{profile, status, stop_reason, total_ms, output_tokens}' logs/requests.jsonl | tail
```

## What the translation handles

- System prompt (string or blocks), minus Claude Code's per-request billing-header line.
- Tools and `tool_choice`; `tool_use` → `tool_calls`; `tool_result` → `role: tool`, including error flags and
  images (lifted into a following user message).
- Tool results regrouped right after the assistant turn that asked for them, missing ones filled with a
  placeholder, orphans dropped — OpenAI-style servers 400 otherwise.
- Tool ids hashed to 9 alphanumerics (NVIDIA rejects anything else); deterministic, so calls and results still pair.
- Streaming: text streams through; tool calls are buffered and emitted whole once their JSON is validated.
  Malformed arguments are passed on as an obviously invalid input rather than dropped, so the model sees the error
  and retries instead of a `Write` silently never happening. `ping` events keep the stream alive meanwhile.
- `finish_reason` → `stop_reason`; usage; reasoning tokens counted and logged but not shown.
- Thinking blocks from earlier turns are dropped (other providers can't verify Anthropic signatures).

## Adding a provider

Copy a profile, set `base_url`, `model`, key, `context`, then `ccrouter.py test N`. The tool-call probe is the one
that matters — Claude Code is useless without tool calling.

Providers that need **no registration or key** (from OmniRoute's catalog; unverified for tool calling, looser terms):

| Provider | base_url | Models to try |
|---|---|---|
| ovhcloud | `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1` | `gpt-oss-120b`, `Qwen3.6-27B` |
| pollinations | `https://gen.pollinations.ai/v1` | `qwen-coder`, `openai`, `deepseek` |
| uncloseai | `https://hermes.ai.unturf.com/v1` | `qwen3.6:27b` |

AI Horde is keyless too but has no tool calling. The other "keyless" OmniRoute entries are web scrapers or OAuth flows.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `config error: api_key is still the placeholder` | Put the real key in `config.yaml`. |
| `port 8787 is already in use` | Another `cclocal --ccrouter` session is running; each session runs its own router. |
| Every turn takes a minute | NVIDIA's free tier queues when busy (45–110 s observed). Try `nemotron-3-super-120b-a12b` or a second provider. |
| `rate_limit_error: every profile has hit its limit` | All profiles cooling down. Add another profile, or wait the time in the message. |
| `response exceeded the N output token maximum` | Profile's `max_output` is lower than the file being written; raise it if the provider allows, or ask for the file in parts. |
| Model answers but never calls tools | That model/provider doesn't support tool calling — `ccrouter.py test N` shows it. |

## Tests

```bash
.venv/bin/python -m unittest discover -s tests
```

Translation golden cases, plus end-to-end rotation against a fake upstream (429 on profile 1 → success on
profile 2, all-limited → `rate_limit_error`, 5xx doesn't rotate, keys never logged).
