#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "=== claude-code-local setup ==="
echo ""

# Pre-flight checks
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "ERROR: This tool requires Apple Silicon (arm64). Detected: $(uname -m)"
    exit 1
fi
if ! command -v claude &>/dev/null; then
    echo "ERROR: Claude Code CLI not found. Install it first:"
    echo "  https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

# 1. Check/install uv
echo "[1/3] Checking uv..."
if ! command -v uv &>/dev/null; then
    echo "  Installing uv via brew..."
    if ! command -v brew &>/dev/null; then
        echo "ERROR: brew not found. Install Homebrew first: https://brew.sh"
        exit 1
    fi
    brew install uv
fi
echo "  uv: $(uv --version)"

# 2. Create venv and install vllm-mlx
# Using the vitorallo/vllm-mlx fork, branch feat/claude-code-local-0.4.1: a
# fresh branch off upstream v0.4.1 carrying only three patches that are still
# absent upstream —
# - POST /v1/reset (deep cache reset) and health.memory_warning
# - opt-in --tool-call-truncation-notice: when a tool call is cut off by
#   max_tokens, return "write it in parts" instead of a silent HTTP 200 or an
#   unrunnable argument-less tool call (see README #18)
# - qwen3_xml / qwen3.5 exposed in --tool-call-parser choices
#
# The old branch was 354 commits behind upstream and hard-pinned
# mlx==0.31.1 / mlx-lm==0.31.1 to dodge the "no Stream(gpu, N) in current
# thread" crash. That was upstream issue #407, fixed in PR #452, so the pins
# are gone and the MLX stack floats again (mlx 0.32.x, mlx-lm 0.31.3+,
# mlx-vlm 0.6.x) — which is what makes Qwen3.8 loadable.
#
# Four Gemma-4 channel-cleaning patches were deliberately NOT carried over:
# upstream 0.4.1 handles Gemma 4 tool calls with a real gemma4_tool_parser.py
# rather than text cleaning. If Gemma 4 regresses, they are still on the old
# branch below.
#
# NOTE: if another project on this machine consumes the same fork, it will do
# so through its own pin (submodule or its own venv). Changing the branch here
# does not touch it.
#
# To roll back, swap the line below for either:
# VLLM_MLX_REPO="git+https://github.com/vitorallo/vllm-mlx.git@fix/gemma4-toolcall-safe-and-faildloud"  # pre-0.4.1, mlx pinned
# VLLM_MLX_REPO="git+https://github.com/vitorallo/vllm-mlx.git@claude-code-local-patches"               # older still
VLLM_MLX_REPO="git+https://github.com/vitorallo/vllm-mlx.git@feat/claude-code-local-0.4.1"
echo ""
echo "[2/3] Installing vllm-mlx into local venv..."
if [[ -d "$VENV_DIR" ]]; then
    echo "  Upgrading existing venv..."
    uv pip install --python "$VENV_DIR/bin/python3" --upgrade --force-reinstall "$VLLM_MLX_REPO"
else
    echo "  Creating venv..."
    uv venv "$VENV_DIR"
    uv pip install --python "$VENV_DIR/bin/python3" "$VLLM_MLX_REPO"
fi
if [[ -x "$VENV_DIR/bin/vllm-mlx" ]]; then
    echo "  vllm-mlx installed: $VENV_DIR/bin/vllm-mlx"
    MLXLM_VER=$("$VENV_DIR/bin/python3" -c "import mlx_lm; print(mlx_lm.__version__)" 2>/dev/null || echo "unknown")
    MLX_VER=$("$VENV_DIR/bin/python3" -c "import mlx.core as mx; print(mx.__version__)" 2>/dev/null || echo "unknown")
    MLXVLM_VER=$("$VENV_DIR/bin/python3" -c "import mlx_vlm; print(mlx_vlm.__version__)" 2>/dev/null || echo "unknown")
    echo "  mlx: $MLX_VER  |  mlx-lm: $MLXLM_VER  |  mlx-vlm: $MLXVLM_VER"
else
    echo "  ERROR: vllm-mlx binary not found in venv."
    exit 1
fi

# 3. Create cclocal symlink
echo ""
echo "[3/3] Creating cclocal command..."
mkdir -p ~/.local/bin
ln -sf "$SCRIPT_DIR/run.sh" ~/.local/bin/cclocal
echo "  Symlinked: ~/.local/bin/cclocal -> $SCRIPT_DIR/run.sh"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
    echo ""
    echo "  NOTE: ~/.local/bin is not in your PATH. Add it with:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "  Or just run ./run.sh directly from this directory."
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Quick start:"
echo "  cclocal               # Interactive menu"
echo "  cclocal --qwen38      # Qwen3.8-27B (~16GB, best quality, needs 24GB)"
echo "  cclocal --gemma-light # Gemma-4-E4B (~5GB, light default, clean tool calling)"
echo "  cclocal --server      # Server only, connect Claude Code separately"
echo "  cclocal --clean       # List and delete cached models"
echo "  cclocal -h            # All models and flags"
echo ""
echo "On a 24GB Mac, --qwen38 will offer to raise the GPU memory limit at"
echo "startup. Take it (option 2 or 3) — 16GB of weights against the ~19GB"
echo "default budget leaves very little room for the context cache."
echo ""
echo "Or run directly: ./run.sh"
