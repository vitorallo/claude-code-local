#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_CONFIG="$SCRIPT_DIR/mcp-local.json"
HF_CACHE="$HOME/.cache/huggingface/hub"

# =============================================================================
# Model catalog (single source of truth)
# =============================================================================
# Parallel arrays: flag / huggingface id / display name / size / description
MODEL_FLAGS=(
    "gemma-light"
    "gemma"
    "review"
    "coder"
    "qwen3"
    "coder7b"
)
MODEL_IDS=(
    "mlx-community/gemma-4-e4b-it-4bit"
    "mlx-community/gemma-4-26b-a4b-it-4bit"
    "mlx-community/GLM-4.7-Flash-4bit"
    "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
    "mlx-community/Qwen3.5-9B-MLX-4bit"
    "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
)
MODEL_NAMES=(
    "Gemma-4-E4B"
    "Gemma-4-26B-A4B MoE"
    "GLM-4.7-Flash"
    "Qwen3-Coder-30B-A3B"
    "Qwen3.5-9B"
    "Qwen2.5-Coder-7B"
)
MODEL_SIZES=(
    "5GB"
    "16GB"
    "17GB"
    "18GB"
    "5GB"
    "5GB"
)
MODEL_DESCS=(
    "Default, clean tool calling — 16GB+ RAM"
    "Google MoE, 3.8B active — 24GB+ RAM"
    "Stronger reasoning — 24GB+ RAM"
    "Heavier code model — 24GB+ RAM"
    "General reasoning — verbose thinking leak"
    "Code analysis — tool calls unreliable"
)

# =============================================================================
# Colors (TTY-aware)
# =============================================================================
if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'; REVERSE=$'\e[7m'
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RED=$'\e[31m'
    BLUE=$'\e[34m'
else
    BOLD=""; DIM=""; RESET=""; REVERSE=""
    GREEN=""; YELLOW=""; CYAN=""; RED=""
    BLUE=""
fi

# =============================================================================
# Helpers
# =============================================================================

is_cached() {
    local cache_name="models--${1//\//--}"
    [[ -d "$HF_CACHE/$cache_name" ]]
}

# cache_name_to_model_id: HF dir name -> HuggingFace model id (pure bash, no forks)
# e.g. "models--mlx-community--Qwen3.5-9B-MLX-4bit" -> "mlx-community/Qwen3.5-9B-MLX-4bit"
cache_name_to_model_id() {
    local name="${1##*/}"
    name="${name#models--}"
    echo "${name//--//}"
}

# Find catalog index by flag name. Prints index or empty.
find_by_flag() {
    local flag="$1" i
    for i in "${!MODEL_FLAGS[@]}"; do
        if [[ "${MODEL_FLAGS[$i]}" == "$flag" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

# TUI enter/leave: hide cursor + clear, then restore cursor.
tui_enter() { tput civis 2>/dev/null || true; clear 2>/dev/null || printf '\n\n'; }
tui_leave() { tput cnorm 2>/dev/null || true; clear 2>/dev/null || printf '\n'; }

print_header() {
    printf "\n${BOLD}${BLUE}╭────────────────────────────────────────────────╮${RESET}\n"
    printf "${BOLD}${BLUE}│${RESET}  ${BOLD}Claude Code Local${RESET} ${DIM}— vllm-mlx on Apple Silicon${RESET}  ${BOLD}${BLUE}│${RESET}\n"
    printf "${BOLD}${BLUE}╰────────────────────────────────────────────────╯${RESET}\n\n"
}

# =============================================================================
# Screens
# =============================================================================

# Reads MODEL_CACHED[] precomputed by interactive_menu.
render_model_menu() {
    local selected=$1
    tput cup 0 0 2>/dev/null || true
    print_header
    printf "  ${DIM}↑↓ navigate   Enter to select   q to quit${RESET}\n\n"
    printf "       ${DIM}%-22s %5s %-14s %s${RESET}\n" "Model" "Size" "Flag" "Notes"
    printf "       ${DIM}──────────────────────────────────────────────────────────────${RESET}\n"

    local i mark line
    for i in "${!MODEL_FLAGS[@]}"; do
        if [[ "${MODEL_CACHED[$i]}" == "1" ]]; then
            mark="${GREEN}●${RESET}"
        else
            mark="${DIM}○${RESET}"
        fi
        printf -v line "%s %2d) %-22s %5s  --%-12s %s" \
            "$mark" "$((i + 1))" "${MODEL_NAMES[$i]}" "${MODEL_SIZES[$i]}" \
            "${MODEL_FLAGS[$i]}" "${MODEL_DESCS[$i]}"
        if [[ $i -eq $selected ]]; then
            printf "  ${REVERSE}${BOLD} ▸ %s ${RESET}\n" "$line"
        else
            printf "     ${DIM}%s${RESET}\n" "$line"
        fi
    done

    printf "\n  ${GREEN}●${RESET} ${DIM}downloaded${RESET}   ${DIM}○ not downloaded${RESET}\n\n"
    printf "  ${BOLD}${CYAN}m${RESET}) Manage cache   ${BOLD}${CYAN}l${RESET}) List cache   ${BOLD}${CYAN}q${RESET}) Quit\n"
    tput ed 2>/dev/null || true
}

# Read a single key (handles escape sequences for arrow keys).
# Integer -t timeouts keep this compatible with macOS bash 3.2 (no fractional -t).
# Standalone Esc resolves after a ~1s delay; 'q' quits instantly.
read_key() {
    local key c2 c3
    IFS= read -rsn1 key 2>/dev/null || return 1
    if [[ "$key" == $'\e' ]]; then
        IFS= read -rsn1 -t 1 c2 2>/dev/null || { echo "ESC"; return 0; }
        IFS= read -rsn1 -t 1 c3 2>/dev/null || { echo "ESC"; return 0; }
        case "${c2}${c3}" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[H'|'OH') echo "HOME" ;;
            '[F'|'OF') echo "END" ;;
            *)    echo "ESC" ;;
        esac
    elif [[ -z "$key" ]]; then
        echo "ENTER"
    else
        echo "$key"
    fi
}

interactive_menu() {
    local selected=0
    local n=${#MODEL_FLAGS[@]}
    local i

    # Precompute cache state so render_model_menu doesn't stat the FS per keypress.
    MODEL_CACHED=()
    for i in "${!MODEL_IDS[@]}"; do
        if is_cached "${MODEL_IDS[$i]}"; then
            MODEL_CACHED+=("1")
        else
            MODEL_CACHED+=("0")
        fi
    done

    tui_enter
    trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM

    while true; do
        render_model_menu "$selected"
        local key
        key=$(read_key) || key="q"

        case "$key" in
            UP|k)
                selected=$((selected - 1))
                [[ $selected -lt 0 ]] && selected=$((n - 1))
                ;;
            DOWN|j)
                selected=$((selected + 1))
                [[ $selected -ge $n ]] && selected=0
                ;;
            HOME|g)  selected=0 ;;
            END|G)   selected=$((n - 1)) ;;
            ENTER|RIGHT)
                MODEL="${MODEL_IDS[$selected]}"
                MODEL_NAME_DISPLAY="${MODEL_NAMES[$selected]}"
                tui_leave
                return 0
                ;;
            [1-9])
                local idx=$((key - 1))
                if [[ $idx -ge 0 && $idx -lt $n ]]; then
                    MODEL="${MODEL_IDS[$idx]}"
                    MODEL_NAME_DISPLAY="${MODEL_NAMES[$idx]}"
                    tui_leave
                    return 0
                fi
                ;;
            q|Q|ESC)
                tui_leave
                echo "Bye."
                exit 0
                ;;
            m|M)
                tput cnorm 2>/dev/null || true
                manage_cached_models
                # Cache state may have changed
                MODEL_CACHED=()
                for i in "${!MODEL_IDS[@]}"; do
                    if is_cached "${MODEL_IDS[$i]}"; then
                        MODEL_CACHED+=("1")
                    else
                        MODEL_CACHED+=("0")
                    fi
                done
                tui_enter
                ;;
            l|L)
                tput cnorm 2>/dev/null || true
                clear 2>/dev/null || printf '\n'
                print_header
                list_cached_all
                echo ""
                read -rp "  Press Enter to return..." _
                tui_enter
                ;;
        esac
    done
}

# Format a size in KB into a human-readable string (e.g. "4.9G", "12M", "512K").
_format_kb() {
    local kb=$1
    if   (( kb >= 1048576 )); then awk -v k="$kb" 'BEGIN{printf "%.1fG", k/1048576}'
    elif (( kb >= 1024 ));    then awk -v k="$kb" 'BEGIN{printf "%.0fM",  k/1024}'
    else                           echo "${kb}K"
    fi
}

# Populate CACHED_DIRS / CACHED_NAMES / CACHED_KB with the models currently
# on disk. Runs a single `du -sk` over the whole cache (one tree walk).
scan_cache() {
    CACHED_DIRS=()
    CACHED_NAMES=()
    CACHED_KB=()
    [[ -d "$HF_CACHE" ]] || return 0

    shopt -s nullglob
    local dirs=("$HF_CACHE"/models--*)
    shopt -u nullglob
    [[ ${#dirs[@]} -eq 0 ]] && return 0

    # One du invocation for all entries — much cheaper than 6 separate calls.
    local line kb dir
    while IFS=$'\t' read -r kb dir; do
        [[ -d "$dir" ]] || continue
        CACHED_DIRS+=("$dir")
        CACHED_NAMES+=("$(cache_name_to_model_id "$dir")")
        CACHED_KB+=("$kb")
    done < <(du -sk "${dirs[@]}" 2>/dev/null)
}

list_cached_all() {
    printf "${BOLD}Cached models on disk${RESET}\n"
    printf "${DIM}%s${RESET}\n\n" "$HF_CACHE"

    scan_cache
    local total=${#CACHED_DIRS[@]}
    if [[ $total -eq 0 ]]; then
        printf "  ${DIM}No cached models.${RESET}\n"
        return 0
    fi

    local i name size in_catalog j sum_kb=0
    for i in "${!CACHED_DIRS[@]}"; do
        name="${CACHED_NAMES[$i]}"
        size=$(_format_kb "${CACHED_KB[$i]}")
        sum_kb=$((sum_kb + CACHED_KB[i]))
        in_catalog=""
        for j in "${!MODEL_IDS[@]}"; do
            if [[ "${MODEL_IDS[$j]}" == "$name" ]]; then
                in_catalog=" ${DIM}(--${MODEL_FLAGS[$j]})${RESET}"
                break
            fi
        done
        printf "  %2d  ${BOLD}%-55s${RESET} %6s%s\n" \
            "$((i + 1))" "$name" "$size" "$in_catalog"
    done

    printf "\n  ${DIM}Total cache size: %s${RESET}\n" "$(_format_kb "$sum_kb")"
}

manage_cached_models() {
    while true; do
        clear 2>/dev/null || printf '\n\n'
        print_header
        list_cached_all  # populates CACHED_DIRS / CACHED_NAMES / CACHED_KB
        printf "\n  ${BOLD}${CYAN}<num>${RESET}) Delete a cached model by number\n"
        printf "  ${BOLD}${CYAN}a${RESET})     Delete ALL cached models\n"
        printf "  ${BOLD}${CYAN}b${RESET})     Back to main menu\n"
        printf "  ${BOLD}${CYAN}q${RESET})     Quit\n\n"

        local choice
        read -rp "  Choice: " choice

        case "$choice" in
            q|Q) exit 0 ;;
            b|B|"") return 0 ;;
            a|A)
                read -rp "  ${RED}Delete ALL cached models? [y/N]:${RESET} " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    rm -rf "$HF_CACHE"/models--*
                    printf "  ${GREEN}All cached models deleted.${RESET}\n"
                    sleep 1
                fi
                ;;
            [1-9]|[1-9][0-9])
                local idx=$((choice - 1))
                if [[ $idx -lt 0 || $idx -ge ${#CACHED_DIRS[@]} ]]; then
                    printf "  ${RED}Invalid number.${RESET}\n"
                    sleep 1
                    continue
                fi
                local name="${CACHED_NAMES[$idx]}"
                local size
                size=$(_format_kb "${CACHED_KB[$idx]}")
                read -rp "  Delete ${BOLD}$name${RESET} ($size)? [y/N]: " confirm
                if [[ "$confirm" =~ ^[yY]$ ]]; then
                    rm -rf "${CACHED_DIRS[$idx]}"
                    printf "  ${GREEN}Deleted.${RESET}\n"
                    sleep 1
                fi
                ;;
            *)
                printf "  ${RED}Invalid input.${RESET}\n"
                sleep 1
                ;;
        esac
    done
}

show_help() {
    cat <<EOF
${BOLD}Usage:${RESET} cclocal [OPTIONS]

Without any model flag, cclocal opens an interactive menu to select a model,
show cached models, and manage the cache. Model flags bypass the menu.

${BOLD}Model flags${RESET}
  --gemma-light   Gemma-4-E4B (~5GB, default, clean tool calling)
  --gemma         Gemma-4-26B-A4B MoE (~16GB)
  --review        GLM-4.7-Flash (~17GB)
  --coder         Qwen3-Coder-30B-A3B (~18GB)
  --qwen3         Qwen3.5-9B (~5GB, general reasoning, thinking leak)
  --coder7b       Qwen2.5-Coder-7B (~5GB, tool calls unreliable)
  --light         Alias for --gemma-light (back-compat with v2.0.1)
  --model ID      Use a custom HuggingFace MLX model ID

${BOLD}Commands${RESET}
  --list, -l      List cached models and exit
  --rm            Manage cached models (interactive)
  --clean         Alias for --rm

${BOLD}Server options${RESET}
  --server        Start vllm-mlx server only (don't launch Claude Code)
  --port N        Server port (default: 8000)

${BOLD}Other${RESET}
  -h, --help      Show this help

${BOLD}Examples${RESET}
  cclocal                  ${DIM}# interactive menu${RESET}
  cclocal --gemma-light    ${DIM}# direct launch, Gemma-4-E4B (default)${RESET}
  cclocal --gemma          ${DIM}# direct launch, Gemma-4-26B MoE${RESET}
  cclocal --list           ${DIM}# show cached models${RESET}
  cclocal --rm             ${DIM}# manage/delete cached models${RESET}
  cclocal --server         ${DIM}# server only, connect Claude Code later${RESET}
EOF
}

# =============================================================================
# Argument parsing
# =============================================================================
MODEL=""
MODEL_NAME_DISPLAY=""
PORT=8000
SERVER_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coder7b|--review|--coder|--gemma|--gemma-light|--qwen3)
            idx=$(find_by_flag "${1#--}")
            MODEL="${MODEL_IDS[$idx]}"
            MODEL_NAME_DISPLAY="${MODEL_NAMES[$idx]}"
            shift
            ;;
        --light)
            # Backward-compat alias: v2.0.1 default was Qwen3.5-9B which leaks
            # plain-text thinking. v2.0.2 default is Gemma-4-E4B — clean tool
            # calling via the fork's gemma4_tool_parser + channel-cleanup
            # patches.
            idx=$(find_by_flag "gemma-light")
            MODEL="${MODEL_IDS[$idx]}"
            MODEL_NAME_DISPLAY="${MODEL_NAMES[$idx]}"
            shift
            ;;
        --model)
            MODEL="$2"
            MODEL_NAME_DISPLAY="$2"
            shift 2
            ;;
        --port)    PORT="$2"; shift 2 ;;
        --server)  SERVER_ONLY=true; shift ;;
        --list|-l)
            print_header
            list_cached_all
            echo ""
            exit 0
            ;;
        --rm|--clean)
            manage_cached_models
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            printf "${RED}Unknown option: $1${RESET}\n"
            echo "Run 'cclocal --help' for usage."
            exit 1
            ;;
    esac
done

# No model flag given — show interactive menu
if [[ -z "$MODEL" ]]; then
    interactive_menu
fi

# =============================================================================
# Pre-flight checks
# =============================================================================
VLLM_BIN="$SCRIPT_DIR/.venv/bin/vllm-mlx"
if [[ ! -x "$VLLM_BIN" ]]; then
    echo "${RED}ERROR: vllm-mlx not found in .venv. Run ./install.sh first.${RESET}"
    exit 1
fi
if ! command -v claude &>/dev/null; then
    printf "${RED}ERROR: Claude Code CLI not found. Install it first:${RESET}\n"
    echo "  https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

# =============================================================================
# Launch
# =============================================================================
print_header
printf "  ${BOLD}Model:${RESET}  ${MODEL_NAME_DISPLAY:-$MODEL}\n"
printf "  ${DIM}ID:     $MODEL${RESET}\n"
printf "  ${BOLD}Port:${RESET}   $PORT\n"
if ! is_cached "$MODEL"; then
    printf "  ${YELLOW}Note:${RESET}   model not cached — first run will download\n"
fi
echo ""

# Kill any existing process on the port
existing_pid=$(lsof -ti:"$PORT" 2>/dev/null || true)
if [[ -n "$existing_pid" ]]; then
    echo "Stopping existing process on port $PORT (pid: $existing_pid)..."
    kill $existing_pid 2>/dev/null || true
    sleep 2
    kill -0 $existing_pid 2>/dev/null && kill -9 $existing_pid 2>/dev/null || true
fi

# Start vllm-mlx server in background
LOG_FILE="$SCRIPT_DIR/server.log"
printf "${DIM}Starting vllm-mlx server (logs: $LOG_FILE)...${RESET}\n"

# CLAUDE_CODE_MAX_OUTPUT_TOKENS — per-request output cap sent by Claude Code.
# Distinct from vllm-mlx's `--max-tokens` flag below (which is the server-side
# context window default). Small models get a generous output; large models
# get a smaller cap to avoid OOM under memory pressure.
CC_OUTPUT_TOKENS="4096"
case "$MODEL" in
    *Coder-7B*|*Coder-3B*|*e4b*|*e2b*|*9B*|*3B*)
        CC_OUTPUT_TOKENS="16384"
        ;;
esac

# Environment variables passed to Claude Code. Kept as a single array so the
# --server print-out and the in-process launch cannot drift apart.
CLAUDE_ENV=(
    "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT"
    "ANTHROPIC_API_KEY=not-needed"
    "ANTHROPIC_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_OPUS_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_SONNET_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_HAIKU_MODEL=$MODEL"
    "CLAUDE_CODE_SUBAGENT_MODEL=$MODEL"
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS=$CC_OUTPUT_TOKENS"
    "CLAUDE_CODE_ATTRIBUTION_HEADER=0"
    "DISABLE_PROMPT_CACHING=1"
    "DISABLE_AUTOUPDATER=1"
    "DISABLE_TELEMETRY=1"
    "DISABLE_ERROR_REPORTING=1"
    "DISABLE_NON_ESSENTIAL_MODEL_CALLS=1"
)
CLAUDE_FLAGS=(
    --strict-mcp-config
    --mcp-config "$MCP_CONFIG"
    --tools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
)

# Disable thinking/reasoning tokens — Claude Code can't handle them
# KV cache quantization halves cache memory — longer conversations before OOM
# 35% RAM to cache (~8.4GB on 24GB) vs default 20%
# Larger prefill chunks for faster time-to-first-token
# Batch 4 tokens before streaming for better throughput
# 600s timeout — default 300s was causing disconnects on long generations
# Auto tool parser — parses Gemma 4, Qwen, Mistral, Llama, Nemotron formats
#                    into structured tool_use blocks (required for Gemma 4)
VLLM_MLX_ENABLE_THINKING=false \
"$VLLM_BIN" serve "$MODEL" \
    --port "$PORT" \
    --max-tokens 32768 \
    --kv-cache-quantization \
    --cache-memory-percent 0.35 \
    --prefill-step-size 4096 \
    --stream-interval 4 \
    --timeout 600 \
    --enable-auto-tool-choice \
    --tool-call-parser auto \
    > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

# Cleanup on exit
cleanup() {
    echo ""
    printf "${DIM}Shutting down vllm-mlx server (pid: $SERVER_PID)...${RESET}\n"
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    printf "${DIM}Done.${RESET}\n"
}
trap cleanup EXIT

# Wait for server to be ready
printf "${DIM}Waiting for server...${RESET}"
for i in $(seq 1 180); do
    if curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q "healthy"; then
        printf " ${GREEN}ready${RESET} ${DIM}(${i}s)${RESET}\n"
        break
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        printf " ${RED}failed${RESET}\n"
        echo "Server process died. Check: tail $LOG_FILE"
        exit 1
    fi
    if [[ $i -eq 180 ]]; then
        printf " ${RED}timeout${RESET}\n"
        echo "Server did not become ready in 180s."
        exit 1
    fi
    sleep 1
done

if [[ "$SERVER_ONLY" == true ]]; then
    echo ""
    printf "${BOLD}Server running at http://127.0.0.1:$PORT${RESET}\n"
    echo "Connect Claude Code from any terminal with:"
    echo ""
    echo "  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \\"
    for var in "${CLAUDE_ENV[@]}"; do
        echo "    $var \\"
    done
    echo "    claude ${CLAUDE_FLAGS[*]}"
    echo ""
    echo "Press Ctrl+C to stop."
    wait $SERVER_PID
else
    echo ""
    printf "${DIM}Launching Claude Code...${RESET}\n\n"

    # Env vars scoped to this process only — nothing touches ~/.claude/settings.json.
    # -u flags unset any real API keys from the parent shell so they don't leak through.
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "${CLAUDE_ENV[@]}" \
        claude "${CLAUDE_FLAGS[@]}"
fi
