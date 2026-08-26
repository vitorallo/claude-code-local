# Claude-Code-Local

**The only setup that actually works.** Run Claude Code with local LLMs on Apple Silicon — real tool execution, real agentic loops, fully offline.

Every tutorial out there tells you to point Claude Code at Ollama or llama.cpp and call it a day. None of them work. The model generates text that *looks like* a tool call, but nothing executes. No files get created, no commands run, no code gets written. You're watching a convincing hallucination.

This project uses [vllm-mlx](https://github.com/waybarrios/vllm-mlx) — the only backend that speaks Claude Code's native language: the Anthropic Messages API with real `tool_use` content blocks. When the model decides to read a file, it actually reads the file. When it writes code, the code lands on disk. The agentic loop works — tool calls chain into tool results, the model iterates, and you get the real Claude Code experience running entirely on your hardware.

No API key. No cloud. No subscription. No data leaves your machine. Just `./install.sh` and go.

## What you need

- Apple Silicon Mac (M1/M2/M3/M4/M5)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed
- [Homebrew](https://brew.sh)
- Unified memory, which decides which models you can run:

| Memory | What you can run |
|--------|------------------|
| 16GB | The light models (`--gemma-light`, ~5GB). Fast, decent tool calling. |
| 24GB | **`--deckard`** (~6GB) is the best balance of speed and correctness. `--gemma` (26B MoE) if you want a bigger model. `--qwen38` is the most capable but OOMs in real sessions here — see [#26](#26-qwen38-on-24gb-the-honest-verdict). |
| 32GB+ | Qwen3.8-27B with real headroom for long agentic sessions. |

Disk: models are cached under `~/.cache/huggingface`. Budget ~16GB for
Qwen3.8, ~5GB for a light model.

## Quick start

```bash
git clone https://github.com/vitorallo/claude-code-local.git
cd claude-code-local
./install.sh
cclocal                # interactive menu — pick a model
```

Or skip the menu and go straight to a model:

```bash
cclocal --gemma-light    # ~5GB, fast, works on 16GB           (default)
cclocal --qwen38         # ~16GB, best quality, needs 24GB      (see below)
```

First run downloads the model (one-time). `install.sh` also symlinks `cclocal`
into `~/.local/bin`, so make sure that's on your `PATH`.

### Verify it works

In Claude Code, type:

```
create a file called /tmp/test_tools.txt with "hello world"
```

**Working**: Claude Code calls the Write tool, creates the file, confirms.
**Broken**: Claude Code generates text saying it created the file, but nothing exists on disk.

That second outcome is what every other local-LLM tutorial produces. If you
see it here, something is misconfigured — check [Troubleshooting](#troubleshooting).

### Upgrading an existing install

If you installed before August 2026, your venv is pinned to
`mlx==0.31.1` / `mlx-lm==0.31.1` and **cannot load Qwen3.8**. Re-run the
installer to move to the vllm-mlx 0.4.1 branch:

```bash
cd claude-code-local
git pull
./install.sh              # force-reinstalls the venv onto the new branch
```

Nothing else needs changing — your existing model cache is reused. See
[#13](#13-vllm-mlx-critical-bug-missing-return-statement-historical) for why
the pins existed and why they are gone.

#### What a finished install looks like

`install.sh` has three steps. The MLX version line is the **end of step
[2/3]**, not the end of the script — it's a long `uv` package listing followed
by a short summary, so it's easy to mistake for the finish:

```
  vllm-mlx installed: /Users/you/src/claude-code-local/.venv/bin/vllm-mlx
  mlx: 0.32.2  |  mlx-lm: 0.31.3  |  mlx-vlm: 0.6.16

[3/3] Creating cclocal command...
  Symlinked: ~/.local/bin/cclocal -> /Users/you/src/claude-code-local/run.sh

=== Setup Complete ===
```

If you don't see `=== Setup Complete ===`, the install stopped early.

#### Verifying the upgrade took

Three things should be true afterwards:

```bash
# 1. The MLX stack is unpinned — anything below these cannot load Qwen3.8
.venv/bin/python -c "import mlx.core, mlx_lm, mlx_vlm; \
  print(mlx.core.__version__, mlx_lm.__version__, mlx_vlm.__version__)"
# expect >= 0.32.x  0.31.3  0.6.x

# 2. You're on the 0.4.1 branch, not the old pinned one
.venv/bin/python -c "from importlib.metadata import distribution; import json; \
  print(json.loads(distribution('vllm-mlx').read_text('direct_url.json'))\
  ['vcs_info']['requested_revision'])"
# expect feat/claude-code-local-0.4.1

# 3. cclocal is wired up
command -v cclocal
```

If step 3 prints nothing, `~/.local/bin` isn't on your `PATH` — `install.sh`
says so when that happens, and `./run.sh` works regardless.

## Models

| Flag | Model | Size | RAM needed | Notes |
|------|-------|------|-----------|-------|
| `--qwen38` | Qwen3.8-27B | ~16GB | 24GB | **Best quality.** XML tool calls — no JSON escaping [0] |
| `--deckard` | Qwen3.5-9B-Deckard-Agent | ~6GB | 16GB+ | **Best all-rounder here.** Agent-tuned, fast, writes real files [4] |
| *(default)* `--gemma-light` | Gemma-4-E4B | ~5GB | 16GB+ | Clean tool calling, verified end-to-end |
| `--gemma` | Gemma-4-26B-A4B MoE | ~14GB | 24GB | **Best fit for 24GB.** MoE, 3.8B active — 14GB class but prefills fast enough to skip the cache entirely [3] |
| `--coder` | Qwen3-Coder-30B-A3B | ~18GB | **32GB+** | Heavier code model — **untested here** [5] |
| `--qwen3` | Qwen3.5-9B (stock) | ~5GB | 16GB+ | Base model behind `--deckard`. **Now working** — the old thinking leak is gone [1] |
| `--light` | *(alias)* | | | Back-compat alias for `--gemma-light` (v2.0.1 pointed at Qwen3.5-9B) |
| `--model ID` | Any MLX model | varies | varies | Custom HuggingFace model ID (not tested) |

[5] `--coder` has never been downloaded or run on this machine. At 18GB it is
larger than `--qwen38`, which *is* documented as hitting a Metal OOM in real
sessions on 24GB ([#26](#26-qwen38-on-24gb-the-honest-verdict)) — so on a 24GB
Mac expect it to fail the same way. It may well be fine on 32GB+, and being a
~3B-active MoE it could behave like `--gemma`, which prefills fast enough to
sidestep the prefix-cache doubling that kills dense Qwen3.8. Untested either
way; treat the row as a starting point, not a recommendation.

**Removed:** `--coder7b` (Qwen2.5-Coder-7B) and `--review` (GLM-4.7-Flash).
The first has unreliable tool calls [2], and a model that can't call tools
can't drive Claude Code. The second was never downloaded or tested here, and at
17GB it is larger than the model already documented as OOMing on 24GB — a
listed option that could not work on the hardware this project targets. Both
remain reachable via `--model <id>`:

```bash
cclocal --model mlx-community/GLM-4.7-Flash-4bit              # ex --review
cclocal --model mlx-community/Qwen2.5-Coder-7B-Instruct-4bit  # ex --coder7b
```

Note that `--model` gets `auto` tool parsing and no reasoning parser, so a
model needing a specific parser (GLM has `glm47`/`glm4`) will underperform
compared with a proper catalog entry.

[0] Qwen3.8's chat template emits tool calls as XML with raw-text parameters —
`<tool_call><function=Write><parameter=content>...raw bytes...</parameter></function></tool_call>`
— so the model never has to escape quotes inside a file body. That removes the
failure mode in [#18](#18-writeedit-tool-call-silently-does-nothing-no-error)
that no server patch could fix. Parsed by `--tool-call-parser qwen3_xml`.
Thinking is **off by default** (see `--think`); Qwen3.8 defaults to
`reasoning_effort=xhigh` and will otherwise spend minutes deliberating before
its first tool call. Measured ~7.5 tok/s on an M5 24GB at 4-bit.

[3] Measured on an M5/24GB: 3.3s short reply, 5.3s tool call, and 12.7s/turn
against a 13k-token system prompt with no OOM and no prefix cache needed —
the case where the same-sized dense Qwen3.8 hits a Metal OOM. Tool calls
verified: `stop_reason: tool_use`, valid JSON arguments, no channel-token
leakage. See [#26](#26-qwen38-on-24gb-the-honest-verdict) for the full
comparison.

[4] `nightmedia/Qwen3.5-9B-Claude-GBO-Fire-Deckard-Agent-Heretic-dwq4-mlx`, a
4-bit DWQ agent fine-tune of Qwen3.5-9B. Measured on an M5/24GB: **0.73s** for
a short reply, 13s for a full file write, 5.2GB on disk, 8s cold start. It
passes the file-writing test that rejected two other candidates — 4/4
`tool_use`, zero markdown blocks, and the generated module **compiles and
runs**. Multi-turn tool chaining works (consumes a `tool_result`, calls the
next tool). Notably it does **not** exhibit the plain-text thinking leak of
stock Qwen3.5-9B in [1] — the fine-tune fixed it. Uses `qwen3_xml` (same XML
tool format as Qwen3.8, so the same no-escaping benefit as [0]).

[1] **This entry used to warn that Qwen3.5 leaks plain-text "Thinking Process:"
preamble outside `<think>` tags** (see
[vllm-project/vllm#35574](https://github.com/vllm-project/vllm/issues/35574),
[QwenLM/Qwen3#1625](https://github.com/QwenLM/Qwen3/issues/1625)). That finding
predated this branch's configuration work and no longer reproduces. Re-measured
on `mlx-community/Qwen3.5-9B-MLX-4bit` with the current settings — `qwen3_xml`
tool parser, `enable_thinking=false` via `--default-chat-template-kwargs`, the
`qwen3` reasoning parser as a backstop, and the EOS reconciliation from
[#31](#31-every-tool-request-returns-http-500-union-types-in-tool-schemas):

| | Result |
|---|---|
| Thinking leak | **none** (2/2 prompts clean) |
| Riddle | answered correctly |
| `Write` a quote-dense module | `tool_use`, no markdown block, **file compiles** |
| Speed | 10.6s for the file write |

So the leak was a configuration problem, not a model defect. `--deckard` is
still the better checkpoint of the two, but stock `--qwen3` is now a working
option rather than a warning.

[2] Qwen2.5-Coder-7B hallucinates an XML tool-call format
(`<Write path="..." content="..."/>`) that no parser handles. Good for
non-agentic code analysis where you feed it whole files, not for Claude
Code's tool loop. Use `--gemma-light` for tool calling work instead.

---

## Running Qwen3.8-27B

The best local Claude Code experience currently available on a Mac, and the
first model here that doesn't lose large file writes. This section is the
complete recipe.

### 1. Pick a quant

Qwen3.8-27B ships in one useful size (27B dense) at several precisions. On a
24GB Mac only two are realistic:

| Flag | HF model | On disk | Best for |
|------|----------|---------|----------|
| `--qwen38` | `mlx-community/Qwen3.8-27B-4bit` | 16.05 GB | Everything. This is the one. |

There is only one usable quant. 8-bit and above don't fit 24GB, and **the
3-bit community quant is broken** — see [#24](#24-the-3-bit-quant-is-broken-dont-use-it).
If you're on 16GB, none of them fit — stay on `--gemma-light`.

> **Verification status.** `--qwen38` is verified end-to-end on an M5 24GB:
> load, streaming and non-streaming `/v1/messages`, tool calls, large
> quote-dense `Write`, truncation handling, `--think`, and a 13k-token system
> prompt cached and replayed. MTP speculative decoding is **not** enabled:
> upstream [#471](https://github.com/waybarrios/vllm-mlx/issues/471) reports
> `--enable-mtp` silently doing nothing on this code path, so it needs
> measuring before it's worth a flag.

### 2. Understand the memory budget (24GB Macs)

This is the part that bites people. macOS does **not** make all your RAM
available to the GPU. The cap is `iogpu.wired_limit_mb`, which defaults to
about 75% of physical RAM — **~19GB on a 24GB machine**, not 24GB. Check it:

```bash
sysctl iogpu.wired_limit_mb          # 0 means "default" (~75% of RAM)
```

Against that ~19GB you're spending:

- **16.05 GB** of weights, plus
- the **KV cache**, which grows every turn of an agentic session.

Qwen3.8-27B is 64 layers of hybrid attention — `layer_types` alternates
`linear_attention` with `full_attention` every 4th layer, so only **16 layers
hold a KV cache**. At `num_key_value_heads: 4` × `head_dim: 256` × 2 (K+V) ×
2 bytes that's **64 KB/token**, halved to 32 KB/token by
`--kv-cache-quantization`, which `cclocal` always passes:

| Context window (`--max-kv-size`) | KV cache (8-bit) | Weights + cache |
|----------------------------------|------------------|-----------------|
| 16K (after preflight shrink) | ~0.5 GB | ~16.6 GB |
| **32K (`--qwen38` default)** | **~1.0 GB** | **~17.1 GB** |
| 64K | ~2.1 GB | ~18.2 GB |
| 262K (model's native max) | ~8.4 GB | ~24.5 GB — doesn't fit |

So 4-bit at a 32K window fits under ~19GB — barely, with everything else on
your Mac competing for the same pool. `cclocal` detects this and offers two
safeguards before it starts:

```
  ⚠ Tight memory  ~14GB model, GPU budget ~18GB → ~3GB for KV cache.

  Safeguards:
    1) Shrink budgets   --max-tokens 32768 → 16384, --max-kv-size 32768 → 16384
    2) Raise GPU limit  iogpu.wired_limit_mb 0 → 21504  (sudo, until reboot)
    3) Both
```

**For `--qwen38`, take option 2 or 3.** Raising the limit to 21504 MB leaves
real headroom for the cache. It's session-scoped: `run.sh` reverts it on exit,
and it resets on reboot anyway. To set it yourself:

```bash
sudo sysctl iogpu.wired_limit_mb=21504     # 24GB Mac; leaves ~3GB for macOS
sudo sysctl iogpu.wired_limit_mb=0         # back to default
```

Don't push it much past `total_RAM - 3GB`. Starving macOS trades a Metal OOM
for a system-wide stall.

With the cache budget sized correctly (see [#23](#23-everything-works-but-is-unusably-slow-cache-budget-vs-weights)),
4-bit fits under the default limit — the bump buys headroom, not correctness.

### 3. Context window and token budgets

Four different numbers get called "context" and they are not the same thing.
Getting them confused is the single most common way to mis-tune this setup:

| Setting | What it actually limits | Value here |
|---------|------------------------|------------|
| `--max-kv-size` | **The context window.** KV cache bound per sequence. Past it, `RotatingKVCache` evicts the oldest tokens. | `32768` |
| `--max-tokens` | Longest **single generation** when the client doesn't specify one. Peak memory during one reply — not the window. | `32768`, halved to `16384` by the memory preflight |
| `--max-request-tokens` | Ceiling on the `max_tokens` a client is allowed to ask for. | engine default `32768`; `run.sh` doesn't set it |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | What **Claude Code** requests per reply. This is what truncates a large `Write`. | `8192`, raise with `--out-tokens` |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | The window **Claude Code believes it has**, and therefore when auto-compact fires. | 85% of `--max-kv-size`, for compaction headroom |

Two consequences worth internalising:

**The model's 262K native context is not what you get.** Qwen3.8-27B supports
262,144 tokens, but at 32 KB/token of quantized KV that would need ~8GB of
cache — on top of 16GB of weights, against a ~19GB budget. `--max-kv-size` is
what keeps that bounded. The window you actually run is 32K (or 16K after the
preflight shrink), not 262K.

**Once a session exceeds the window, early context is silently evicted.**
`RotatingKVCache` drops the oldest tokens to stay within the bound — the
session keeps working, but the model stops being able to see the start of the
conversation. If a long agentic session starts forgetting what it was doing,
that's this, not a bug. Either raise `--max-kv-size` (and the GPU limit to pay
for it), or start a fresh session.

**This is why `run.sh` sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS`.** Claude Code
doesn't recognise these model IDs, so it warns and falls back to assuming a
200k window:

```
"mlx-community/Qwen3.8-27B-4bit" is not a model this version of Claude Code
recognizes, so auto-compact will keep this session within 200k tokens
```

Left alone that assumption is actively harmful, not cosmetic: Claude Code
would let the session grow roughly 6× past the real 32K window before
compacting, while the server quietly evicted the beginning of the
conversation. The symptom is a model that seems to get stupider as the session
goes on. `run.sh` pins the variable to the window actually being served, so
auto-compact fires before eviction does. The warning itself still prints —
it's emitted before the variable is consulted — and can be ignored.

In remote mode `run.sh` leaves the variable unset, since the remote box's
window is unknown and probably larger.

If you want a bigger window, the arithmetic is: **32 KB per token** with
`--kv-cache-quantization`, 64 KB without. 64K tokens is ~2.1GB of cache, 128K
is ~4.2GB. Raise `iogpu.wired_limit_mb` accordingly to pay for it.

### 4. Run it

```bash
cclocal --qwen38
```

First run downloads ~16GB from HuggingFace — a live progress line shows size
and rate, and partial downloads resume. Subsequent starts load from cache in
about 20 seconds.

That's the whole workflow. Claude Code launches pointed at the local server,
with the tool set scoped and pre-approved so you're not stopped by permission
prompts on every action.

Two things to expect on that first run, both easy to misread:

**At the memory prompt, take option 2 or 3 — not option 1.** On a 24GB Mac the
GPU-limit bump is the one that actually helps. Option 1 shrinks the token
budgets, which trades away context you need; it now floors the window at 32K
so it can't make things worse, but it isn't the lever you want here.

**Claude Code will warn that it doesn't recognise the model.** You'll see:

```
"mlx-community/Qwen3.8-27B-4bit" is not a model this version of Claude Code
recognizes, so auto-compact will keep this session within 200k tokens
(the context window it assumes). If the model accepts more, append [1m] to
the model name for 1M, or set CLAUDE_CODE_MAX_CONTEXT_TOKENS to its real
window; ...
```

**Ignore it — the advice has already been applied.** `run.sh` sets
`CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the real window before launching; Claude
Code just emits this warning before it reads the variable. Don't follow the
`[1m]` suggestion — that would claim a 1M window you are nowhere near serving,
which is the opposite of what you want. See
[#20](#20-claude-code-assumes-a-200k-context-window).

**If something does go wrong, read `server.log` first.** Claude Code surfaces
backend failures as a generic "API error" with no detail; the actual cause —
a template exception, an OOM, a truncated tool call — is in `server.log`, and
the previous run is kept as `server.log.1`:

```bash
tail -40 server.log
```

### 5. Know what to expect

Set expectations before you judge it:

- **~7.5 tokens/sec** for 4-bit on an M5 with 24GB. A single large `Write`
  tool call takes 60–75 seconds. This is normal, not a hang.
- **Thinking is off by default**, and should stay off — see
  [#3](#3-reasoningthinking-tokens-garbage-output). Qwen3.8 defaults to
  `reasoning_effort=xhigh`, which turns a trivial request into minutes of
  silent deliberation at these token rates.
- Turn it back on **only** for genuinely hard reasoning, with `--think`:

  ```bash
  cclocal --qwen38 --think     # reasoning_effort=low, thinking blocks rendered properly
  ```

  Reasoning then arrives as structured Anthropic `thinking` blocks, not leaked
  into the text stream.
- **Large file writes work now.** Qwen3.8 emits XML tool calls with raw-text
  parameters, so a quote-dense file body never has to survive JSON escaping —
  the failure that silently dropped `Write` calls with earlier models. See
  [#18](#18-writeedit-tool-call-silently-does-nothing-no-error).
- The output-token cap still applies. For very large files raise it:

  ```bash
  cclocal --qwen38 --out-tokens 16384
  ```

### 6. Doing it manually (without `cclocal`)

If you want to drive the server yourself, these are the exact flags `run.sh`
uses. Start the server:

```bash
.venv/bin/vllm-mlx serve mlx-community/Qwen3.8-27B-4bit \
  --port 8000 \
  --max-tokens 16384 \
  --kv-cache-quantization \
  --cache-memory-percent 0.35 \
  --prefill-step-size 4096 \
  --stream-interval 4 \
  --timeout 600 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_xml \
  --tool-call-truncation-notice \
  --default-chat-template-kwargs '{"enable_thinking": false, "preserve_thinking": false}' \
  --default-temperature 0.7 --default-top-p 0.80 --default-top-k 20 \
  --default-presence-penalty 1.5 \
  --max-kv-size 32768
```

The two flags that matter most and are easy to get wrong:

- **`--tool-call-parser qwen3_xml`** — Qwen3.8 emits
  `<tool_call><function=..><parameter=..>` XML, not JSON. `auto` may sniff it,
  but naming it is what makes tool calling reliable. (`qwen3_coder` and
  `qwen3.5` are aliases for the same parser.)
- **`--default-chat-template-kwargs`** — the only working way to turn thinking
  off. Note `preserve_thinking: false` too: Qwen3.8 defaults it to *true*,
  which re-injects every previous turn's reasoning on every agentic turn.

Then point Claude Code at it:

```bash
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  ANTHROPIC_BASE_URL=http://127.0.0.1:8000 \
  ANTHROPIC_API_KEY=not-needed \
  ANTHROPIC_MODEL=mlx-community/Qwen3.8-27B-4bit \
  ANTHROPIC_DEFAULT_OPUS_MODEL=mlx-community/Qwen3.8-27B-4bit \
  ANTHROPIC_DEFAULT_SONNET_MODEL=mlx-community/Qwen3.8-27B-4bit \
  ANTHROPIC_DEFAULT_HAIKU_MODEL=mlx-community/Qwen3.8-27B-4bit \
  CLAUDE_CODE_SUBAGENT_MODEL=mlx-community/Qwen3.8-27B-4bit \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192 \
  CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
  DISABLE_PROMPT_CACHING=1 DISABLE_AUTOUPDATER=1 DISABLE_TELEMETRY=1 \
  DISABLE_ERROR_REPORTING=1 DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
  claude --strict-mcp-config --mcp-config mcp-local.json \
    --tools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch" \
    --allowedTools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
```

All four `ANTHROPIC_*_MODEL` variables must be set — Claude Code routes
different work to different tiers, and an unset tier 404s against a
single-model server. Every one of these is explained in
[Why this is hard](#why-this-is-hard-and-how-we-solved-it);
`cclocal --qwen38 --server` prints this same block for you.

### 7. Check it end-to-end

With the server up, confirm real `tool_use` blocks come back — this is the
thing that separates a working setup from a convincing hallucination:

```bash
curl -s http://127.0.0.1:8000/v1/messages -H 'content-type: application/json' -d '{
  "model": "mlx-community/Qwen3.8-27B-4bit",
  "max_tokens": 500,
  "tools": [{"name": "Write", "description": "Write a file",
    "input_schema": {"type": "object",
      "properties": {"file_path": {"type": "string"}, "content": {"type": "string"}},
      "required": ["file_path", "content"]}}],
  "messages": [{"role": "user",
    "content": "Use the Write tool to create /tmp/ok.py containing print(\"hi\")"}]
}' | python3 -m json.tool
```

You want `"type": "tool_use"` in `content` and `"stop_reason": "tool_use"`.
If you get a `text` block describing a tool call instead, tool calling is not
working — check that `--tool-call-parser` is set.

---

## Usage

```bash
cclocal                # Interactive menu: pick model, see what's cached, manage cache
cclocal --qwen38       # Direct launch, Qwen3.8-27B (best quality, 24GB)
cclocal --gemma-light  # Direct launch, Gemma-4-E4B (light default, clean tool calling)
cclocal --gemma        # Direct launch, Gemma-4-26B MoE
cclocal --review       # Direct launch, GLM-4.7-Flash
cclocal --coder        # Direct launch, Qwen3-Coder-30B-A3B
cclocal --list         # List cached models on disk
cclocal --rm           # Manage/delete cached models (interactive)
cclocal --server       # Start server only, connect Claude Code separately
cclocal -h             # Show all options

# Operational flags (combine with any model flag)
cclocal --qwen38 --out-tokens 16384  # Bigger output budget for large file writes (default 8192)
cclocal --qwen38 --safe              # Force the memory-safeguard menu (raise GPU limit / shrink ctx)
cclocal --qwen38 --no-mem-check      # Skip the GPU-headroom preflight prompt
cclocal --qwen38 --think             # Enable brief reasoning (reasoning_effort=low)

# Remote backend — run the model on another box, not this Mac
cclocal --lmstudio                   # LM Studio's server on this Mac (needs 0.4.1+)
cclocal --dgx-active                 # DGX Spark preset (MoE, faster)
cclocal --dgx-idle                   # DGX Spark preset (dense, steadier)
cclocal --remote http://host:8000    # Any remote vLLM endpoint (model auto-detected)
```

Running `cclocal` with no arguments opens an interactive menu that shows every
supported model, indicates which are already cached on disk, and lets you pick
one or jump to a cache management screen. Use the model flags to skip the menu
when you already know what you want.

### What `cclocal` now handles for you (automatic)

You don't configure these; `run.sh` applies them. Listed here so the behaviour
isn't a surprise. Full root-cause writeups in [Why this is hard](#why-this-is-hard-and-how-we-solved-it)
(#16–#18) and the [field report](docs/running-claude-code-on-local-llms.md).

- **Memory preflight.** Before serving, it estimates the model footprint vs.
  the *GPU budget* (the `iogpu.wired_limit_mb` cap, or ~75% of RAM — not total
  RAM). If headroom is tight it offers to shrink the server context and/or
  raise the GPU wired limit via `sudo` for the session (auto-reverted on exit,
  never persisted across reboot). Silent when there's ample headroom; `--safe`
  forces the menu, `--no-mem-check` skips it. See #17.
- **Output budget.** `CLAUDE_CODE_MAX_OUTPUT_TOKENS` defaults to 8192 (raised
  from a too-small value that silently truncated file writes); override with
  `--out-tokens N`. See #18.
- **No classifier stall.** The 8 built-in tools are pre-allowed
  (`--allowedTools`), so auto mode never makes the slow per-action
  safety-classifier model call that a serialized local model can't answer in
  time. Tool set stays scoped; nothing outside it is auto-approved.
- **Write-in-parts hint.** A system-prompt line tells the model to build
  large files incrementally, pre-empting the truncation cycle.
- **Fail-loud truncation notice.** The fork is run with
  `--tool-call-truncation-notice`: a tool call still truncated by the cap
  returns an explicit "write it in smaller parts" message instead of silent
  text. See #18.
- **Diagnosable logs.** `server.log` is rotated to `server.log.1` on each
  launch instead of truncated, so a failed session can be inspected.
- **Pinned ML runtime.** `install.sh` pulls a fork branch that pins
  `mlx==0.31.1` / `mlx-lm==0.31.1` (newer versions crash generation from a
  worker thread). See #18.

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

### Remote backend (DGX Spark or any vLLM box)

vllm-mlx is the answer for running **locally on Apple Silicon** — but the model
doesn't have to live on this Mac. You can point Claude Code at a **remote** box
running plain **vLLM** (e.g. an NVIDIA DGX Spark on your Tailnet). Recent vLLM
ships a complete native **Anthropic Messages API** — `/v1/messages` with real
`tool_use` blocks, Anthropic SSE streaming, and `count_tokens` — so the exact
same wiring works. `run.sh` just skips the whole local-server lifecycle (no
menu, no `.venv` check, no memory preflight, no download/serve) and points
`ANTHROPIC_BASE_URL` at the remote.

```bash
cclocal --dgx-active                      # preset: MoE box (faster)
cclocal --dgx-idle                        # preset: dense box (steadier reasoning)
cclocal --remote http://host:8000         # any remote vLLM endpoint
cclocal --remote http://host:8000 --remote-model Qwen/Qwen3.6-35B-A3B   # override model
```

- **Auto-detect.** With no `--remote-model`, the launcher reads the model id
  from the remote's `/v1/models` and uses it automatically.
- **Presets.** `--dgx-active` / `--dgx-idle` are convenience aliases — edit the
  `DGX_ACTIVE` / `DGX_IDLE` addresses near the top of `run.sh` to match your own
  boxes.
- **Nothing local runs.** vllm-mlx isn't required in remote mode (only the
  `claude` CLI). The remote box's own batching handles concurrency, so the
  single-request OOM safeguards (#7, #17) don't apply.
- **Reachability.** If the endpoint can't be reached you get a clear error
  instead of a hang — with a Tailscale hint for remote boxes, or an
  `lms server start` hint for `--lmstudio`.
- **`--lmstudio`** points the same plumbing at LM Studio on this Mac
  (`http://127.0.0.1:1234`). LM Studio 0.4.1+ serves a native Anthropic
  `/v1/messages` endpoint with SSE and function calling, so mechanically it
  works like a remote vLLM box — no vllm-mlx involved. Start it with
  `lms server start`.

  > **Currently blocked with Claude Code.** LM Studio's `/v1/messages` schema
  > rejects the request Claude Code sends:
  >
  > ```
  > request.messages.1.role: Invalid discriminator value. Expected 'user' | 'assistant'
  > ```
  >
  > This is the same root cause as [#19](#19-system-message-must-be-at-the-beginning-opaque-http-500) —
  > Claude Code puts a `system` message inside `messages[]` rather than only in
  > the top-level `system` field. Our fork hoists it; LM Studio validates
  > strictly and refuses. Reproducible with no model loaded, so it is schema
  > validation, not inference, and nothing in this repo can fix it.
  >
  > **It does not fail every time.** Claude Code only sends that shape in some
  > turns, so `--lmstudio` sessions can run fine and then break mid-conversation.
  > Treat it as usable but liable to stop without warning, rather than broken
  > outright.
  >
  > LM Studio does route Gemma's thought channel into proper `thinking` blocks,
  > which Claude Code renders nicely. That is the same behaviour `--gemma-light`
  > and `--gemma` now have locally via the `gemma4` reasoning parser — see
  > [#27](#27-gemma-narrates-instead-of-acting-and-the-loop-stalls). Before that
  > fix, the local path leaked the channel as assistant text; LM Studio getting
  > it right was the clue that it was ours to fix, not an inherent limitation.

> **Reasoning models emit `thinking`.** Qwen3-class models return `thinking`
> blocks; recent vLLM wraps them as *structured* Anthropic `thinking` content
> (not the raw `<think>` text leak of #3), so Claude Code renders them fine — it
> only costs latency/tokens. The local `VLLM_MLX_ENABLE_THINKING=false` only
> affects the local server; it can't reach the remote. On the `/v1/messages`
> endpoint Claude Code uses, no request parameter disables thinking
> (`thinking:{type:disabled}`, `reasoning_effort`, `chat_template_kwargs` are all
> ignored there) — disable it **server-side on the remote box** if you need to.

---

## Why this is hard (and how we solved it)

Running Claude Code with a local model isn't just "point it at localhost". There are 31 problems that break the experience. This section documents every one and how `run.sh` handles it.

> 📄 For a consolidated field report — every problem tackled, root causes, the fixes/improvements, the honest model-capability limits, and how it scales to larger hardware — see [`docs/running-claude-code-on-local-llms.md`](docs/running-claude-code-on-local-llms.md).

### 1. Ollama can't produce real tool calls

**Problem**: Ollama's Anthropic API adapter generates text that *looks like* tool calls but never emits real `tool_use` content blocks. Claude Code receives plain text, never executes anything. Tested with qwen3.5:9b, qwen3.5:35b-a3b, glm-4.7-flash — all produce fake tool calls.

**Solution**: Use vllm-mlx. It implements the native Anthropic Messages API with real `tool_use` / `tool_result` content blocks.

### 2. `end_turn` vs `stop` (the loop killer)

**Problem**: Claude Code needs `stop_reason: "end_turn"` to know the model finished. Backends returning `"stop"` (OpenAI convention) cause Claude Code to stop looping after the first response — no tool calls, no iteration.

**Solution**: vllm-mlx's native `/v1/messages` endpoint returns correct Anthropic stop reasons.

### 3. Reasoning/thinking tokens (garbage output)

**Problem**: Qwen 3.x and Gemma 4 models emit thinking/reasoning tokens. Claude Code doesn't expect these — causes garbage output and misparses tool calls.

**Solution**: `run.sh` passes `--default-chat-template-kwargs '{"enable_thinking": false, "preserve_thinking": false}'` (and keeps `VLLM_MLX_ENABLE_THINKING=false` as a belt-and-braces fallback). `enable_thinking=false` makes the template emit an empty `<think></think>` so the model skips reasoning outright.

`preserve_thinking=false` matters more than it looks. Qwen3.8 defaults it to
**true**, which re-injects every prior turn's reasoning on every subsequent
turn — in an agentic loop that compounds until the history truncates.

Qwen3.8 also defaults to `reasoning_effort=xhigh`, which turns a trivial task
into minutes of silent deliberation at local token rates. Its template accepts
only `xhigh` / `medium` / `low` (`none` raises), so "no thinking" has to go
through `enable_thinking`.

**`--think`** opts back in at `reasoning_effort=low` and adds
`--reasoning-parser qwen3`, so `<think>` content becomes a structured Anthropic
`thinking` block rather than leaking into the text stream. Claude Code renders
those blocks properly — collapsed reasoning above the answer — so where a model
tags its thinking reliably, `--think` is genuinely pleasant to use.

**But a reasoning parser can only catch *tagged* thinking.** Measured per model:

| Model | `--think` behaviour |
|---|---|
| `--qwen38` | Reliable. Clean `thinking` block, answer separate, riddle answered correctly. |
| `--deckard` | **2 of 3.** Two prompts produced proper blocks; a riddle emitted 1250 characters of raw reasoning as a *single text block* — untagged, so nothing can route it. Inherited from stock Qwen3.5 (see [1]); the fine-tune reduced it but did not remove it. |
| `--gemma*` | Always on regardless (Gemma ignores `enable_thinking=false`), and always parsed into proper `thinking` blocks — see [#27](#27-gemma-narrates-instead-of-acting-and-the-loop-stalls). This is the configuration that renders best in Claude Code: reasoning collapsed above the answer, nothing leaked. `--think` is a no-op for these models. |

With thinking **off** — the default — `--deckard` is clean: 0 leaks across every
prompt tried. That is why it stays off rather than being made the default for
the nicer rendering. Sampling parameters
switch with it: Qwen publishes different recommendations per mode
(non-thinking `temp 0.7 / top_p 0.80 / presence_penalty 1.5`, thinking
`temp 1.0 / top_p 0.95`), and the model's own `generation_config` ships the
*thinking* values — so the non-thinking defaults have to be set explicitly.

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

On a 24GB Mac the GPU budget (`iogpu.wired_limit_mb`, default ~75% of RAM) is
**~19GB**, not 24 — that is the real ceiling, and "free RAM" overstates it.

Qwen3.8-27B is 64 layers of hybrid attention: `layer_types` alternates
`linear_attention` with `full_attention` every 4th layer, so only **16 layers
hold a KV cache**. At `num_key_value_heads: 4` x `head_dim: 256` x 2 (K+V) x
2 bytes that is **64 KB/token**, halved to 32 KB/token by
`--kv-cache-quantization` — about 1GB at a 32K window. 16.05GB of weights plus
~1GB of cache against a ~19GB budget is workable but genuinely tight; expect
some paging if other apps are competing for memory.

| Model | Size | Free RAM | Status |
|-------|------|----------|--------|
| **Qwen3.8-27B** | **~16GB** | **~3GB** | **Best quality — tight; consider the GPU-limit bump** |
| Qwen3.8-27B 3-bit | ~13GB | ~6GB | Roomier context, faster |
| **Gemma-4-E4B** | **~5GB** | **~19GB** | **Light default — verified tool loop** |
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

**Solution**: Fixed upstream long ago. `install.sh` now installs from
[vitorallo/vllm-mlx@feat/claude-code-local-0.4.1](https://github.com/vitorallo/vllm-mlx/tree/feat/claude-code-local-0.4.1)
— a fresh branch off upstream **v0.4.1** carrying only three patches that are
still genuinely absent upstream: `POST /v1/reset` + `health.memory_warning`,
the opt-in `--tool-call-truncation-notice`, and `qwen3_xml`/`qwen3.5` in the
`--tool-call-parser` choices. See #18 for why the previous branch (354 commits
behind upstream, with a hard-pinned MLX stack) was retired rather than rebased.

> **If another project shares this fork:** it will consume it through its own
> pin — a git submodule or its own venv — on its own branch. Switching branches
> here does not affect it, provided you create a new branch rather than
> rewriting or force-pushing one another project already points at.

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
  1) Shrink budgets   --max-tokens 32768 → 16384, --max-kv-size 32768 → 16384
  2) Raise GPU limit  iogpu.wired_limit_mb 0 → 21504  (sudo, until reboot)
  3) Both
  c) Continue as-is (risky)     q) Quit
Choose [1/2/3/c/q] (Enter = 1):
```

(This GPU-budget metric is why a ~15GB cached model with ~9GB of *free RAM*
still OOM-crashed — only ~3GB was actually GPU-usable under the default cap.)

- **Option 1** halves both token budgets: `--max-tokens` (the longest single
  generation, i.e. peak memory while one reply is produced) and
  `--max-kv-size` (the KV cache bound per sequence — the real context window,
  and the only one that affects steady-state memory across a long agentic
  session). Earlier versions shrank only `--max-tokens` and called it
  "shrink context", which was misleading: it capped reply length without
  bounding the cache that actually grows. See
  [Context window and token budgets](#3-context-window-and-token-budgets).
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

**Root cause 3d is now structurally solved — by the model, not a patch.**
Qwen3.8 (and Qwen 3.5 / Qwen3-Coder) emit tool calls as **XML with raw-text
parameters**:

```
<tool_call>
<function=Write>
<parameter=file_path>/tmp/quotes.py</parameter>
<parameter=content>...the file body, verbatim, unescaped...</parameter>
</function>
</tool_call>
```

The model never escapes anything; the *parser* does the JSON encoding. The
whole class of "4-bit model fails to `\"`-escape a quote-dense file body so
`json.loads` drops the call" simply cannot occur. Verified end-to-end: a
48-line module with 58 double quotes, nested escaped quotes and `\n`
sequences round-tripped through `json.loads` into a file that compiles and
runs. Enabled with `--tool-call-parser qwen3_xml`, set per-model from the
`run.sh` catalog.

**Fixed in the fork** (`vitorallo/vllm-mlx`, branch
`feat/claude-code-local-0.4.1`, a fresh branch off upstream v0.4.1):
- **MLX stack unpinned.** The old branch hard-pinned `mlx==0.31.1` /
  `mlx-lm==0.31.1` and capped `mlx-vlm<0.5.0` to dodge
  `RuntimeError: There is no Stream(gpu, N) in current thread`. That was
  [upstream issue #407](https://github.com/waybarrios/vllm-mlx/issues/407),
  fixed 2026-04-24 in PR #452 (inline `prepare_for_start`, a
  `ResidencyManager` thread-divergence guard, explicit stream rebind in
  `stream_generate`). The pins are gone; the stack floats again at
  mlx 0.32.x / mlx-lm 0.31.3+ / mlx-vlm 0.6.x — which is precisely what makes
  Qwen3.8 loadable.
- **Fail-loud `--tool-call-truncation-notice` (opt-in, default OFF).** When a
  tool call is still truncated by the token cap, the server returns an
  explicit *"write the file in smaller parts"* message instead of a silent
  HTTP 200. The gate tests **completeness, not presence**: the Qwen3 XML
  parser happily builds a tool call out of a half-arrived `<function=Write>`,
  leaving either empty arguments or a JSON fragment that never closes. Both
  are worse than no tool call — the agent would run `Write` with no
  arguments, or write a silently truncated file — so arguments must parse as
  JSON and be non-empty, and when the notice fires the shells are dropped and
  `stop_reason` becomes `end_turn`. Covered by
  `tests/test_tool_call_truncation_notice.py`.
- **`qwen3_xml` / `qwen3.5` exposed** in `--tool-call-parser`. The parser was
  already registered under all three aliases in 0.4.1, but the hardcoded
  argparse choices list carried only `qwen3_coder`.
- **Not carried over:** four Gemma-4 channel-cleaning patches (D1/D2
  `_find_tool_call_spans` and friends). Upstream 0.4.1 handles Gemma 4 tool
  calls with a real `gemma4_tool_parser.py` rather than text cleaning, so
  they are held in reserve on the old branch pending a Gemma regression.

**Mitigations (in `run.sh`)**:
- **Proactive guidance**: `run.sh` passes `--append-system-prompt` telling
  the model up front to write files >~150 lines in sections, so it pre-empts
  truncation rather than hitting it.
- `CC_OUTPUT_TOKENS` default raised **4096 → 8192** for *all* models, with
  per-run override `--out-tokens N` (use `16384` for big files; pair with
  `--safe` if a large model then OOMs).
- `server.log` is now **rotated** to `server.log.1` instead of truncated, so
  a failed tool-call session can actually be inspected afterward.

**Honest limits**: the escaping failure is gone, and the silent failure is
gone. What remains is arithmetic: a single artifact larger than the
output-token budget still cannot be emitted in one call, on any engine. The
proactive `--append-system-prompt` guidance plus the fail-loud notice steer
the agent to chunk it. And Qwen3.8-27B is *slow* — ~7.5 tok/s at 4-bit on an
M5 24GB — so for bulk file-writing the lighter models remain more comfortable
even though they are less correct.

### 19. "System message must be at the beginning" (opaque HTTP 500)

**Problem**: Mid-session, Claude Code shows a generic API error and the
session stops working. `server.log` has the real cause:

```
jinja2.exceptions.TemplateError: System message must be at the beginning.
```

Qwen 3.5 / 3.8 chat templates refuse a `system` message at any index but 0.
Claude Code does send one mid-conversation, and vllm-mlx's `developer` →
`system` role mapping manufactures more. The template raises, FastAPI turns it
into a 500, and the client sees only "API error".

This is not vllm-mlx-specific. **LM Studio's Anthropic endpoint rejects the
same request** at schema validation, before inference:

```
request.messages.1.role: Invalid discriminator value. Expected 'user' | 'assistant'
```

Strictly, the Anthropic Messages API puts system content in a top-level
`system` field, not in `messages[]` — so LM Studio is validating correctly and
Claude Code is the one being loose. Our fork chooses leniency, because
refusing the request just breaks the session. It's the reason `--lmstudio`
does not currently work with Claude Code.

**Solution**: fixed in the fork. `_normalize_messages()` now **hoists** every
non-leading system message into the leading system block (creating one if the
conversation didn't start with a system message). Merging preserves the
instruction text and keeps it classified as an instruction — dropping it loses
guidance, and demoting it to `user` reclassifies instructions as dialogue. A
multimodal (non-string) system message can't be merged into text, so it is
demoted to `user` rather than discarded. Conversations with no misplaced
system message are returned byte-identical.

Verified live: a mid-conversation `system` message and a mid-conversation
`developer` message both return 200, and the hoisted instruction still takes
effect.

### 20. Claude Code assumes a 200k context window

**Problem**: On startup Claude Code prints:

```
"mlx-community/Qwen3.8-27B-4bit" is not a model this version of Claude Code
recognizes, so auto-compact will keep this session within 200k tokens
(the context window it assumes).
```

It doesn't know these model IDs, so it guesses 200k. The server is actually
serving a 32K window (`--max-kv-size`). Claude Code would therefore let a
session grow ~6× past the real window before auto-compacting, while
`RotatingKVCache` silently evicted the oldest tokens. The failure mode is
nasty because nothing errors — the model just progressively forgets the start
of the conversation and appears to get worse as the session goes on.

**Solution**: `run.sh` sets `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the window
actually being served, so auto-compact fires before eviction does. The warning
still prints (Claude Code emits it before reading the variable) and is safe to
ignore. In remote mode the variable is left unset, since the remote's window
is unknown and probably larger.

**Every local model gets one.** An earlier version only set this for models
with an explicit `--max-kv-size`, which meant only `--qwen38` — so `--gemma`
and the rest still ran on the 200k assumption. Now every catalog entry carries
a KV bound (`32768` for the ~14GB+ models, `65536` for the ~5GB ones) and a
custom `--model` falls back to `32768`. Bounding the KV is worth doing anyway:
left unbounded the cache grows until Metal OOMs.

**The warning cannot be suppressed, and two of its three suggestions are
traps.** Checked against the [model configuration
docs](https://code.claude.com/docs/en/model-config):

| Suggestion | Effect here |
|---|---|
| Append `[1m]` to the model name | **Don't.** Declares a 1M window — 30× further from the truth than the 200k default, in the wrong direction. The assumed window is already far too big. |
| Set `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | **Correct, already done** by `run.sh`. Fixes when auto-compact fires. Does *not* silence the warning — that is printed before the variable is read. |
| Map it in `modelOverrides` | Doesn't help. It remaps model IDs for provider routing (Bedrock ARNs and the like) and silences a separate stderr diagnostic, not this warning. |
| `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` | **Don't.** It defers compaction until the API rejects the conversation outright. On a 32K window you want compaction *early*, not after a failure. |

So: the warning is cosmetic here and stays. There is no documented way to make
Claude Code recognise a local model ID.

**`run.sh` reports 85% of the real bound**, not 100% — e.g. `27852` for a
`32768` window. Claude Code compacts as it nears the window it believes in, and
compaction is itself a model call that must fit inside that window. Set to
exactly `--max-kv-size`, that threshold coincides with `RotatingKVCache`'s
eviction point, so a session can start losing its oldest tokens just as it
tries to summarise them. See
[Context window and token budgets](#3-context-window-and-token-budgets).

### 21. Concurrent requests rejected mid-session ("API error")

**Problem**: The session dies with a generic API error. `server.log` shows:

```
vllm_mlx.engine.base.EngineBusy: SimpleEngine serialized route is busy;
  request_id=simple-9f22d4000; active=...; waiters=0; retry later
POST /v1/messages?beta=true HTTP/1.1" 500 Internal Server Error
```

The engine is deliberately serialized — no `--continuous-batching`, because
concurrent Metal work OOMs a large model on 24GB (see
[#7](#7-concurrent-requests-oom)). But its default admission policy is
`fail_fast`: a second in-flight request is **rejected outright** rather than
queued (`waiters=0` — there is no queue). Claude Code routinely issues
overlapping requests, so this fires within a few turns.

**Solution**: `run.sh` sets `VLLM_MLX_SIMPLE_ENGINE_LOCK_ADMISSION=wait`. Same
one-at-a-time execution, but the second request now waits on the lock instead
of being refused. Verified: three concurrent `/v1/messages` calls all return
200, correctly, with zero `EngineBusy`.

Two supporting fixes in the fork:

- `/v1/messages` now translates `EngineBusy` into a retryable **503**, as the
  OpenAI endpoints already did. A 500 tells the client the request is fatal
  when the right answer is "retry".
- Serialization is still the right call on 24GB. `--continuous-batching` is
  not the fix here; queueing is.

### 22. Sampling flags silently disable the system prompt cache

**Problem**: Qwen publishes `top_k=20` and `presence_penalty=1.5` for
non-thinking mode. Setting them costs far more than they're worth here.
`server.log`:

```
System KV cache SKIP (stream_chat): request or engine has controls/features
the cache branch cannot honor (['top_k', 'presence_penalty']); using uncached path
```

vllm-mlx's system-prompt KV cache drives `mlx_lm.stream_generate` with a
sampler built from **temperature and top_p only**. Any of `top_k`, `min_p`,
`presence_penalty` or `repetition_penalty` at a non-default value makes the
engine skip the cache entirely — so Claude Code's large system prompt is
re-prefilled from scratch on *every turn*. That is the same class of
regression as [#4](#4-kv-cache-invalidation-90-slowdown), traded away for a
marginal sampling tweak.

**Solution**: `run.sh` sets only `--default-temperature` and
`--default-top-p`, which the cached path honours, and deliberately does not
set the other four. Verified: the SKIP messages are gone and the cache now
reports `MISS → STORED → HIT` across turns.

### 23. Everything works but is unusably slow (cache budget vs. weights)

**Problem**: No errors, but a bare "hi" takes 20+ seconds. `vm.swapusage`
shows many GB swapped and memory pressure is high. The machine is thrashing,
not computing.

Two numbers collide on a 24GB Mac:

- `--cache-memory-percent 0.35` reserves **35% of total RAM** for the
  prompt/prefix cache — 8.6GB on a 24GB machine.
- Qwen3.8-27B's weights are **16GB**.

16 + 8.6 = **24.4GB requested against an ~18.4GB GPU budget** — more than the
machine physically has. That default was tuned when every model here was ~5GB
(5 + 8.6 = 13.6GB, comfortable); nobody revisited it when a 16GB model was
added.

**Solution**: `run.sh` now sizes the cache from what's actually left after the
weights — `GPU budget − weights − 1.5GB` for activations and KV, clamped to
[512MB, 8GB] — and passes it as `--cache-memory-mb`. On this machine that's
~1.5GB instead of 8.6GB, so weights + cache come to 16.9GB against an 18.4GB
budget.

Measured effect on an M5/24GB, same prompt: **22.9s → 1.2s**.

### 24. The 3-bit quant is broken — don't use it

`leonsarmiento/Qwen3.8-27B-3bit-mtp-mlx` was briefly shipped here as
`--qwen38-fast` on the reasoning that 13GB of weights beats 16GB on a 24GB
Mac. It has been **removed**. The quant does not produce usable output:

```
$ "What is 2+2? Answer with just the number."
  -> '□:**  о_{{齐吻_worksystem\n ま+竟然砂_function初始"/_ok-ok_稍微<'
```

That is not degradation, it is noise — on a trivial prompt, with the same
engine, parser and flags that produce correct answers at 4-bit. Tool calling
never fires; `stop_reason` comes back `end_turn` with 1.6KB of token soup.
Whether the cause is 3-bit affine quantization being too aggressive for this
hybrid-attention architecture or the MTP weight injection, it is not usable
and not worth debugging.

**4-bit is the only usable quant** on Apple Silicon today. 6-bit and 8-bit
don't fit 24GB.

The lesson generalises: a community quant that loads, serves, and answers
quickly is not thereby *working*. Latency was fine — 1.0s on a short prompt —
and it would have passed any benchmark that didn't read the output. Check
coherence on a trivial factual prompt before trusting any new quant.

### 25. Sizing the system-prompt cache (corrected)

Claude Code's system prompt measures **~13,000 tokens**. Caching it is what
makes turn 2 onward fast, so its size matters. Measured from the engine's own
`STORED` lines, two points:

| System prompt | Cache stored |
|---|---|
| 684 tokens | 204.3 MB |
| 13,008 tokens | 1009.6 MB |

That is **66.9 KB/token plus ~160MB fixed** — the fixed part being
linear-attention state, which is per-sequence, not per-token. It matches the
KV arithmetic in [Context window and token budgets](#3-context-window-and-token-budgets)
(64 KB/token across the 16 full-attention layers).

An earlier version of this README extrapolated 306 KB/token from the 684-token
sample alone and concluded 4-bit couldn't fit on 24GB. That was wrong: the
small sample was almost entirely fixed overhead. The real figures are

| | 4-bit on 24GB |
|---|---|
| Weights | 16.0 GB |
| 13k-token system cache | ~1.0 GB |
| **Total** | **~17.0 GB** vs an ~18.4GB budget — fits |

Measured end-to-end, 13k-token system prompt, M5/24GB:

| | Time |
|---|---|
| First turn (cold, must prefill 13k tokens) | ~115 s |
| Subsequent turns (cache `HIT`) | **~2 s** |

So expect one slow turn per distinct system prompt, then normal speed. The
real memory problem was never the weights or the cache — it was
[#23](#23-everything-works-but-is-unusably-slow-cache-budget-vs-weights),
a cache *budget* asking for 8.6GB it was never going to use.

If the machine has already been thrashing, reboot before re-measuring — macOS
grows the swap file and does not shrink it back, so timings taken after a
thrash are not representative.

### 26. Qwen3.8 on 24GB: the honest verdict

It runs. It is not comfortable, and on a 24GB Mac it is probably not the right
choice for real agentic work.

Measured on an M5/24GB, `iogpu.wired_limit_mb` left at its default:

| | Result |
|---|---|
| Short exchange ("hi", a 2-turn test) | works |
| 13k-token system prompt, first turn | ~111 s (full prefill) |
| Same prompt, later turns | ~1.9 s (cache `HIT`) |
| **Real session — 8 messages, 30 tools, accumulating context** | **Metal OOM** |

The failure is specific and reproducible from the log:

```
System KV cache HIT (stream_chat): reusing 13536 tokens
Pure-LLM KV-cache path failed before first token (Metal OOM); falling back to
  uncached stream_generate
Streaming error, ensuring terminal frame: [METAL] ... OutOfMemory
```

The prefix cache costs its size **twice** at peak — the stored snapshot plus
the live copy restored on a hit. With 15.3GB of weights against an 18.4GB
budget, a 13.5k-token system prompt (1043MB stored, 1043MB restored) leaves
about 1GB for live conversation KV and activations. A bare exchange fits; turn
8 of a real session does not. `run.sh` now halves the cache budget to account
for the doubling, which helps but does not create memory that isn't there.

**Raising `iogpu.wired_limit_mb` is the only thing that genuinely fixes it, and
it is not recommended.** That cap exists to stop the GPU starving macOS. Push
it to 21.5GB on a 24GB machine and a heavy model can take memory the system
needs, at which point the whole Mac stalls — for hours, in one case here. The
preflight offers it, warns about it, and never chooses it for you.

**Recommendation**: on 24GB use **`--gemma`** (26B MoE) or `--gemma-light`.
All three were measured on the same machine, same tests:

| | `--gemma-light` (5GB) | `--gemma` (14GB MoE) | `--qwen38` (15GB dense) |
|---|---|---|---|
| Short reply | 1.3 s | 3.3 s | ~18 s |
| Tool call (~600 chars) | 5.2 s | 5.3 s | 37 s |
| 13k-token system prompt | — | **12.7 s/turn** | 111 s cold, 1.9 s cached |
| Real agentic session | ok | ok | **Metal OOM** |
| `stop_reason: tool_use` | yes | yes | yes |

`--gemma` is the sweet spot here: it is the same 14GB class as Qwen3.8 but MoE
with ~3.8B active, so it prefills a 13k system prompt in ~12.7s instead of
~111s — fast enough that it doesn't need the prefix cache at all, which is
precisely what removes the doubling that OOMs Qwen3.8. Zero errors, zero 500s,
swap flat across the whole test.

Reach for `--qwen38` when you want its code quality on a bounded task and can
accept a slow first turn, or on 32GB+ where none of this applies.

What Qwen3.8 still uniquely gives you, when you can run it, is
[#18](#18-writeedit-tool-call-silently-does-nothing-no-error): XML tool calls
that never ask the model to escape a file body. Both Gemmas get that wrong, in
opposite directions, and both do it *inside a perfectly valid tool call* —
the JSON parses, the Python doesn't:

- **E4B under-escapes**: `"author4": " "The only thing we have to fear..."",`
- **26B over-escapes**: emits `\"\"\"` for a docstring, as though still inside
  the JSON string it had already left.

That is problem 3d exactly, and no server patch fixes it — only a model that
never has to escape anything.

### 27. Gemma narrates instead of acting, and the loop stalls

**Symptom**: mid-session Claude Code prints what it is *about* to do and then
stops. Nothing executes. You type "continue" and it proceeds — sometimes.

**Cause**: Gemma 4 ignores `enable_thinking=false` (see `gemma4-status.md`) and
emits an asymmetric `<|channel>thought …` block. With `--tool-call-parser auto`
and no reasoning parser, that block is delivered as **plain assistant text** —
so Claude Code renders the model's private deliberation as its answer. Worse,
that text then goes back in as conversation history, so on the next turn the
model continues narrating rather than calling a tool.

Measured on `gemma-4-e4b-it-4bit`, same prompt, same tools:

| | `--tool-call-parser auto` | `--tool-call-parser gemma4 --reasoning-parser gemma4` |
|---|---|---|
| Leaked `<\|channel>` text | **817 chars** | **0** |
| Structured `thinking` block | none | 797 chars |
| Tool call + arguments | correct | correct |
| `stop_reason` | `tool_use` | `tool_use` |

**Solution**: the catalog now pins **`gemma4`** as both the tool-call parser and
the reasoning parser for `--gemma-light` and `--gemma`. The reasoning parser is
applied *regardless of `--think`*, because for Gemma thinking cannot be turned
off — the only choice is whether it arrives as a structured `thinking` block or
as text pretending to be the answer.

This is also why `--tool-call-parser auto` is not a free default: it works, but
"works" only meant the tool call parsed. Naming the model's own parser is
strictly better wherever the model is known.

### 28. Client gives up on a long generation

**Symptom**: Claude Code announces what it will build, then sits there. At the
bottom: `Waiting for API response · will retry in 4m 40s · check your network`.
Nothing is wrong with the network, and `server.log` shows **no error at all** —
just a request that starts and never gets a completion line, because the server
is still happily generating.

**Cause**: Claude Code's client-side timeouts assume a cloud API, and the client
gives up long before a local model finishes. Two of them bite:

| Variable | Default | Why it fires here |
|---|---|---|
| `API_TIMEOUT_MS` | 600000 (10 min) | A 26B model observed at **1.6 tok/s** needs ~85 min for an 8192-token file |
| `API_FORCE_IDLE_TIMEOUT` | on for every non-Anthropic provider | Aborts a stream after 5 minutes with no bytes — and a 13k-token prefill sends nothing at all while it runs |

The giveaway is the asymmetry: the server log has zero errors and no completion
line, while the client reports a network problem. Whenever those two disagree,
the client timed out.

**Solution**: `run.sh` now sets `API_TIMEOUT_MS=1800000`,
`API_FORCE_IDLE_TIMEOUT=0` and `CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=1800000`
(the documented 30-minute ceiling), and raises the server's own `--timeout` to
1800 to match. Disabling the idle abort is safe here in a way it wouldn't be
against a remote provider: the server is on localhost and its liveness is
already tracked by `disconnect_guard`.

**This does not make it fast.** It stops a long generation being thrown away.
If a single file takes 20 minutes, the real fixes are a smaller file (`run.sh`
already tells the model to write in sections — see
[#18](#18-writeedit-tool-call-silently-does-nothing-no-error)) or a faster
model. And if a model that was doing 5–9 tok/s is suddenly doing 1.6, check for
a second `cclocal` session with another model still resident — see
[#29](#29-two-cclocal-sessions-fight-over-port-8000).

### 29. Two cclocal sessions fight over port 8000

Every `cclocal` run defaults to port 8000. Start a second one and the outcomes
are all bad and none of them say so:

- the second server can't bind and dies, but Claude Code still launches pointed
  at 8000 — where the **first** session's server answers with a different
  model, so every request 404s (`The model X does not exist. Available model:
  Y`), which Claude Code reports as *"check your network"*;
- or both models stay resident — e.g. 5GB + 14GB on a 24GB Mac — and
  everything slows to a crawl from memory pressure.

**Solution**: `run.sh` now checks the port before launching and refuses with an
actionable message, naming the model already there and the one you asked for.
To run two at once, give the second its own port; to attach a second Claude
Code to a server that's already running, use `--remote`:

```bash
cclocal --gemma --port 8001                 # independent second server
cclocal --remote http://127.0.0.1:8000      # attach to an existing one
```

### 30. Evaluating a new model: check that it *writes files*, not that it answers

`mlx-community/gemma-4-12b-coder-fable5-composer2.5-4bit` was evaluated and
**rejected**. It is instructive because almost everything about it looks right.

What works:

- loads cleanly (`gemma4_unified`, via mlx-vlm), 6.3GB on disk, 8s cold start
- coherent, **16.3 tok/s** — faster than anything else tried here
- clean structured `thinking` blocks, zero `<|channel>` leakage
- simple tool calls: `Read /etc/hostname`, `Bash echo hi`, `Write` a two-line
  function — 3/3 with correct arguments

What doesn't:

- asked to `Write` an actual code file, it emits *"Use the `Write` tool once to
  create the"* followed by a ` ```python ` markdown block — **0/5** across
  content sizes (3, 8 and 20 dict entries)
- adding a system prompt stating *"NEVER print file contents in a markdown code
  block — always emit an actual Write tool call"* changed nothing: **0/2**, and
  byte-identical across runs. It is not sampling noise, it is what the model
  does.

That is precisely the "says what it will do, then stops" failure of
[#27](#27-gemma-narrates-instead-of-acting-and-the-loop-stalls), except no
parser can fix it — there is no tool call to parse. Plausibly the coder
fine-tune optimised for emitting code blocks and eroded the agentic tool
behaviour of the base model.

**The lesson, which cost real time twice** (see also
[#24](#24-the-3-bit-quant-is-broken-dont-use-it)): a model that loads, streams
fast and answers correctly can still be useless here. Benchmarks that read only
latency and coherence pass both of these models. Before adopting any new model,
run the one test that matters:

```bash
# ask it to Write a real file, then check what came back
grep -o '"type": "tool_use"' out.txt     # must be present
grep -o '```python' out.txt              # must NOT be present
```

If the answer arrives as a markdown block instead of a `tool_use` block, the
model cannot drive Claude Code, however good it looks otherwise.

### 31. Every tool request returns HTTP 500 (union types in tool schemas)

**Symptom**: with tools enabled, every request fails. `server.log` shows:

```
File "<template>", line 59, in top-level template code
TypeError: can only concatenate str (not "list") to str
```

**Cause**: JSON Schema permits `"type": ["boolean", "null"]`, and Claude Code
declares optional tool parameters that way. Qwen3.5's chat template renders the
schema by string concatenation —

```jinja
"<type>" + param_details.type + "</type>"
```

— so a list type raises inside Jinja *before the model sees anything*. The
client gets an opaque 500 that says nothing about tool schemas.

**Solution**: fixed in the fork. `convert_tools_for_template()` — the single
choke point both the Anthropic and OpenAI paths pass through — now collapses a
list `type` to its first non-`null` member. The null branch carries nothing a
prompt can use, and scalar types are untouched. Only the copy given to the
template is rewritten; the schema used for constrained decoding keeps its union
types.

Worth noting how narrowly this was missed: `--deckard` passed every API-level
test — file writing, chaining, coherence — because those tests used simple tool
schemas. Claude Code's real schemas have optional parameters, and the model
never got a chance to be wrong.

---

## Troubleshooting

**Start with `server.log`.** Claude Code reports every backend failure as a
generic "API error" with no detail. The real cause is always in the server
log, and the previous run is preserved rather than overwritten:

```bash
tail -40 server.log      # this run
tail -40 server.log.1    # the run before it (kept back to server.log.5)
```

`run.sh` keeps **five** generations. One is not enough: starting a couple more
servers — testing a different model, a failed launch, anything — silently
destroys the evidence from the session you actually wanted to diagnose.

Every entry in the table below was first diagnosed that way.

| Symptom | Cause | Fix |
|---------|-------|-----|
| `install.sh` seems to stop after the `mlx: … mlx-lm: … mlx-vlm: …` line | It didn't — that line ends step [2/3] | A finished run prints `[3/3]` then `=== Setup Complete ===`. See [What a finished install looks like](#what-a-finished-install-looks-like) |
| `RuntimeError: There is no Stream(gpu, N) in current thread` | Old pinned venv (mlx 0.31.1 era) | Re-run `./install.sh` — fixed upstream in vllm-mlx PR #452, see [#13](#13-vllm-mlx-critical-bug-missing-return-statement-historical) |
| Qwen3.8 won't load / unknown architecture | venv still pinned to `mlx-lm==0.31.1` | Re-run `./install.sh`. Qwen3.8 needs mlx-lm 0.31.3+; it runs on the `qwen3_5` architecture, which older mlx-lm has but the pinned stack couldn't reach |
| Model loads, then the whole Mac stalls / heavy swapping | Almost always the cache budget, not the weights | See [#23](#23-everything-works-but-is-unusably-slow-cache-budget-vs-weights); if it persists, take preflight option 2 (`iogpu.wired_limit_mb` → 21504) |
| Qwen3.8 thinks for minutes before doing anything | Thinking left on at the model's `xhigh` default | Don't pass `--think`. Off is the default; `--think` uses `reasoning_effort=low` — see [#3](#3-reasoningthinking-tokens-garbage-output) |
| Tool call returns "⚠ The previous tool call was discarded…" | A tool call was truncated by the output-token cap | Working as intended — that's the fail-loud notice. Raise `--out-tokens 16384`, or let the model write the file in sections — see [#18](#18-writeedit-tool-call-silently-does-nothing-no-error) |
| vllm-mlx crashes on startup (TypeError: NoneType) | Using unpatched upstream | `./install.sh` installs from our fork which has the fix |
| Model generates text about tools but nothing executes | Using Ollama | Switch to vllm-mlx — Ollama can't produce real tool_use blocks |
| Metal GPU OOM crash under load (`kIOGPUCommandBufferCallbackErrorOutOfMemory`) | Large model + growing agentic context exceeds the GPU budget; the prefix cache costs its size twice at peak | On 24GB with a 16GB model this is expected in a real session — use `--gemma-light`, see [#26](#26-qwen38-on-24gb-the-honest-verdict) and #17 |
| First run hangs at "Waiting for server..." | Multi-GB model still downloading from HuggingFace | It's not hung — a live download progress line now shows; partial downloads resume — see #16 |
| Write/Edit tool call shows then silently does nothing (no error) | Large tool-call output truncated by the token cap (+ fork channel-filter) | `--out-tokens 16384`, or use `gemma-light`/a coder model; inspect `server.log.1` — see #18 |
| Generic "API error" mid-session; log shows `TemplateError: System message must be at the beginning` | Qwen 3.5/3.8 templates reject a non-leading system message | Re-run `./install.sh` — the fork now hoists them, see [#19](#19-system-message-must-be-at-the-beginning-opaque-http-500) |
| `--lmstudio`: `messages.1.role: Invalid discriminator value` | LM Studio validates the Anthropic schema strictly; Claude Code puts a system message in `messages[]` | Not fixable here — use the local vllm-mlx path, see [#19](#19-system-message-must-be-at-the-beginning-opaque-http-500) |
| "not a model this version of Claude Code recognizes… 200k tokens" | Claude Code doesn't know local model IDs | Harmless warning; `run.sh` already pins `CLAUDE_CODE_MAX_CONTEXT_TOKENS` to the real window — see [#20](#20-claude-code-assumes-a-200k-context-window) |
| Model seems to forget the start of a long session | Session exceeded `--max-kv-size`; oldest tokens evicted | Raise `--max-kv-size` (and the GPU limit), or start a fresh session — see [#20](#20-claude-code-assumes-a-200k-context-window) |
| Claude Code asks about "detected custom API key" | Real API key leaking | Use `cclocal` which unsets real keys |
| "Model does not exist" (404) | Wrong model name | Must use full HuggingFace ID, not "default" |
| `EngineBusy: serialized route is busy` → API error | Concurrent requests rejected instead of queued | Re-run `./install.sh`; `run.sh` now sets `VLLM_MLX_SIMPLE_ENGINE_LOCK_ADMISSION=wait` — see [#21](#21-concurrent-requests-rejected-mid-session-api-error) |
| `System KV cache SKIP … (['top_k', 'presence_penalty'])` | Sampling flags disable the prefix cache; system prompt re-prefilled every turn | Don't set `top_k`/`min_p`/`presence_penalty`/`repetition_penalty` — see [#22](#22-sampling-flags-silently-disable-the-system-prompt-cache) |
| No errors but everything crawls; `sysctl vm.swapusage` shows GB swapped | Cache budget + weights exceed the GPU budget | Re-run with current `run.sh` — the cache is now sized from what's left after weights, see [#23](#23-everything-works-but-is-unusably-slow-cache-budget-vs-weights) |
| Claude Code says what it will do, then stops; you must type "continue" | Gemma's `<\|channel>thought` leaking as assistant text and re-entering history | Re-launch — the catalog now uses the `gemma4` tool *and* reasoning parsers, see [#27](#27-gemma-narrates-instead-of-acting-and-the-loop-stalls) |
| "Waiting for API response … check your network", but `server.log` shows no error | Claude Code's client timeout fired while the server was still generating | Re-launch — `run.sh` now raises `API_TIMEOUT_MS` and disables the 5-min idle abort, see [#28](#28-client-gives-up-on-a-long-generation) |
| A model that was fast is suddenly ~1 tok/s | A second `cclocal` session left another model resident | Stop the other session; `run.sh` now refuses to share a port, see [#29](#29-two-cclocal-sessions-fight-over-port-8000) |
| Slow responses (30-75s) | Normal for local inference | ~7.5 tok/s on an M5 24GB. The *first* turn against a new system prompt also pays a ~115s prefill; later turns hit the cache and cost ~2s. Use a light model if it's too slow |

---

## Configuration reference

### Environment variables (set by run.sh per-session)

| Variable | Value | Purpose |
|----------|-------|---------|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:8000` (local) or the remote URL with `--remote`/`--dgx-*` | Point Claude Code at the server |
| `ANTHROPIC_API_KEY` | `not-needed` | Dummy key (real key explicitly unset) |
| `ANTHROPIC_MODEL` | Full HuggingFace ID | Model identifier |
| `ANTHROPIC_DEFAULT_*_MODEL` | Same as above | Route all tiers (Opus/Sonnet/Haiku) locally |
| `CLAUDE_CODE_SUBAGENT_MODEL` | Same as above | Route subagent calls locally |
| `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | `8192` default, `--out-tokens N` to override | Output cap; must fit a whole Write/Edit file body (see #18) |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | 85% of `--max-kv-size` (local runs only) | The window Claude Code assumes, so auto-compact fires — with headroom to run — before the KV cache evicts (see #20) |
| `CLAUDE_CODE_ATTRIBUTION_HEADER` | `0` | Prevents KV cache invalidation |
| `DISABLE_PROMPT_CACHING` | `1` | Local server doesn't support Anthropic caching |
| `DISABLE_AUTOUPDATER` | `1` | No update checks |
| `DISABLE_TELEMETRY` | `1` | No telemetry |
| `DISABLE_ERROR_REPORTING` | `1` | No error reporting |
| `DISABLE_NON_ESSENTIAL_MODEL_CALLS` | `1` | Reduce background model calls |

### vllm-mlx server flags (set by run.sh)

| Flag | Purpose |
|------|---------|
| `--default-chat-template-kwargs` | `{"enable_thinking": false, "preserve_thinking": false}`, or `{"reasoning_effort": "low", ...}` with `--think` (see #3) |
| `--reasoning-parser qwen3` | Only with `--think`: emit `<think>` as structured Anthropic thinking blocks instead of leaking text |
| `--default-temperature` / `--default-top-p` | Qwen's published sampling values, which differ between thinking and non-thinking modes (see #3). Only these two — `top_k`, `min_p`, `presence_penalty` and `repetition_penalty` are deliberately left unset because they disable the system prompt cache (see #22) |
| `VLLM_MLX_SIMPLE_ENGINE_LOCK_ADMISSION=wait` | Queue concurrent requests on the serialized engine instead of rejecting them (see #21) |
| `VLLM_MLX_ENABLE_THINKING` | Legacy fallback for engines predating `--default-chat-template-kwargs` |
| `--max-kv-size` | **The context window.** KV cache bound per sequence (RotatingKVCache); past it the oldest tokens are evicted. `32768` for the ~14GB+ models, `65536` for the ~5GB ones; set for every local model so the KV can't grow unbounded. The memory preflight halves it but never below a `32768` floor — Claude Code's system prompt plus ~30 tool definitions is already several thousand tokens, and vllm-mlx's own guidance is `>= 32768` for reasoning models. See [Context window and token budgets](#3-context-window-and-token-budgets) |
| `--kv-cache-quantization` | 8-bit KV cache — halves cache memory usage |
| `--cache-memory-mb` | Prompt/prefix cache budget, computed per-model as `GPU budget − weights − 1.5GB`, clamped to [512MB, 8GB]. Replaces a fixed `--cache-memory-percent 0.35`, which asked for 8.6GB on top of 16GB of weights and guaranteed swap (see #23) |
| `--prefill-step-size 4096` | Faster time-to-first-token on large prompts |
| `--stream-interval 4` | Batch 4 tokens before streaming for throughput |
| `--timeout 1800` | 30 min, matched to the client-side `API_TIMEOUT_MS` (see #28) |
| `--max-tokens` | Default length of a **single generation**, not the context window: `32768`, halved to `16384` by the memory preflight (see #17) |
| `--max-request-tokens` | Ceiling on the `max_tokens` a client may ask for. Engine default `32768`; not set by `run.sh` |
| `--enable-auto-tool-choice --tool-call-parser` | Parse model output into structured tool_use blocks. `qwen3_xml` for Qwen 3.5/3.8/Coder (XML `<function=..><parameter=..>`), `auto` (sniffs Gemma 4 / Mistral / Llama / Hermes) otherwise. Per-model, from the `run.sh` catalog |
| `--tool-call-truncation-notice` | Fork flag: on a tool call truncated by the output-token cap, return an explicit "write it in smaller parts" message instead of silent text or an unrunnable argument-less tool call (see #18) |

### CLI flags / env (memory preflight)

| Flag / env | Purpose |
|------------|---------|
| `--safe` / `CCLOCAL_FORCE_MEMCHECK=1` | Always show the memory-safeguard menu, for any model (see #17) |
| `--no-mem-check` / `CCLOCAL_NO_MEMCHECK=1` | Skip the GPU-headroom preflight prompt (see #17) |
| `--out-tokens N` | Max output tokens Claude Code requests (default 8192; raise to 16384 for large file writes — see #18) |
| `--think` | Enable brief reasoning (`reasoning_effort=low`) instead of none (see #3) |
| `--lmstudio` | Point at LM Studio's server on this Mac instead of running vllm-mlx (see [Remote backend](#remote-backend-dgx-spark-or-any-vllm-box)) |
| `iogpu.wired_limit_mb` | Optionally raised via `sudo sysctl` by preflight option 2; **per-session only** — reverted on exit (prompts for sudo at shutdown if creds expired), and resets on reboot |

### Claude Code flags (set by run.sh)

| Flag | Purpose |
|------|---------|
| `--strict-mcp-config` | Ignore global plugins |
| `--mcp-config mcp-local.json` | Empty config — no plugin tools |
| `--tools "Bash,Read,..."` | 8 essential built-in tools only |
| `--allowedTools "Bash,Read,..."` | Pre-approve the same 8 tools so auto mode skips the slow per-action safety-classifier call (see #18) |
| `--append-system-prompt "..."` | Tells the model to build files >~150 lines in incremental Write/Edit calls, pre-empting output-token truncation (see #18) |

---

## File structure

```
claude-code-local/
  run.sh                    # Launcher — model catalog, memory preflight, starts vllm-mlx + Claude Code
  install.sh                # Setup — creates .venv, installs the vllm-mlx fork, symlinks cclocal
  mcp-local.json            # Empty MCP config (strips plugins for local sessions)
  docs/
    running-claude-code-on-local-llms.md   # Field report: every wall, root causes, honest limits
  server.log                # Last server run (rotated to server.log.1 … .5) — first place to look
  .venv/                    # Local Python venv with vllm-mlx (created by install.sh)
  .gitignore
  README.md
```

The model catalog lives in `run.sh` as parallel arrays (`MODEL_FLAGS`,
`MODEL_IDS`, `MODEL_NAMES`, `MODEL_SIZES`, `MODEL_DESCS`, `MODEL_PARSERS`,
`MODEL_KV_SIZES`) — a single source of truth feeding the flags, the help text
and the interactive menu. To add a model, append one entry to each of the
seven, keeping them the same length.

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
