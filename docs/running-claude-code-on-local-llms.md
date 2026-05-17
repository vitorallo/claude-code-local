# Running Claude Code on a local LLM: the problems, and what it took to fix them

This is a field report. It documents, end to end, the problems encountered
making Claude Code genuinely usable against a local model served by
`vllm-mlx` on Apple Silicon — and the fixes/improvements that went into
`cclocal` (this project) and the `vitorallo/vllm-mlx` fork.

The short version: getting a cloud-grade agent to drive a quantized local
model is not one problem, it is a *stack of compounding problems* across the
harness, the inference server, the ML runtime, and the model itself. Each
layer has a failure mode that masquerades as another layer's bug. Most fail
**silently**. This is why it is hard.

---

## Environment

- Apple Silicon, unified memory (the constrained case studied here: 24 GB).
- Inference: `vllm-mlx` (OpenAI- + Anthropic-compatible local server),
  installed from the `vitorallo/vllm-mlx` fork.
- Driver: `cclocal` (`run.sh`) launches the server and Claude Code with
  session-scoped env, a restricted tool set, and no MCP.
- Model under test: a 4-bit ~26B MoE (Gemma-4-26B-A4B). Generation ~10–23
  tok/s.

---

## The problems, root causes, and fixes

Each item: **Symptom → Root cause → Fix → Residual limit.**

### 1. First-run model download looked like a hang

- **Symptom:** launch sat at "waiting for server" for minutes, then
  "timed out", with no output.
- **Root cause:** the readiness check was a blind fixed-duration `/health`
  poll. A multi-GB HuggingFace download legitimately exceeds it; nothing
  surfaced the download.
- **Fix:** live progress derived from the HF cache directory size
  (downloaded GB + rate), and a *stall-based* timeout that only aborts when
  there is genuinely no progress — never mid-download. Partial downloads
  resume.
- **Residual:** none. (Cosmetic-but-critical: invisible long operations read
  as crashes.)

### 2. Out-of-memory crashes under agentic load (constrained RAM)

- **Symptom:** server hard-crashed mid-generation with
  `[METAL] Insufficient Memory (kIOGPUCommandBufferCallbackErrorOutOfMemory)`;
  the in-flight Claude Code session then spun on `ConnectionRefused`.
- **Root cause:** a ~15 GB model plus a KV cache that grows every agentic
  turn (tool outputs fed back) exceeds the Metal budget. Critically, macOS
  only makes ~75 % of RAM GPU-addressable by default, so "free RAM" *over*-
  states what is usable.
- **Fix:** a pre-flight that estimates the model footprint against the
  *effective GPU budget* (the `iogpu.wired_limit_mb` cap, or ~75 % of RAM),
  and when headroom is tight offers: (1) shrink the server context window,
  (2) raise the GPU wired limit via `sudo` for the session (auto-reverted on
  exit; never persisted across reboot), (3) both. Skippable; forced with
  `--safe`; silent when there is ample headroom.
- **Residual:** a single artifact larger than the budget still cannot be
  produced in one pass on a black-box engine. Hardware/model size is the
  real lever (see "Scaling").

### 3. Write/Edit tool calls that silently did nothing — the central problem

This one had **four** compounding causes; it is the heart of why local-LLM
agents are hard.

- **Symptom:** the model "calls" Write; the invocation is shown; then
  silence. No file, **no error**, HTTP 200. Short tools (`ls`) worked.
- **Root cause 3a — output-token truncation.** A `Write` serializes the
  *entire file body* as output tokens inside the tool-call JSON. The output
  cap was conservative; a real file exceeds it; generation is cut
  mid-`content`; the JSON never closes; no `tool_use` can be parsed; the
  server returns the partial text with a normal finish — silent.
- **Root cause 3b — fork channel-cleaner destroyed tool calls.** The Gemma
  channel cleaner, on an unclosed `<|channel>thought` (which a truncated
  stream produces), deleted everything to end-of-text — *including a tool
  call that followed it*. It also matched channel markers that occur
  *inside* a tool call's file body, corrupting otherwise-valid calls.
- **Root cause 3c — streaming parser fragility.** Tool-call completion was
  detected by substring-in-delta heuristics; large multi-line content
  defeats them.
- **Root cause 3d — invalid JSON from a weak model.** Even when *complete*,
  a 4-bit model frequently fails to `\"`-escape quotes in a long, quote-
  dense `content`; `json.loads` fails; the tool input is dropped.
- **Fixes:**
  - Output budget made a real, tunable knob (`--out-tokens`, sane default
    raised); `server.log` rotated instead of truncated so a failed session
    is actually diagnosable.
  - **Fork fix (D1/D2):** the channel cleaner is now *tool-call-span-safe* —
    channel stripping is applied only outside `<|tool_call>…<tool_call|>`
    spans (reusing the engine's own tag table); spans are kept verbatim.
    With no tool markers present, behaviour is byte-for-byte identical to
    before, and it is Gemma-only — no impact on other model formats.
  - **Fork fix (fail-loud, opt-in):** `--tool-call-truncation-notice` — when
    a tool call is still truncated by the token cap, the server returns an
    explicit *"write the file in smaller parts"* message instead of silent
    text. Default off, model-agnostic, condition-specific (non-tool /
    non-truncated paths unchanged).
  - **Proactive guidance:** `cclocal` passes a system-prompt hint telling
    the model to build large files incrementally, pre-empting the truncation
    cycle.
- **Residual (honest):** 3d is a *model-capability* limit. No server patch
  robustly repairs arbitrary malformed JSON. A complete, valid single-shot
  large write *did* succeed in testing — the failure is *intermittent* on
  large quote-dense content, not absolute. Mitigation is a stronger model
  and/or chunked writes, not more code.

### 4. ML runtime dependency fragility (`Stream(gpu, 1)`)

- **Symptom:** every request 500'd with
  `RuntimeError: There is no Stream(gpu, 1) in current thread`.
- **Root cause:** `mlx 0.31.2` broke GPU streams in `ThreadPoolExecutor`
  worker threads, and `mlx-lm 0.31.2` broke the `BatchGenerator` API. The
  inference server runs generation in a worker thread, so it hit this
  directly. `mlx-vlm 0.5.0` hard-requires the broken `mlx`, dragging it in
  transitively. The fork's dependency floors were loose (`>=`), so a
  reinstall silently resolved to the broken stack.
- **Fix:** the fork's `pyproject.toml` now pins `mlx==0.31.1`,
  `mlx-lm==0.31.1`, and caps `mlx-vlm<0.5.0` (0.4.x still supports the
  model). Reproducible installs; the loose-floor leak is closed.
- **Residual:** the pin freezes out later runtime improvements. A documented
  bisection plan exists to revisit once upstream fixes the worker-thread
  stream behaviour and the `BatchGenerator` API; the exit criteria require a
  real generation (the bug never surfaces in unit tests).

### 5. The permission classifier vs. a slow serialized model

- **Symptom:** in auto mode, `Write` was blocked with "model temporarily
  unavailable, so auto mode cannot determine the safety of Write" — the
  model never even attempted the tool call.
- **Root cause:** auto mode makes a *separate* model call to classify
  whether each tool action is safe. A local model serializes generation
  (one request at a time) and is slow; that classifier call cannot return
  in time, so the harness declares the model unavailable.
- **Fix:** `cclocal` pre-allows its restricted built-in tool set
  (`--allowedTools`). Pre-approved tools need no safety classification, so
  the extra per-action model call is never made. The tool set stays scoped;
  nothing outside it is auto-approved.
- **Residual:** none for the scoped tool set; this is a structural mismatch
  (model-graded permissioning assumes a fast model) that pre-approval side-
  steps cleanly.

### 6. Standard harness behaviours that punish weak models

- **Read-before-write:** Claude Code refuses to `Write`/`Edit` an existing
  file until it has been `Read`. Standard, correct behaviour — but a weak
  model *flails* against it (`ls` instead of `Read`) instead of recovering.
  Not a bug; mitigated by deleting stale artifacts / fresh paths / a
  stronger model. Worth knowing because the *symptom* ("Error writing
  file") looks like an infrastructure failure and is not.
- **"Prompt caching disabled" banner:** benign. The local server does not
  implement server-side prompt caching; the warning assumes the hosted API.
  No token cost applies locally. Cosmetic.

---

## The fundamental limit (what no amount of plumbing fixes)

After truncation, channel-destruction, OOM, the runtime crash, and the
classifier are all solved, the remaining wall is **a weak, quantized local
model reliably emitting valid structured output (JSON tool calls) for large,
complex actions**. This is a capability limit, not an engineering one. The
honest engineering response is: fail *loudly* (not silently), pre-empt where
possible, and otherwise let the agent adapt (chunk the work) or use a
stronger model. Pretending the server can reconstruct arbitrary malformed
model output would be over-engineering a brittle thing.

---

## Scaling: does this hold up on larger memory / a bigger model?

Nothing here is hardcoded to a constrained machine:

- **Auto-adapts:** the memory pre-flight is RAM-relative and simply stays
  silent when there is headroom; OOM largely disappears with room for the
  KV cache; the fork fixes and the dependency pin are memory-independent
  correctness fixes that always apply.
- **Does *not* auto-scale:** the output-token cap is an explicit, deliberately
  conservative default — more RAM does not raise it. On a large-memory
  machine you *can* safely raise it (`--out-tokens`), which removes most
  truncation, *because* the headroom makes a big output budget non-fatal.
- **The biggest lever is the model, not the RAM.** Large memory's real value
  is that it lets you run a *stronger* model, which produces valid JSON for
  big tool calls and recovers from standard guards without flailing — that
  is what dissolves the fundamental limit above. RAM is the enabler, not the
  cure.

---

## Summary of improvements

| Area | Improvement |
|---|---|
| Visibility | Live model-download progress; stall-based (not blind) readiness timeout; rotated `server.log` for post-mortems |
| Memory | GPU-budget-aware pre-flight; interactive shrink / GPU-limit raise; `--safe`; session-scoped, auto-reverted `sudo` change |
| Tool calls | Tunable output budget (`--out-tokens`); fork tool-call-span-safe channel cleaning; opt-in fail-loud truncation notice; proactive write-in-parts guidance |
| Runtime | Pinned, reproducible ML dependency stack; documented plan to lift the pin |
| Permissions | Pre-allowed scoped tool set so auto mode needs no slow classifier call |
| Honesty | Silent failures converted to explicit, actionable signals; limitations documented rather than papered over |

## Takeaway

Every fix above exists because a layer failed *silently* and looked like a
different layer's fault. Making a cloud-grade agent usable on a local LLM is
less about one clever change and more about (a) making every failure loud
and diagnosable, (b) right-sizing budgets to the hardware, (c) pinning a
fragile runtime, and (d) being honest about the model-capability ceiling
instead of engineering around it. That is the actual cost of "local Claude
Code", and it is mostly invisible until you hit each wall in turn.
