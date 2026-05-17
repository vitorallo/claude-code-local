# Claude-Code-Local

**The only setup that actually works.** Run Claude Code with local LLMs on Apple Silicon — real tool execution, real agentic loops, fully offline.

Every tutorial out there tells you to point Claude Code at Ollama or llama.cpp and call it a day. None of them work. The model generates text that *looks like* a tool call, but nothing executes. No files get created, no commands run, no code gets written. You're watching a convincing hallucination.

This project uses [vllm-mlx](https://github.com/waybarrios/vllm-mlx) — the only backend that speaks Claude Code's native language: the Anthropic Messages API with real `tool_use` content blocks. When the model decides to read a file, it actually reads the file. When it writes code, the code lands on disk. The agentic loop works — tool calls chain into tool results, the model iterates, and you get the real Claude Code experience running entirely on your hardware.

No API key. No cloud. No subscription. No data leaves your machine. Just `./install.sh` and go.

## What you need

- Apple Silicon Mac (M1/M2/M3/M4/M5)
- 16GB+ unified memory (24GB+ recommended)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [Homebrew](https://brew.sh)

## Quick start

```bash
git clone https://github.com/vitorallo/claude-code-local.git
cd claude-code-local
./install.sh
cclocal
```

First run downloads the default model (~5GB, one-time). Then starts vllm-mlx and launches Claude Code.

### Verify it works

In Claude Code, type:

```
create a file called /tmp/test_tools.txt with "hello world"
```

**Working**: Claude Code calls the Write tool, creates the file, confirms.
**Broken**: Claude Code generates text saying it created the file, but nothing exists on disk. 

## Models

| Flag | Model | Size | RAM needed | Notes |
|------|-------|------|-----------|-------|
| *(default)* `--gemma-light` | Gemma-4-E4B | ~5GB | 16GB+ | Clean tool calling, verified end-to-end |
| `--gemma` | Gemma-4-26B-A4B MoE | ~16GB | 24GB+ | Google MoE, 3.8B active params |
| `--review` | GLM-4.7-Flash | ~17GB | 24GB+ | Stronger reasoning |
| `--coder` | Qwen3-Coder-30B-A3B | ~18GB | 24GB+ | Heavier code model |
| `--qwen3` | Qwen3.5-9B | ~5GB | 16GB+ | General reasoning — leaks plain-text thinking [1] |
| `--coder7b` | Qwen2.5-Coder-7B | ~5GB | 16GB+ | Code analysis — tool calls unreliable [2] |
| `--light` | *(alias)* | | | Back-compat alias for `--gemma-light` (v2.0.1 pointed at Qwen3.5-9B) |
| `--model ID` | Any MLX model | varies | varies | Custom HuggingFace model ID (not tested) |

[1] Qwen3.5 is a hybrid-thinking model that ignores `enable_thinking=false` at
the template level and emits plain-text "Thinking Process:" preamble outside
`<think>` tags. Known upstream issue; see
[vllm-project/vllm#35574](https://github.com/vllm-project/vllm/issues/35574)
and [QwenLM/Qwen3#1625](https://github.com/QwenLM/Qwen3/issues/1625). Use
only if you want general reasoning and tolerate verbose output.

[2] Qwen2.5-Coder-7B hallucinates an XML tool-call format
(`<Write path="..." content="..."/>`) that no parser handles. Good for
non-agentic code analysis where you feed it whole files, not for Claude
Code's tool loop. Use `--gemma-light` for tool calling work instead.

```bash
cclocal                # Interactive menu: pick model, see what's cached, manage cache
cclocal --gemma-light  # Direct launch, Gemma-4-E4B (default, clean tool calling)
cclocal --gemma        # Direct launch, Gemma-4-26B MoE
cclocal --review       # Direct launch, GLM-4.7-Flash
cclocal --coder        # Direct launch, Qwen3-Coder-30B-A3B
cclocal --list         # List cached models on disk
cclocal --rm           # Manage/delete cached models (interactive)
cclocal --server       # Start server only, connect Claude Code separately
cclocal -h             # Show all options
```

Running `cclocal` with no arguments opens an interactive menu that shows every
supported model, indicates which are already cached on disk, and lets you pick
one or jump to a cache management screen. Use the model flags to skip the menu
when you already know what you want.

### Server-only mode

```bash
cclocal --server
```

Then connect Claude Code from any terminal:

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8000 \
ANTHROPIC_API_KEY=not-needed \
ANTHROPIC_MODEL=mlx-community/gemma-4-e4b-it-4bit \
claude --strict-mcp-config --mcp-config /path/to/claude-code-local/mcp-local.json \
  --tools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
```

> Replace `/path/to/claude-code-local` with wherever you cloned the repo. Or just use `cclocal --server` which prints the full command for you.

---

## Why this is hard (and how we solved it)

Running Claude Code with a local model isn't just "point it at localhost". There are 15 problems that break the experience. This section documents every one and how `run.sh` handles it.

### 1. Ollama can't produce real tool calls

**Problem**: Ollama's Anthropic API adapter generates text that *looks like* tool calls but never emits real `tool_use` content blocks. Claude Code receives plain text, never executes anything. Tested with qwen3.5:9b, qwen3.5:35b-a3b, glm-4.7-flash — all produce fake tool calls.

**Solution**: Use vllm-mlx. It implements the native Anthropic Messages API with real `tool_use` / `tool_result` content blocks.

### 2. `end_turn` vs `stop` (the loop killer)

**Problem**: Claude Code needs `stop_reason: "end_turn"` to know the model finished. Backends returning `"stop"` (OpenAI convention) cause Claude Code to stop looping after the first response — no tool calls, no iteration.

**Solution**: vllm-mlx's native `/v1/messages` endpoint returns correct Anthropic stop reasons.

### 3. Reasoning/thinking tokens (garbage output)

**Problem**: Qwen 3.x and Gemma 4 models emit thinking/reasoning tokens. Claude Code doesn't expect these — causes garbage output and misparses tool calls.

**Solution**: `run.sh` sets `VLLM_MLX_ENABLE_THINKING=false` on the server, which passes `enable_thinking=False` to the chat template. This suppresses thinking tokens at the template level for all models.

### 4. KV cache invalidation (90% slowdown)

**Problem**: Claude Code's attribution header changes every request, invalidating the KV cache. Follow-up responses go from 2s to 30s+.

**Solution**: `CLAUDE_CODE_ATTRIBUTION_HEADER=0` disables the header (set by `run.sh`).

### 5. Background Haiku model calls (crash)

**Problem**: Claude Code calls `claude-haiku-4-5-20251001` for background tasks. The local server doesn't recognize it — 404 — hang.

**Solution**: All model tier env vars (`ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`) are set to the same local model (set by `run.sh`).

### 6. Token counting endpoint (silent failure)

**Problem**: Claude Code calls `/v1/messages/count_tokens`. Most local servers don't implement it.

**Solution**: vllm-mlx supports it. `DISABLE_PROMPT_CACHING=1` reduces dependence on it.

### 7. Concurrent requests OOM

**Problem**: Claude Code fires concurrent requests (main + background + subagents). Two concurrent 24K+ token prompts exceed the Metal GPU buffer limit on 24GB and crash the server.

**Solution**: Run in single-request mode (no `--continuous-batching`). Requests serialize instead of competing for Metal memory. Additionally, `--kv-cache-quantization` halves KV cache memory usage, giving more headroom before OOM.

### 8. Streaming format mismatches (partial responses)

**Problem**: Claude Code expects Anthropic SSE events. OpenAI-format streaming shows only the last token.

**Solution**: vllm-mlx uses native Anthropic SSE streaming.

### 9. Tool flooding (259 tools overwhelm local models)

**Problem**: Claude Code sends ALL tool definitions in every request. With plugins enabled, that's 200+ tools crammed into the system prompt. Even 30B models choke.

**Solution**: Two flags strip tools down to essentials:
```
--strict-mcp-config --mcp-config mcp-local.json    # strips all plugin/MCP tools
--tools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"  # 8 built-in tools only
```

Your plugins remain available when running Claude Code normally with the cloud API.

### 10. Real API key leaking to local server

**Problem**: Your real `ANTHROPIC_API_KEY` (`sk-ant-...`) is set in the shell. Claude Code detects it and may send it to the local server.

**Solution**: `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN` in `run.sh` explicitly unsets real keys before setting the dummy one.

### 11. Autoupdater and telemetry (network-dependent startup)

**Problem**: Claude Code tries to check for updates and send telemetry on startup, which can hang or slow down local-only sessions.

**Solution**: Session env vars:
```
DISABLE_AUTOUPDATER=1
DISABLE_TELEMETRY=1
DISABLE_ERROR_REPORTING=1
```

### 12. Memory pressure on 24GB

| Model | Size | Free RAM | Status |
|-------|------|----------|--------|
| **Gemma-4-E4B** | **~5GB** | **~19GB** | **Default — verified tool loop** |
| Qwen3.5-9B | ~5GB | ~19GB | Works but leaks plain-text thinking |
| Qwen2.5-Coder-7B | ~5GB | ~19GB | Code analysis only — tool calls unreliable |
| Gemma-4-26B-A4B MoE | ~16GB | ~8GB | Fast inference, tight on 24GB |
| GLM-4.7-Flash | ~16.9GB | ~7GB | Works single-request only |

### 13. vllm-mlx critical bug: missing `return` statement (historical)

**Problem**: Earlier versions of `vllm-mlx serve` crashed on startup with any model:
```
TypeError: cannot unpack non-iterable NoneType object
```

In `vllm_mlx/utils/tokenizer.py`, the function `load_model_with_fallback()` was missing a `return` statement on the success path.

**Solution**: Fixed upstream and present in our fork. `install.sh` installs from [vitorallo/vllm-mlx@claude-code-local-patches](https://github.com/vitorallo/vllm-mlx/tree/claude-code-local-patches) which has the fix on top of a rebased `foil-patches-rebased` base, plus Gemma 4 channel-token cleanup patches for Claude Code compatibility (asymmetric `<|channel>thought...<channel|>` handling in both non-streaming and streaming paths).

### 14. Health endpoint mismatch

**Problem**: Scripts polling for server readiness grep for `"ok"` but vllm-mlx returns `"status":"healthy"`.

**Solution**: `run.sh` greps for `"healthy"`.

### 15. Model name `default` not recognized

**Problem**: Setting `ANTHROPIC_MODEL=default` causes 404. vllm-mlx requires the full HuggingFace model ID.

**Solution**: `run.sh` passes the full model ID (e.g., `mlx-community/gemma-4-e4b-it-4bit`).

### 16. First-run model download looks like a hang

**Problem**: On first use of a model, `vllm-mlx serve` downloads it from HuggingFace
(5–18GB) before the server comes up. The readiness check previously did a blind
fixed-duration poll of `/health` with no output, so a multi-GB download that
took longer than the timeout looked like a frozen/failed launch — even though
it was downloading fine.

**Solution**: `run.sh` now watches the model's HuggingFace cache directory and
prints a live progress line while it grows:

```
⬇ Downloading model 8.4GB (42.3 MB/s)
⏳ Model cached (16.0GB) — loading into memory... 12s
```

The timeout is no longer a blind wall: it only aborts if there is **no**
download progress *and* the server is not ready for a sustained period
(`STALL_LIMIT`, 240s). A slow-but-progressing download never false-times-out,
and a partial download is preserved in `~/.cache/huggingface/hub` so a restart
resumes rather than starting over. Progress is measured by cache-directory
size (robust) rather than scraping HuggingFace's tqdm bars from the log.

### 17. OOM crash under agentic load — memory preflight

**Problem**: On a 24GB machine, large models (Gemma-4-26B ~16GB, Coder ~18GB)
survive short prompts but the KV cache grows every turn as Claude Code feeds
back tool output. Once context passes ~24K tokens the KV cache + model weights
exceed the Metal memory budget and MLX throws an uncaught C++ exception:

```
libc++abi: terminating due to uncaught exception of type std::runtime_error:
[METAL] Command buffer execution failed: Insufficient Memory
(kIOGPUCommandBufferCallbackErrorOutOfMemory)
```

This kills the **entire** vllm-mlx process (not a recoverable per-request
error), and the in-progress Claude Code session is left retrying a dead
backend with `ConnectionRefused`.

**Solution**: `run.sh` runs a `memory_preflight` before starting the server.

The binding constraint is **not** total RAM — macOS only makes ~75% of RAM
GPU-addressable by default (the `iogpu.wired_limit_mb` cap). So the preflight
estimates the model footprint (real on-disk size if cached, else the catalog
estimate) against the **effective GPU budget**: the wired limit if explicitly
set, otherwise ~75% of RAM. If less than ~6GB of GPU headroom would be left
after the weights, it shows an interactive safeguard menu:

```
⚠ Tight memory  ~15GB model, GPU budget ~18GB → ~3GB for KV cache.
Safeguards:
  1) Shrink context   --max-tokens 32768 → 16384   (recommended)
  2) Raise GPU limit  iogpu.wired_limit_mb 0 → 21504  (sudo, until reboot)
  3) Both
  c) Continue as-is (risky)     q) Quit
Choose [1/2/3/c/q] (Enter = 1):
```

(This GPU-budget metric is why a ~15GB cached model with ~9GB of *free RAM*
still OOM-crashed — only ~3GB was actually GPU-usable under the default cap.)

- **Option 1** lowers the server-side context window (`--max-tokens`), which
  is the single biggest KV-cache saver.
- **Option 2** raises the Metal GPU wired-memory limit via
  `sudo sysctl iogpu.wired_limit_mb=<RAM−3GB>`. It is strictly a temporary,
  per-session bump: the original value is captured and **reverted on exit**.
  The revert uses a normal `sudo` (it will **prompt for your password** at
  shutdown if the cached credentials have expired); if you skip the prompt it
  prints the one-line command to restore manually. It is also **not**
  persisted across reboots — macOS resets it to the default on restart.
- If the GPU limit is already at/above the recommended value, option 2 is
  shown as "already fine" instead of being offered.

Models that fit comfortably (e.g. 5GB models with ~13GB+ of GPU headroom)
never trigger the prompt — they launch straight through. To **force** the
menu for any model regardless of the heuristic, use `--safe` (or
`CCLOCAL_FORCE_MEMCHECK=1`). The check is skipped entirely with
`--no-mem-check` (or `CCLOCAL_NO_MEMCHECK=1`), auto-applies the recommended
shrink in non-interactive runs, and skips silently if the model size can't be
estimated. Recovery from a crash: exit the dead Claude session, then relaunch
with a smaller model (`cclocal --gemma-light`) or with `--safe`.

### 18. Write/Edit tool call silently does nothing (no error)

**Symptom**: The model "calls" a tool to write a file — Claude Code shows the
tool invocation — then **silence**. No file written, no error. Short-argument
tools (`Bash ls`) work; large `Write`/`Edit` calls don't. You end up
copy-pasting the file content out by hand.

**Cause** — three compounding factors, all triggered by *large* tool
arguments (a `Write` serializes the **entire file body** as output tokens
inside the tool-call JSON):

1. **Output-token truncation (primary).** `gemma-4-26b` did not match the
   `CC_OUTPUT_TOKENS` override list, so it ran at the **4096** default. A
   file write blows past that; generation is cut mid-`content`, the JSON
   never closes, and no valid `tool_use` block can be built. HTTP 200, no
   error — Claude just sees text.

2. **Fork channel-filter amplifies truncation.** The custom fork's
   `_clean_gemma4_channels` (`vllm_mlx/api/utils.py`) handles a truncated
   Gemma thought block by deleting everything from an unclosed
   `<|channel>thought` to end-of-text. A tool call truncated mid-stream
   leaves exactly such an unclosed opener, so the *partial* tool call is
   **erased entirely** before the parser sees it — turning a possibly
   recoverable fragment into nothing.

3. **Fork channel-filter content collision (latent).** The same filter is a
   plain substring/regex pass over the *whole* accumulated text including
   the file body. If the file being written itself contains
   `<|channel>thought` / `<|channel>` (realistic for security-review notes,
   docs, code about LLMs), a *complete* tool call can also be destroyed.

The installed engine is confirmed to be the
[vitorallo/vllm-mlx fork](https://github.com/vitorallo/vllm-mlx/tree/claude-code-local-patches)
(not upstream — verified via the venv's `direct_url.json` and the fork-only
`_clean_gemma4_channels` patch), so this is the fork's behaviour, not a wrong
dependency.

**Mitigations (in `run.sh`)**:
- `CC_OUTPUT_TOKENS` default raised **4096 → 8192** for *all* models, with
  per-run override `--out-tokens N` (use `16384` for big files; pair with
  `--safe` if a large model then OOMs).
- `server.log` is now **rotated** to `server.log.1` instead of truncated, so
  a failed tool-call session can actually be inspected afterward.

**Not yet fixed (fork-side)**: factors 2 and 3 need a patch to
`_clean_gemma4_channels` (don't strip channel markers that fall *inside* a
tool-call span / a JSON string). Raising `--out-tokens` reduces factor 1 but
does not address content-collision. For heavy file-writing, `gemma-light` or
a coder model is currently more reliable.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| vllm-mlx crashes on startup (TypeError: NoneType) | Using unpatched upstream | `./install.sh` installs from our fork which has the fix |
| Model generates text about tools but nothing executes | Using Ollama | Switch to vllm-mlx — Ollama can't produce real tool_use blocks |
| Metal GPU OOM crash under load (`kIOGPUCommandBufferCallbackErrorOutOfMemory`) | Large model + growing agentic context exceeds RAM | Take the `memory_preflight` prompt (shrink context / raise GPU limit), or use a 5GB model — see #17 |
| First run hangs at "Waiting for server..." | Multi-GB model still downloading from HuggingFace | It's not hung — a live download progress line now shows; partial downloads resume — see #16 |
| Write/Edit tool call shows then silently does nothing (no error) | Large tool-call output truncated by the token cap (+ fork channel-filter) | `--out-tokens 16384`, or use `gemma-light`/a coder model; inspect `server.log.1` — see #18 |
| Claude Code asks about "detected custom API key" | Real API key leaking | Use `cclocal` which unsets real keys |
| "Model does not exist" (404) | Wrong model name | Must use full HuggingFace ID, not "default" |
| Slow responses (30-60s) | Normal for local inference | Context grows each turn — 24K+ tokens at ~8 tok/s |

---

## Configuration reference

### Environment variables (set by run.sh per-session)

| Variable | Value | Purpose |
|----------|-------|---------|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:8000` | Point Claude Code at local server |
| `ANTHROPIC_API_KEY` | `not-needed` | Dummy key (real key explicitly unset) |
| `ANTHROPIC_MODEL` | Full HuggingFace ID | Model identifier |
| `ANTHROPIC_DEFAULT_*_MODEL` | Same as above | Route all tiers (Opus/Sonnet/Haiku) locally |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Same as above | Route subagent calls locally |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `8192` default, `--out-tokens N` to override | Output cap; must fit a whole Write/Edit file body (see #18) |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | `0` | Prevents KV cache invalidation |
| `DISABLE_PROMPT_CACHING` | `1` | Local server doesn't support Anthropic caching |
| `DISABLE_AUTOUPDATER` | `1` | No update checks |
| `DISABLE_TELEMETRY` | `1` | No telemetry |
| `DISABLE_ERROR_REPORTING` | `1` | No error reporting |
| `DISABLE_NON_ESSENTIAL_MODEL_CALLS` | `1` | Reduce background model calls |

### vllm-mlx server flags (set by run.sh)

| Flag | Purpose |
|------|---------|
| `VLLM_MLX_ENABLE_THINKING=false` | Disable thinking/reasoning tokens |
| `--kv-cache-quantization` | 8-bit KV cache — halves cache memory usage |
| `--cache-memory-percent 0.35` | 35% of RAM for cache (~8.4GB on 24GB) |
| `--prefill-step-size 4096` | Faster time-to-first-token on large prompts |
| `--stream-interval 4` | Batch 4 tokens before streaming for throughput |
| `--timeout 600` | 10 min timeout (default 300s caused disconnects) |
| `--max-tokens` | Server context window: `32768`, or `16384` if the memory preflight shrinks it (see #17) |

### CLI flags / env (memory preflight)

| Flag / env | Purpose |
|------------|---------|
| `--safe` / `CCLOCAL_FORCE_MEMCHECK=1` | Always show the memory-safeguard menu, for any model (see #17) |
| `--no-mem-check` / `CCLOCAL_NO_MEMCHECK=1` | Skip the GPU-headroom preflight prompt (see #17) |
| `--out-tokens N` | Max output tokens Claude Code requests (default 8192; raise to 16384 for large file writes — see #18) |
| `iogpu.wired_limit_mb` | Optionally raised via `sudo sysctl` by preflight option 2; **per-session only** — reverted on exit (prompts for sudo at shutdown if creds expired), and resets on reboot |

### Claude Code flags (set by run.sh)

| Flag | Purpose |
|------|---------|
| `--strict-mcp-config` | Ignore global plugins |
| `--mcp-config mcp-local.json` | Empty config — no plugin tools |
| `--tools "Bash,Read,..."` | 8 essential built-in tools only |

---

## File structure

```
claude-code-local/
  run.sh                    # Launcher — starts vllm-mlx + Claude Code
  install.sh                # Setup — creates .venv, installs vllm-mlx, patches bugs, creates cclocal
  mcp-local.json            # Empty MCP config (strips plugins for local sessions)
  .venv/                    # Local Python venv with vllm-mlx (created by install.sh)
  .gitignore
  README.md
```

---

## Links

- [vllm-mlx](https://github.com/waybarrios/vllm-mlx) — Anthropic-compatible MLX inference server
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — Anthropic's CLI for Claude
- [Why Claude Code Fails with Local LLMs](https://explore.n1n.ai/blog/why-claude-code-fails-local-llm-inference-2026-02-19) — Detailed failure analysis
- [Claude Code tool flooding issue](https://github.com/anthropics/claude-code/issues/25857) — 259 tools sent to local models
- [Ollama Anthropic Compatibility](https://docs.ollama.com/api/anthropic-compatibility) — Confirmed broken for tool_use

---

## Citation

This project would not exist without [vllm-mlx](https://github.com/waybarrios/vllm-mlx)
by Wayner Barrios — the native Apple Silicon MLX backend that makes real
Anthropic tool-use blocks possible on local hardware. If you use vLLM-MLX in
your research or project, please cite:

```bibtex
@software{vllm_mlx2025,
  author = {Barrios, Wayner},
  title = {vLLM-MLX: Apple Silicon MLX Backend for vLLM},
  year = {2025},
  url = {https://github.com/waybarrios/vllm-mlx},
  note = {Native GPU-accelerated LLM and vision-language model inference on Apple Silicon}
}
```
