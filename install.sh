#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
echo "[1/4] Checking uv..."
if ! command -v uv &>/dev/null; then
    echo "  Installing uv via brew..."
    if ! command -v brew &>/dev/null; then
        echo "ERROR: brew not found. Install Homebrew first: https://brew.sh"
        exit 1
    fi
    brew install uv
fi
echo "  uv: $(uv --version)"

# 2. Install vllm-mlx
echo ""
echo "[2/4] Installing vllm-mlx..."
uv tool install git+https://github.com/waybarrios/vllm-mlx.git || {
    echo "  Trying upgrade instead..."
    uv tool upgrade vllm-mlx || true
}
echo "  Verifying installation..."
if command -v vllm-mlx &>/dev/null; then
    echo "  vllm-mlx installed successfully"
else
    echo "  WARNING: vllm-mlx not found in PATH. You may need to restart your shell."
fi

# 3. Patch vllm-mlx bug (missing return statement in load_model_with_fallback)
# See vllm-mlx-bug-report.md for details. This checks before patching — skip if already fixed.
echo ""
echo "[3/4] Checking vllm-mlx for known bugs..."
VLLM_BIN=$(which vllm-mlx 2>/dev/null || true)
if [[ -n "$VLLM_BIN" ]]; then
    # Resolve the actual package directory from the binary's symlink/shim
    VLLM_PKG_DIR=$(python3 -c "import importlib.util; spec = importlib.util.find_spec('vllm_mlx'); print(spec.submodule_search_locations[0] if spec else '')" 2>/dev/null || true)
fi
TOKENIZER_PY=""
if [[ -n "${VLLM_PKG_DIR:-}" && -d "$VLLM_PKG_DIR" ]]; then
    TOKENIZER_PY=$(find "$VLLM_PKG_DIR" -name "tokenizer.py" -path "*/utils/tokenizer.py" 2>/dev/null | head -1)
fi
# Fallback to default uv tools location
if [[ -z "$TOKENIZER_PY" ]]; then
    TOKENIZER_PY=$(find ~/.local/share/uv/tools/vllm-mlx -name "tokenizer.py" -path "*/utils/tokenizer.py" 2>/dev/null | head -1)
fi
if [[ -n "$TOKENIZER_PY" ]]; then
    # Check if the bug exists: load() succeeds but no return statement follows
    if grep -A1 'model, tokenizer = load(model_name' "$TOKENIZER_PY" | grep -q 'return model, tokenizer'; then
        echo "  vllm-mlx tokenizer.py already patched (or fixed upstream)"
    else
        echo "  Applying patch: missing 'return model, tokenizer' in load_model_with_fallback()"
        sed -i.bak 's/\(        model, tokenizer = load(model_name, tokenizer_config=tokenizer_config)\)/\1\n        return model, tokenizer/' "$TOKENIZER_PY"
        rm -f "${TOKENIZER_PY}.bak"
        # Verify the patch applied
        if grep -A1 'model, tokenizer = load(model_name' "$TOKENIZER_PY" | grep -q 'return model, tokenizer'; then
            echo "  Patched successfully. See vllm-mlx-bug-report.md for details."
        else
            echo "  WARNING: Patch may not have applied correctly."
            echo "  If vllm-mlx crashes on startup, apply manually. See vllm-mlx-bug-report.md."
        fi
    fi
else
    echo "  WARNING: Could not find vllm-mlx tokenizer.py to check for bugs."
    echo "  If vllm-mlx crashes on startup, see vllm-mlx-bug-report.md for the fix."
fi

# 4. Create cclocal symlink
echo ""
echo "[4/4] Creating cclocal command..."
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
echo "  cclocal              # Qwen3.5-9B (~5GB, default, proven working)"
echo "  cclocal --review     # GLM-4.7-Flash (~16.9GB, stronger reasoning)"
echo "  cclocal --coder      # Qwen3-Coder-30B-A3B (~17.5GB, code generation)"
echo "  cclocal --server     # Server only, connect Claude Code separately"
echo "  cclocal --clean      # List and delete cached models"
echo ""
echo "Or run directly: ./run.sh"
