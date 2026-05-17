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
# Using vitorallo/vllm-mlx fork. Pinned to the fix/gemma4-toolcall-safe-and-faildloud
# branch (built on claude-code-local-patches) which adds, on top of the base:
# - All foil-patches-rebased patches (memory warning, /v1/reset, Qwen thinking strip)
# - Gemma 4 asymmetric channel token stripping (for VLLM_MLX_ENABLE_THINKING=false)
# - Tool-call-span-safe channel cleaning (D1/D2) + opt-in
#   --tool-call-truncation-notice (see README #18)
# claude-code-local-patches itself is intentionally left untouched so other
# downstream consumers are unaffected until/if this branch is merged there.
#
# To manually roll back to the base branch, swap the line below for:
# VLLM_MLX_REPO="git+https://github.com/vitorallo/vllm-mlx.git@claude-code-local-patches"
VLLM_MLX_REPO="git+https://github.com/vitorallo/vllm-mlx.git@fix/gemma4-toolcall-safe-and-faildloud"
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
    echo "  mlx-lm version: $MLXLM_VER"
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
echo "  cclocal              # Interactive menu"
echo "  cclocal --gemma-light # Gemma-4-E4B (~5GB, default, clean tool calling)"
echo "  cclocal --gemma      # Gemma-4-26B-A4B MoE (~16GB)"
echo "  cclocal --review     # GLM-4.7-Flash (~17GB, stronger reasoning)"
echo "  cclocal --server     # Server only, connect Claude Code separately"
echo "  cclocal --clean      # List and delete cached models"
echo ""
echo "Or run directly: ./run.sh"
