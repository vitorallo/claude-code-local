# ccrouter — plan and task list

## Approach

- **Translating proxy, not a pass-through.** Claude Code speaks Anthropic `/v1/messages`; NVIDIA and nearly every
  free provider speak OpenAI `/v1/chat/completions`. `translate.py` holds pure conversion functions ported from
  OmniRoute's `claude-to-openai` / `openai-to-claude` translators; `ccrouter.py` holds everything with I/O.
- **Stdlib server, two deps.** `ThreadingHTTPServer` + `httpx` (upstream, streaming) + `PyYAML`. Own venv via `uv`.
- **One active profile.** Start on N or random; stay; rotate only on a limit failure, retrying that request before
  any byte reaches Claude Code (upstream status is known before the response is relayed).
- **Wired into cclocal as a remote.** `--ccrouter` starts the router, then reuses remote mode unchanged: health check,
  `/v1/models` auto-detect of model id and context window, env for Claude Code. The router advertises
  `max_output_tokens` too, and `run.sh` now caps Claude Code's output budget by it.
- **Log everything, leak nothing.** Human log, JSONL per request, full bodies per request; keys masked everywhere.

Provider facts it relies on (NVIDIA): base `https://integrate.api.nvidia.com/v1`, Bearer key, model
`nvidia/nemotron-3-ultra-550b-a55b`, 1M context, ~40 RPM free tier; tool-call ids must be `^[A-Za-z0-9]{9}$`;
thinking off via `chat_template_kwargs.enable_thinking=false`; `stream_options` only when streaming.

## Tasks

### Router
- [x] `translate.py`: system/billing-header, messages, images, tools, tool_choice
- [x] Tool-result regrouping, missing-result placeholders, orphan drop, 9-char tool ids
- [x] Non-streaming response mapping; stop reasons; usage
- [x] `StreamTranslator`: text streaming, buffered + validated tool calls, split id/name, resent-args dedup,
      trailing usage chunk, empty stream, leading-whitespace hold-back
- [x] `ccrouter.py`: YAML config + validation (placeholder key, env keys, keyless profiles)
- [x] Router: start N / R, stay, rotate on 429/402/quota text with cooldowns, all-limited → `rate_limit_error`
- [x] Endpoints: `/health`, `/v1/models` (context + max output), `/v1/messages`, `/v1/messages/count_tokens`
- [x] Logging: `ccrouter.log`, `requests.jsonl`, `bodies/` with pruning, masked keys, stream pings
- [x] CLI: `serve`, `list`, `test [N]`

### cclocal integration
- [x] `run.sh`: resolve the `cclocal` symlink for `SCRIPT_DIR` (was `~/.local/bin`)
- [x] `run.sh`: `--ccrouter [N|R]` flag, help and examples
- [x] `run.sh`: start router, health wait, stop on exit (and in `--server` mode, keep it alive)
- [x] `run.sh`: display upstream model; cap output tokens by advertised `max_output_tokens`
- [x] `install.sh`: ccrouter venv step, config.yaml from example (chmod 600)
- [x] `.gitignore`: `ccrouter/config.yaml`, `ccrouter/logs/`

### Verification
- [x] Unit tests: translation golden cases; rotation against fake upstream; keys never logged
- [x] `ccrouter.py test 1` against NVIDIA: text ok, streaming tool call ok (`get_weather({"city": "Rome"})`)
- [x] Real Claude Code session through the router on Nemotron 3 Ultra: Write a quote-dense file → Edit it →
      reply; file runs. Also covered Claude Code's title-generation side call.
- [x] Found live and fixed: NVIDIA answers 200 then sends `{"error": 503 overloaded}` as the first chunk → now
      turned into a real HTTP error before our 200 goes out, so Claude Code retries
- [x] Found live and fixed: Claude Code sends `system`-role messages inside `messages[]` → hoisted into the
      top system prompt (strict OpenAI servers reject a non-leading system message)
- [x] `cclocal --ccrouter R --server`: router starts, random pick logged, env points at it, stops on exit
- [ ] Second profile (another key or provider) to exercise real rotation

### Docs and publishing
- [x] `PRD.md`, `README.md`, this plan
- [x] Root README: ccrouter section + flag row
- [x] Public mirror: publish code/docs/example config only; verify no real key before push; fresh clone passes tests

### Later (not now)
- [ ] `show_thinking` option: emit reasoning as Anthropic thinking blocks
- [ ] Try keyless providers (ovhcloud, pollinations) for tool calling and document results
- [ ] Per-profile RPM throttle to stay under NVIDIA's 40 RPM instead of eating 429s
