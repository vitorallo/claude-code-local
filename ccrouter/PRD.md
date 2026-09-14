# ccrouter — PRD

## Problem

`cclocal` runs Claude Code against a local MLX model or a remote box that already speaks the Anthropic Messages
API. A 24 GB Mac tops out around a 27B 4-bit model. Meanwhile several hosted providers give away far stronger open
models — NVIDIA's free developer tier serves Nemotron 3 Ultra (550B MoE, 1M context) — but they speak OpenAI
`/v1/chat/completions`, not Anthropic `/v1/messages`, so Claude Code can't use them directly. Free tiers also run
out (rate limits, credits), and a session shouldn't die when one does.

OmniRoute solves this but is a 356-provider Next.js + SQLite application with a dashboard. We want the 5% of it
that matters for one person running Claude Code from a terminal.

## Goal

A small, readable Python router, started and stopped by `cclocal --ccrouter [N|R]`, that lets Claude Code use any
OpenAI-compatible provider and keeps a session alive across quota exhaustion by rotating between configured profiles.

## Non-goals

- A dashboard, database, multi-user auth, or a public listening address.
- Load balancing or per-request spreading across providers (one active profile at a time, by design).
- Native Gemini / Responses-API / OAuth / web-scraper providers. OpenAI-compatible chat completions only.
- Prompt caching, Anthropic thinking signatures, server tools (web search), token-exact counting.

## Users and stories

One developer on a Mac, already using `cclocal`.

1. *As a user* I put my NVIDIA key in a YAML file and run `cclocal --ccrouter` — Claude Code works on Nemotron.
2. *As a user* with several keys/providers I number them as profiles and pick one (`--ccrouter 2`) or let it pick
   (`--ccrouter R`).
3. *As a user* whose free credits run out mid-session, the router moves to the next profile and the failed request
   is retried — I see a log line, not a dead session.
4. *As a user* debugging a weird answer, I can open the exact request that went upstream and the exact response.
5. *As a user* adding a provider, I copy a profile block, change four fields, and run `ccrouter.py test N`.

## Requirements

**Functional**

| # | Requirement |
|---|---|
| F1 | Serve `POST /v1/messages` (streaming SSE and non-streaming), `GET /health`, `GET /v1/models`, `POST /v1/messages/count_tokens` on 127.0.0.1. |
| F2 | Translate Anthropic ↔ OpenAI: system prompt, text, images, tools, tool_choice, tool_use/tool_result, stop reasons, usage. |
| F3 | Tool-call robustness: regroup tool results after their assistant turn, fill missing results, drop orphans, normalise tool ids to 9 alphanumerics (NVIDIA), never silently drop malformed tool arguments. |
| F4 | Config in YAML: numbered profiles, each = base_url + key (inline, env var, or none) + model + context + max_output + extra_body. |
| F5 | Start on profile N (default 1) or a random one (R). Stay on it. |
| F6 | On a limit failure (429, 402, quota/credit/degraded errors) mark the profile cooling down (Retry-After or 60s; credit exhaustion = rest of session), rotate (next number, or random with R), retry the same request. All profiles limited → Anthropic `rate_limit_error`. |
| F7 | Other upstream errors pass through as Anthropic-shaped errors without rotating. |
| F8 | `cclocal --ccrouter [N|R]` starts the router, waits for health, points Claude Code at it, stops it on exit. |
| F9 | CLI: `serve`, `list` (keys masked), `test [N]` (text + streaming tool-call probe). |

**Logging (everything)**

| # | Requirement |
|---|---|
| L1 | `logs/ccrouter.log` (rotating): startup, profiles (masked), picks, rotations, one line per request, errors with upstream body. |
| L2 | `logs/requests.jsonl`: one structured record per request — profile, model, status, latency, TTFT, tokens, stop reason, rotations, errors. |
| L3 | `logs/bodies/<id>.json`: incoming request, each upstream attempt, assembled response; newest N kept. |
| L4 | API keys never appear in any log. |

**Non-functional**

- Two dependencies (httpx, PyYAML), own venv, stdlib HTTP server. Two source files a person can read in one sitting.
- Real keys live only in gitignored `config.yaml` (chmod 600); only `config.yaml.example` is published.
- Adds no latency worth measuring next to the provider's own.

## Success criteria

- `cclocal --ccrouter` completes a Read → Write (quote-dense file) → Edit loop on Nemotron 3 Ultra.
- With profile 1 forced to 429, a request succeeds on profile 2 and the rotation is logged.
- Unit tests pass; `grep` of the public mirror finds no real key.

## Known limits / risks

- NVIDIA's free tier is slow when busy (observed 45–110 s per request) and capped around 40 RPM.
- Different profiles may run different models; a rotation mid-session changes who's answering.
- Keyless providers (pollinations, ovhcloud) are unverified for tool calling and have looser terms of use.
