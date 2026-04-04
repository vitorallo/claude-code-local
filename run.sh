#!/bin/bash
set -euo pipefail

# Models
MODEL_LIGHT="mlx-community/Qwen3.5-9B-MLX-4bit"
MODEL_REVIEW="mlx-community/GLM-4.7-Flash-4bit"
MODEL_CODER="mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
MODEL_35B="mlx-community/Qwen3.5-35B-A3B-4bit"
MODEL="$MODEL_LIGHT"
PORT=8000
SERVER_ONLY=false
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_CONFIG="$SCRIPT_DIR/mcp-local.json"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --light)   MODEL="$MODEL_LIGHT"; shift ;;
        --review)  MODEL="$MODEL_REVIEW"; shift ;;
        --coder)   MODEL="$MODEL_CODER"; shift ;;
        --35b)     MODEL="$MODEL_35B"; shift ;;
        --model)   MODEL="$2"; shift 2 ;;
        --port)    PORT="$2"; shift 2 ;;
        --server)  SERVER_ONLY=true; shift ;;
        --clean)
            HF_CACHE="$HOME/.cache/huggingface/hub"
            echo "=== Cached models in $HF_CACHE ==="
            echo ""
            total=0
            for dir in "$HF_CACHE"/models--*; do
                [[ -d "$dir" ]] || continue
                name=$(basename "$dir" | sed 's/^models--//' | sed 's/--/\//g')
                size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                total=$((total + 1))
                echo "  [$total] $name ($size)"
            done
            if [[ $total -eq 0 ]]; then
                echo "  No cached models found."
                exit 0
            fi
            echo ""
            echo "  [a] Delete ALL cached models"
            echo "  [q] Cancel"
            echo ""
            read -rp "Delete which? [1-$total/a/q]: " choice
            case "$choice" in
                q|Q|"") echo "Cancelled."; exit 0 ;;
                a|A)
                    read -rp "Delete ALL cached models? [y/N]: " confirm
                    if [[ "$confirm" =~ ^[yY]$ ]]; then
                        rm -rf "$HF_CACHE"/models--*
                        echo "All cached models deleted."
                    else
                        echo "Cancelled."
                    fi
                    ;;
                *)
                    i=0
                    for dir in "$HF_CACHE"/models--*; do
                        [[ -d "$dir" ]] || continue
                        i=$((i + 1))
                        if [[ "$i" -eq "$choice" ]]; then
                            name=$(basename "$dir" | sed 's/^models--//' | sed 's/--/\//g')
                            size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                            read -rp "Delete $name ($size)? [y/N]: " confirm
                            if [[ "$confirm" =~ ^[yY]$ ]]; then
                                rm -rf "$dir"
                                echo "Deleted."
                            else
                                echo "Cancelled."
                            fi
                            break
                        fi
                    done
                    ;;
            esac
            exit 0
            ;;
        -h|--help)
            echo "Usage: run.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --light     Qwen3.5-9B (~5GB, default, proven working, huge context headroom)"
            echo "  --review    GLM-4.7-Flash (~16.9GB, stronger reasoning, tight on 24GB)"
            echo "  --coder     Qwen3-Coder-30B-A3B (~17.5GB, best for code generation + tool use)"
            echo "  --35b       Qwen3.5-35B-A3B (~22GB, smarter but tight on 24GB)"
            echo "  --model ID  Custom HuggingFace model ID"
            echo "  --port N    Server port (default: 8000)"
            echo "  --server    Start server only, don't launch Claude Code"
            echo "  --clean     List and delete cached models"
            echo "  -h, --help  Show this help"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Pre-flight checks
if ! command -v vllm-mlx &>/dev/null; then
    echo "ERROR: vllm-mlx not found. Run ./install.sh first."
    exit 1
fi
if ! command -v claude &>/dev/null; then
    echo "ERROR: Claude Code CLI not found. Install it first:"
    echo "  https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

echo "=== Local Claude Code via vllm-mlx ==="
echo "Model:  $MODEL"
echo "Port:   $PORT"
echo ""

# Kill any existing process on the port
existing_pid=$(lsof -ti:"$PORT" 2>/dev/null || true)
if [[ -n "$existing_pid" ]]; then
    echo "Killing existing process on port $PORT (pid: $existing_pid)..."
    kill $existing_pid 2>/dev/null || true
    sleep 2
    # Force kill if still alive
    kill -0 $existing_pid 2>/dev/null && kill -9 $existing_pid 2>/dev/null || true
fi

# Start vllm-mlx server in background
LOG_FILE="$SCRIPT_DIR/server.log"
echo "Starting vllm-mlx server (logs: $LOG_FILE)..."
# Tune for model size:
# - Small models (9B, 4B, 3B): large context + output (plenty of headroom)
# - Large models (GLM, 30B, 35B): small context to avoid OOM
# NOTE: continuous batching disabled — 2 concurrent 24K+ prompts OOM on 24GB Metal
MAX_TOKENS="4096"
case "$MODEL" in
    *9B*|*4B*|*3B*)
        MAX_TOKENS="16384"
        ;;
esac

vllm-mlx serve "$MODEL" \
    --port "$PORT" \
    --max-tokens 32768 \
    > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

# Cleanup on exit
cleanup() {
    echo ""
    echo "Shutting down vllm-mlx server (pid: $SERVER_PID)..."
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    echo "Done."
}
trap cleanup EXIT

# Wait for server to be ready
echo "Waiting for server to be ready..."
for i in $(seq 1 180); do
    if curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q "healthy"; then
        echo "Server ready! (took ${i}s)"
        break
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "ERROR: Server process died. Check: tail $LOG_FILE"
        exit 1
    fi
    if [[ $i -eq 180 ]]; then
        echo "ERROR: Server did not become ready in 180s."
        exit 1
    fi
    sleep 1
done

if [[ "$SERVER_ONLY" == true ]]; then
    echo ""
    echo "Server running at http://127.0.0.1:$PORT"
    echo "Connect Claude Code from any terminal with:"
    echo ""
    echo "  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \\"
    echo "    ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT \\"
    echo "    ANTHROPIC_API_KEY=not-needed \\"
    echo "    ANTHROPIC_MODEL=$MODEL \\"
    echo "    ANTHROPIC_DEFAULT_OPUS_MODEL=$MODEL \\"
    echo "    ANTHROPIC_DEFAULT_SONNET_MODEL=$MODEL \\"
    echo "    ANTHROPIC_DEFAULT_HAIKU_MODEL=$MODEL \\"
    echo "    CLAUDE_CODE_SUBAGENT_MODEL=$MODEL \\"
    echo "    CLAUDE_CODE_MAX_OUTPUT_TOKENS=${MAX_TOKENS} \\"
    echo "    CLAUDE_CODE_ATTRIBUTION_HEADER=0 \\"
    echo "    DISABLE_PROMPT_CACHING=1 \\"
    echo "    DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \\"
    echo "    claude --strict-mcp-config --mcp-config $MCP_CONFIG --tools \"Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch\""
    echo ""
    echo "Press Ctrl+C to stop."
    wait $SERVER_PID
else
    echo ""
    echo "Launching Claude Code (all env vars session-only, no global settings modified)..."
    echo ""

    # All env vars are scoped to this process only — nothing touches ~/.claude/settings.json
    # -u flags unset any real API keys from the parent shell so they don't leak through
    # --strict-mcp-config disables all plugins/MCP servers so the model only sees 8 built-in tools
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT" \
        ANTHROPIC_API_KEY="not-needed" \
        ANTHROPIC_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL" \
        ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL" \
        CLAUDE_CODE_SUBAGENT_MODEL="$MODEL" \
        CLAUDE_CODE_MAX_OUTPUT_TOKENS="${MAX_TOKENS}" \
        CLAUDE_CODE_ATTRIBUTION_HEADER="0" \
        DISABLE_PROMPT_CACHING="1" \
        DISABLE_AUTOUPDATER="1" \
        DISABLE_TELEMETRY="1" \
        DISABLE_ERROR_REPORTING="1" \
        DISABLE_NON_ESSENTIAL_MODEL_CALLS="1" \
        claude --strict-mcp-config --mcp-config "$SCRIPT_DIR/mcp-local.json" --tools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
fi
