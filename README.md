# claude-code-local

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
git clone https://github.com/YOUR_USER/claude-code-local.git
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
| *(default)* | Qwen3.5-9B | ~5GB | 16GB+ | Proven working, huge context headroom |
| `--review` | GLM-4.7-Flash | ~16.9GB | 24GB+ | Stronger reasoning, single-request only |
| `--coder` | Qwen3-Coder-30B-A3B | ~17.5GB | 24GB+ | Code generation |
| `--35b` | Qwen3.5-35B-A3B | ~22GB | 32GB+ | Needs 32GB, swaps on 24GB |
| `--model ID` | Any MLX model | varies | varies | Custom HuggingFace model ID |

```bash
cclocal                # Default: Qwen3.5-9B
cclocal --review       # GLM-4.7-Flash
cclocal --coder        # Qwen3-Coder-30B-A3B
cclocal --server       # Start server only, connect Claude Code separately
cclocal --clean        # List and delete cached models
cclocal -h             # Show all options
```

### Server-only mode

```bash
cclocal --server
```

Then connect Claude Code from any terminal:

```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:8000 \
ANTHROPIC_API_KEY=not-needed \
ANTHROPIC_MODEL=mlx-community/Qwen3.5-9B-MLX-4bit \
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

**Problem**: Qwen 3.x models emit `<think>...</think>` blocks. Claude Code doesn't expect these — causes garbage output and misparses tool calls.

**Solution**: MLX 4-bit quantized models default to thinking off.

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

**Solution**: Run in single-request mode (no `--continuous-batching`). Requests serialize instead of competing for Metal memory.

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
| **Qwen3.5-9B** | **~5GB** | **~19GB** | **Working — full tool loop** |
| GLM-4.7-Flash | ~16.9GB | ~7GB | Works single-request only |
| Qwen3.5-35B-A3B | ~22GB | ~2GB | Swaps to death |

### 13. vllm-mlx critical bug: missing `return` statement

**Problem**: `vllm-mlx serve` crashes on startup with any model:
```
TypeError: cannot unpack non-iterable NoneType object
```

In `vllm_mlx/utils/tokenizer.py`, the function `load_model_with_fallback()` is missing a `return` statement on the success path.

**Solution**: `install.sh` automatically detects and patches this bug. If the upstream fix has been merged, the patch is skipped. See [vllm-mlx-bug-report.md](vllm-mlx-bug-report.md) for details.

### 14. Health endpoint mismatch

**Problem**: Scripts polling for server readiness grep for `"ok"` but vllm-mlx returns `"status":"healthy"`.

**Solution**: `run.sh` greps for `"healthy"`.

### 15. Model name `default` not recognized

**Problem**: Setting `ANTHROPIC_MODEL=default` causes 404. vllm-mlx requires the full HuggingFace model ID.

**Solution**: `run.sh` passes the full model ID (e.g., `mlx-community/Qwen3.5-9B-MLX-4bit`).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| vllm-mlx crashes on startup (TypeError: NoneType) | Missing return bug | Run `./install.sh` to auto-patch, or see [#13](#13-vllm-mlx-critical-bug-missing-return-statement) |
| Model generates text about tools but nothing executes | Using Ollama | Switch to vllm-mlx — Ollama can't produce real tool_use blocks |
| Metal GPU OOM | Model too large for concurrent requests | Use default model (9B) or accept single-request mode |
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
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `16384` (9B) / `4096` (large) | Output limit per model size |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | `0` | Prevents KV cache invalidation |
| `DISABLE_PROMPT_CACHING` | `1` | Local server doesn't support Anthropic caching |
| `DISABLE_AUTOUPDATER` | `1` | No update checks |
| `DISABLE_TELEMETRY` | `1` | No telemetry |
| `DISABLE_ERROR_REPORTING` | `1` | No error reporting |
| `DISABLE_NON_ESSENTIAL_MODEL_CALLS` | `1` | Reduce background model calls |

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
  install.sh                # Setup — installs vllm-mlx, patches bugs, creates cclocal command
  mcp-local.json            # Empty MCP config (strips plugins for local sessions)
  vllm-mlx-bug-report.md    # Upstream bug report for the missing return fix
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
