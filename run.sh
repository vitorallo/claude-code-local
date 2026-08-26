#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_CONFIG="$SCRIPT_DIR/mcp-local.json"
HF_CACHE="$HOME/.cache/huggingface/hub"

# Remote backend presets — any box running vLLM with the native Anthropic
# Messages API (recent vLLM ships /v1/messages with real tool_use blocks).
# Edit these to match your own boxes (Tailscale addresses shown).
DGX_ACTIVE="http://100.96.179.64:8000"   # Qwen3.6-35B-A3B (MoE, faster)
DGX_IDLE="http://100.126.117.58:8000"    # Qwen3.6-27B (dense, steadier)

# LM Studio's local server. Since 0.4.1 it serves a native Anthropic
# /v1/messages endpoint (SSE + tool calls), so it works with the same remote
# plumbing as a vLLM box. Start it with `lms server start`.
LMSTUDIO_URL="http://127.0.0.1:1234"

# =============================================================================
# Model catalog (single source of truth)
# =============================================================================
# Parallel arrays: flag / huggingface id / display name / size / description
MODEL_FLAGS=(
    "qwen38"
    "deckard"
    "gemma-light"
    "gemma"
    "coder"
    "qwen3"
)
MODEL_IDS=(
    "mlx-community/Qwen3.8-27B-4bit"
    "nightmedia/Qwen3.5-9B-Claude-GBO-Fire-Deckard-Agent-Heretic-dwq4-mlx"
    "mlx-community/gemma-4-e4b-it-4bit"
    "mlx-community/gemma-4-26b-a4b-it-4bit"
    "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"
    "mlx-community/Qwen3.5-9B-MLX-4bit"
)
MODEL_NAMES=(
    "Qwen3.8-27B"
    "Qwen3.5-9B-Deckard-Agent"
    "Gemma-4-E4B"
    "Gemma-4-26B-A4B MoE"
    "Qwen3-Coder-30B-A3B"
    "Qwen3.5-9B"
)
MODEL_SIZES=(
    "16GB"
    "6GB"
    "5GB"
    "16GB"
    "18GB"
    "5GB"
)
MODEL_DESCS=(
    "Best quality, XML tool calls — 24GB RAM"
    "Agent-tuned, fast, writes real files — 16GB+ RAM"
    "Light default, clean tool calling — 16GB+ RAM"
    "Google MoE, 3.8B active — 24GB+ RAM"
    "Heavier code model — 24GB+ RAM"
    "Base Qwen3.5, verified working — 16GB+ RAM"
)
# Tool-call parser per model. Qwen 3.5 / 3.8 / 3-Coder emit XML tool calls
# (<tool_call><function=name><parameter=k>raw value</parameter></function>),
# which qwen3_xml parses natively — and which, unlike JSON arguments, needs no
# escaping of the file body, removing the truncation/escaping failure mode that
# silently dropped large Writes. "auto" sniffs the format for everything else.
MODEL_PARSERS=(
    "qwen3_xml"
    "qwen3_xml"
    "gemma4"
    "gemma4"
    "qwen3_xml"
    "qwen3_xml"
)
# Reasoning parser applied REGARDLESS of --think, for models whose thinking
# cannot be turned off. Gemma 4 ignores enable_thinking=false (gemma4-status.md
# problem 2) and emits an asymmetric <|channel>thought block. Without a parser
# that lands in the response as plain assistant text: Claude Code renders the
# model's private reasoning as its answer, and — worse — that text goes back in
# as conversation history, so the next turn continues narrating instead of
# calling a tool. That is the "it says what it will do and stops" hang.
# Measured on gemma-4-e4b: auto -> 817 chars of leaked channel text and no
# thinking block; gemma4 -> 0 leaked, 797 chars in a proper thinking block,
# same tool call and args.
MODEL_REASONING=(
    ""
    ""
    "gemma4"
    "gemma4"
    ""
    "qwen3"
)
# Per-sequence KV cache bound (--max-kv-size). Empty = engine default.
# Only worth setting where the KV cache is the binding memory constraint.
# Per-sequence KV bound (--max-kv-size), and the window reported to Claude Code
# as CLAUDE_CODE_MAX_CONTEXT_TOKENS. Every local model needs one: without it the
# cache grows unbounded until Metal OOMs, and Claude Code falls back to assuming
# a 200k window it will never actually get. 32768 for the ~14GB+ models, 65536
# for the ~5GB ones that have the headroom.
MODEL_KV_SIZES=(
    "32768"
    "65536"
    "65536"
    "32768"
    "32768"
    "65536"
)

# The eight arrays above are positional: index i of each describes one model.
# Nothing enforces that, and a drifted array fails at the worst possible time —
# `set -u` aborts with "MODEL_KV_SIZES[3]: unbound variable" only for the one
# model whose index is missing, so a short array ships silently until someone
# picks that entry. Cheap to check once at startup instead.
_check_catalog() {
    local n=${#MODEL_FLAGS[@]} name len
    for name in MODEL_IDS MODEL_NAMES MODEL_SIZES MODEL_DESCS \
                MODEL_PARSERS MODEL_REASONING MODEL_KV_SIZES; do
        eval "len=\${#${name}[@]}"
        if [[ "$len" -ne "$n" ]]; then
            echo "INTERNAL ERROR: model catalog is inconsistent." >&2
            echo "  MODEL_FLAGS has $n entries but $name has $len." >&2
            echo "  All eight MODEL_* arrays must line up by index." >&2
            exit 1
        fi
    done
}
_check_catalog

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

# =============================================================================
# Memory preflight
# =============================================================================
# Server-side context window (vllm-mlx --max-tokens). Lowered automatically /
# interactively when the chosen model leaves little RAM headroom — the KV cache
# for a large context is what OOM-crashes Metal on tight machines.
VLLM_MAX_TOKENS=32768

# Set by _raise_wired_limit to the pre-change value so cleanup() can revert it.
WIRED_RESTORE=""

_raise_wired_limit() {
    local target=$1 orig
    orig=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    printf "  Raising Metal GPU wired limit to ${target}MB ${DIM}(sudo — may prompt)${RESET}...\n"
    if sudo sysctl iogpu.wired_limit_mb="$target" >/dev/null 2>&1; then
        WIRED_RESTORE="$orig"
        printf "  ${GREEN}Set.${RESET} ${DIM}Auto-restored to ${orig} on exit (also resets on reboot).${RESET}\n"
    else
        printf "  ${RED}Could not set it${RESET} — continuing without the bump.\n"
    fi
}

# Estimate model footprint vs the Metal GPU memory budget — the real OOM
# constraint. macOS only makes ~75% of RAM GPU-addressable by default (the
# iogpu.wired_limit_mb cap), so "free RAM" overstates what's actually usable.
# If GPU headroom is tight — or --safe / CCLOCAL_FORCE_MEMCHECK forces it —
# offer two safeguards: shrink the server context and/or raise the GPU limit.
# Skips silently when CCLOCAL_NO_MEMCHECK=1 or the model size is unknown.
# Shrink the token budgets. --max-tokens caps a single generation (peak memory
# while one reply is produced); --max-kv-size caps the KV cache per sequence,
# which is the real context window — beyond it RotatingKVCache evicts the
# oldest tokens. Only --max-kv-size affects steady-state memory across a long
# agentic session, which is why shrinking --max-tokens alone was never enough.
#
# But the window has a hard floor. Claude Code's system prompt plus ~30 tool
# definitions is already several thousand tokens before any conversation, and
# vllm-mlx's own guidance is that reasoning models want >= 32768 so a think
# block isn't evicted mid-generation. Below MIN_KV_SIZE the session doesn't
# save memory so much as start amnesiac, so the floor wins over the halving.
# Resolve the model's on-disk footprint and the GPU budget it has to fit in.
# Sets model_mb / wired_mb / gpu_mb in the CALLER's scope (both callers declare
# them local). Returns 1 when the size can't be determined, so callers can skip
# rather than guess. Prefers the real cached size over the catalog estimate,
# because a catalog figure is rounded and quants vary.
_model_footprint() {
    local cache_dir i total_mb
    total_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
    [[ "$total_mb" -le 0 ]] && return 1

    # Catalog estimate first, then the real cached size if it looks complete.
    # A partial download must never win: run.sh aborts a stalled fetch (see
    # STALL_LIMIT), leaving e.g. 3GB of a 16GB model on disk. Trusting that
    # would tell the preflight there is plenty of headroom AND hand the prefix
    # cache a budget sized for a 3GB model — producing exactly the swap
    # thrashing this sizing exists to prevent. Take the larger of the two.
    local catalog_mb=0 cached_mb=0
    for i in "${!MODEL_IDS[@]}"; do
        if [[ "${MODEL_IDS[$i]}" == "$MODEL" ]]; then
            catalog_mb=$(( ${MODEL_SIZES[$i]%%GB*} * 1024 ))
            break
        fi
    done
    cache_dir="$HF_CACHE/models--${MODEL//\//--}"
    if [[ -d "$cache_dir" ]]; then
        cached_mb=$(( $(du -sk "$cache_dir" 2>/dev/null | cut -f1 || echo 0) / 1024 ))
    fi
    if [[ "$cached_mb" -gt "$catalog_mb" ]]; then
        model_mb=$cached_mb
    else
        model_mb=$catalog_mb
    fi
    [[ "${model_mb:-0}" -le 0 ]] && return 1

    # Effective GPU budget: the wired limit if explicitly set, else the macOS
    # default of ~75% of RAM.
    wired_mb=$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)
    if [[ "${wired_mb:-0}" -gt 0 ]]; then
        gpu_mb=$wired_mb
    else
        gpu_mb=$(( total_mb * 3 / 4 ))
    fi
    return 0
}

MIN_KV_SIZE=32768

# Prompt/prefix cache budget, in MB, sized from what's actually left after the
# weights rather than as a fixed fraction of total RAM.
#
# The old --cache-memory-percent 0.35 was tuned when every model here was ~5GB
# (5 + 8.4 = 13.4GB, comfortable). Against a 16GB model on a 24GB Mac it asks
# for 16 + 8.4 = 24.4GB — more than the machine has, let alone the ~19GB the
# GPU can address — and the result is swap thrashing, not caching. Measured on
# an M5/24GB: 14.2GB swapped and a 5-token reply taking 22.9s.
#
# Budget = GPU budget - weights - reserve, floored so the cache still exists.
CACHE_MEMORY_MB=""
_compute_cache_budget() {
    local model_mb wired_mb gpu_mb avail
    _model_footprint || return 0

    # The prefix cache costs its size TWICE at peak: the stored snapshot plus
    # the live copy restored into the working KV cache on a HIT. Observed
    # directly — a 13,536-token system prompt stores 1043MB, and restoring it
    # on the next turn pushed a 24GB Mac past the default 18.4GB budget:
    #   "System KV cache HIT ... / Pure-LLM KV-cache path failed before first
    #    token (Metal OOM); falling back to uncached stream_generate"
    # and the fallback then OOMed too, ending the stream with a 500.
    #
    # So halve it: budget for snapshot + live copy + 1.5GB of activations.
    avail=$(( (gpu_mb - model_mb - 1536) / 2 ))
    if   [[ "$avail" -lt 512 ]];  then CACHE_MEMORY_MB=512
    elif [[ "$avail" -gt 8192 ]]; then CACHE_MEMORY_MB=8192
    else CACHE_MEMORY_MB=$avail
    fi
}

_shrink_budgets() {
    VLLM_MAX_TOKENS=16384
    if [[ -n "$MAX_KV_SIZE" ]]; then
        local halved=$(( MAX_KV_SIZE / 2 ))
        if [[ "$halved" -lt "$MIN_KV_SIZE" ]]; then
            MAX_KV_SIZE=$(( MAX_KV_SIZE < MIN_KV_SIZE ? MAX_KV_SIZE : MIN_KV_SIZE ))
        else
            MAX_KV_SIZE=$halved
        fi
    fi
    return 0
}

memory_preflight() {
    [[ "${CCLOCAL_NO_MEMCHECK:-0}" == "1" ]] && return 0

    local model_mb wired_mb gpu_mb gpu_free_mb rec_mb forced total_mb
    forced="${CCLOCAL_FORCE_MEMCHECK:-0}"
    _model_footprint || return 0   # RAM or model size unknown — don't block

    total_mb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
    gpu_free_mb=$(( gpu_mb - model_mb ))
    rec_mb=$(( total_mb - 3072 ))   # leave ~3GB for the OS

    # >=6GB GPU headroom after weights comfortably holds a ~25-32K-token
    # agentic KV cache (8-bit quantized). Below that it OOM-crashes.
    if [[ "$forced" != "1" && "$gpu_free_mb" -ge 6144 ]]; then
        return 0
    fi

    printf "\n  ${YELLOW}⚠ Tight memory${RESET}  ~$(( model_mb / 1024 ))GB model, "
    printf "GPU budget ~$(( gpu_mb / 1024 ))GB → ~$(( gpu_free_mb / 1024 ))GB for KV cache.\n"
    printf "  ${DIM}Large agentic contexts have OOM-crashed vllm-mlx in this range.${RESET}\n\n"
    printf "  ${BOLD}Safeguards:${RESET}\n"
    # Two distinct knobs, previously conflated under "shrink context":
    #   --max-tokens  = longest single generation (peak memory during one reply)
    #   --max-kv-size = KV cache bound per sequence, i.e. the real context window
    # Halving both is what actually reduces steady-state memory.
    printf "    ${CYAN}1${RESET}) Shrink budgets   --max-tokens ${VLLM_MAX_TOKENS} → 16384"
    if [[ -n "$MAX_KV_SIZE" ]]; then
        local _shrunk=$(( MAX_KV_SIZE / 2 ))
        [[ "$_shrunk" -lt "$MIN_KV_SIZE" ]] && _shrunk=$MIN_KV_SIZE
        [[ "$MAX_KV_SIZE" -lt "$_shrunk" ]] && _shrunk=$MAX_KV_SIZE
        if [[ "$_shrunk" -ne "$MAX_KV_SIZE" ]]; then
            printf ", --max-kv-size ${MAX_KV_SIZE} → ${_shrunk}"
        else
            printf " ${DIM}(context window already at the ${MIN_KV_SIZE} floor)${RESET}"
        fi
    fi
    printf "\n"
    # Can the GPU limit still be raised, and would that actually help?
    local can_raise=false
    [[ "${wired_mb:-0}" -lt "$rec_mb" ]] && can_raise=true

    if [[ "$can_raise" == true ]]; then
        printf "    ${CYAN}2${RESET}) Raise GPU limit  iogpu.wired_limit_mb ${wired_mb:-0} → ${rec_mb}  ${DIM}(sudo, until reboot)${RESET}\n"
        printf "       ${YELLOW}⚠ Starves macOS of memory. If the GPU then takes more than the${RESET}\n"
        printf "       ${YELLOW}  system can spare, the whole Mac can stall for a long time.${RESET}\n"
        printf "       ${DIM}Reverted on exit and on reboot, but the stall happens while it's set.${RESET}\n"
    else
        printf "    ${DIM}2) GPU limit already ${wired_mb}MB — fine${RESET}\n"
    fi
    printf "    ${CYAN}3${RESET}) Both\n"
    printf "    ${CYAN}c${RESET}) Continue as-is ${DIM}(risky)${RESET}     ${CYAN}q${RESET}) Quit\n\n"

    # Default to 1 (shrink budgets) — never to anything that touches
    # iogpu.wired_limit_mb. Raising that cap takes memory away from macOS
    # itself, and if the GPU then claims it the machine can hang hard. It is
    # offered, never chosen for you.
    local _dflt=1 _dlabel="shrink budgets"

    if ! [[ -t 0 ]]; then
        printf "  ${DIM}Non-interactive — applying recommended (${_dlabel}).${RESET}\n"
        # Never prompt for sudo in a non-interactive run; shrink only.
        _shrink_budgets
        return 0
    fi

    local choice
    read -rp "  Choose [1/2/3/c/q] (Enter = ${_dflt}): " choice
    [[ -z "$choice" ]] && choice=$_dflt
    case "$choice" in
        1)     _shrink_budgets ;;
        2)     _raise_wired_limit "$rec_mb" ;;
        3)     _shrink_budgets; _raise_wired_limit "$rec_mb" ;;
        c|C)   printf "  ${DIM}Continuing with current settings.${RESET}\n" ;;
        q|Q)   printf "  Aborted.\n"; exit 0 ;;
        *)     printf "  ${DIM}Unrecognized — applying recommended.${RESET}\n"; _shrink_budgets ;;
    esac
}

show_help() {
    cat <<EOF
${BOLD}Usage:${RESET} cclocal [OPTIONS]

Without any model flag, cclocal opens an interactive menu to select a model,
show cached models, and manage the cache. Model flags bypass the menu.

${BOLD}Model flags${RESET}
  --qwen38        Qwen3.8-27B (~16GB, best quality, XML tool calls)
  --deckard       Qwen3.5-9B-Deckard-Agent (~6GB, agent-tuned, fast)
  --gemma-light   Gemma-4-E4B (~5GB, default, clean tool calling)
  --gemma         Gemma-4-26B-A4B MoE (~16GB)
  --coder         Qwen3-Coder-30B-A3B (~18GB)
  --qwen3         Qwen3.5-9B stock (~5GB; --deckard is the fixed fine-tune)
  --light         Alias for --gemma-light (back-compat with v2.0.1)
  --model ID      Use a custom HuggingFace MLX model ID

${BOLD}Commands${RESET}
  --list, -l      List cached models and exit
  --rm            Manage cached models (interactive)
  --clean         Alias for --rm

${BOLD}Server options${RESET}
  --server        Start vllm-mlx server only (don't launch Claude Code)
  --port N        Server port (default: 8000)
  --no-mem-check  Skip the RAM-headroom preflight prompt
  --safe          Always show the memory-safeguard menu (force, any model)
  --out-tokens N  Max output tokens Claude Code requests (default 8192;
                  raise for large file writes, e.g. 16384)
  --think         Enable brief reasoning (reasoning_effort=low) instead of
                  none. Costs latency; thinking is emitted as structured
                  Anthropic thinking blocks, never leaked into the text.

${BOLD}Remote backend${RESET} ${DIM}(skip the local server, connect to a remote vLLM box)${RESET}
  --dgx-active    DGX Spark preset ${DIM}($DGX_ACTIVE)${RESET}
  --dgx-idle      DGX Spark preset ${DIM}($DGX_IDLE)${RESET}
  --lmstudio      LM Studio on this Mac ${DIM}($LMSTUDIO_URL)${RESET}
                  ${DIM}Needs LM Studio 0.4.1+ (native Anthropic /v1/messages);${RESET}
                  ${DIM}start it with \`lms server start\`.${RESET}
  --remote URL    Any remote vLLM endpoint, e.g. http://host:8000
  --remote-model ID  Override model (default: auto-detect from /v1/models)

${BOLD}Other${RESET}
  -h, --help      Show this help

${BOLD}Examples${RESET}
  cclocal                  ${DIM}# interactive menu${RESET}
  cclocal --gemma-light    ${DIM}# direct launch, Gemma-4-E4B (default)${RESET}
  cclocal --gemma          ${DIM}# direct launch, Gemma-4-26B MoE${RESET}
  cclocal --list           ${DIM}# show cached models${RESET}
  cclocal --rm             ${DIM}# manage/delete cached models${RESET}
  cclocal --server         ${DIM}# server only, connect Claude Code later${RESET}
  cclocal --qwen38         ${DIM}# direct launch, Qwen3.8-27B${RESET}
  cclocal --qwen38 --think ${DIM}# ...with brief reasoning enabled${RESET}
  cclocal --lmstudio       ${DIM}# use LM Studio's server on this Mac${RESET}
  cclocal --dgx-active     ${DIM}# remote DGX Spark (MoE box)${RESET}
  cclocal --remote http://host:8000  ${DIM}# any remote vLLM box${RESET}
EOF
}

# =============================================================================
# Argument parsing
# =============================================================================
MODEL=""
MODEL_NAME_DISPLAY=""
PORT=8000
SERVER_ONLY=false
REMOTE_URL=""      # set by --remote / --dgx-* ; empty = local vllm-mlx
REMOTE_MODEL=""    # optional override; else auto-detected from /v1/models
ENABLE_THINKING=false   # --think: reasoning_effort=low instead of no thinking
TOOL_PARSER="auto"      # resolved from the catalog once MODEL is known
REASONING_PARSER=""     # ditto; applied even without --think (see catalog)
MAX_KV_SIZE=""          # resolved from the catalog; empty = engine default

while [[ $# -gt 0 ]]; do
    case "$1" in
        --coder|--gemma|--gemma-light|--deckard|--qwen3|--qwen38)
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
        --remote)        REMOTE_URL="$2"; shift 2 ;;
        --remote-model)  REMOTE_MODEL="$2"; shift 2 ;;
        --dgx-active)    REMOTE_URL="$DGX_ACTIVE"; shift ;;
        --dgx-idle)      REMOTE_URL="$DGX_IDLE"; shift ;;
        --lmstudio)      REMOTE_URL="$LMSTUDIO_URL"; shift ;;
        --think)         ENABLE_THINKING=true; shift ;;
        --no-mem-check) CCLOCAL_NO_MEMCHECK=1; shift ;;
        --safe)         CCLOCAL_FORCE_MEMCHECK=1; shift ;;
        --out-tokens)   CC_OUTPUT_TOKENS_OVERRIDE="$2"; shift 2 ;;
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

# No model flag given — show interactive menu (local only; remote auto-detects)
if [[ -z "$REMOTE_URL" && -z "$MODEL" ]]; then
    interactive_menu
fi

# Resolve per-model serve flags from the catalog. Done once here rather than in
# the flag parser so the interactive menu and --model take the same path.
# A custom --model ID isn't in the catalog and keeps the "auto" defaults.
for _i in "${!MODEL_IDS[@]}"; do
    if [[ "${MODEL_IDS[$_i]}" == "$MODEL" ]]; then
        TOOL_PARSER="${MODEL_PARSERS[$_i]}"
        REASONING_PARSER="${MODEL_REASONING[$_i]}"
        MAX_KV_SIZE="${MODEL_KV_SIZES[$_i]}"
        break
    fi
done
# A custom --model isn't in the catalog. Give it the same conservative bound
# rather than none: an unbounded rotating cache grows until Metal OOMs, and
# CLAUDE_CODE_MAX_CONTEXT_TOKENS below would otherwise promise Claude Code a
# window the server was never told to honour.
[[ -z "$MAX_KV_SIZE" && -z "$REMOTE_URL" ]] && MAX_KV_SIZE=32768

# =============================================================================
# Pre-flight checks
# =============================================================================
# vllm-mlx is only needed when we run the model locally.
if [[ -z "$REMOTE_URL" ]]; then
    VLLM_BIN="$SCRIPT_DIR/.venv/bin/vllm-mlx"
    if [[ ! -x "$VLLM_BIN" ]]; then
        echo "${RED}ERROR: vllm-mlx not found in .venv. Run ./install.sh first.${RESET}"
        exit 1
    fi
fi
if ! command -v claude &>/dev/null; then
    printf "${RED}ERROR: Claude Code CLI not found. Install it first:${RESET}\n"
    echo "  https://docs.anthropic.com/en/docs/claude-code"
    exit 1
fi

# =============================================================================
# Remote backend setup (reachability + model auto-detect)
# =============================================================================
# BASE_URL is what Claude Code points ANTHROPIC_BASE_URL at — the local server
# by default, or the remote box when --remote/--dgx-* is used.
if [[ -n "$REMOTE_URL" ]]; then
    REMOTE_URL="${REMOTE_URL%/}"   # strip trailing slash

    # Reachability check (a few short retries)
    printf "${DIM}Checking remote endpoint $REMOTE_URL ...${RESET}\n"
    http_code=""
    reachable=false
    for _ in 1 2 3 4 5; do
        http_code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$REMOTE_URL/health" 2>/dev/null || true)
        if [[ "$http_code" == "200" ]]; then reachable=true; break; fi
        sleep 1
    done
    if [[ "$reachable" != true ]]; then
        printf "${RED}ERROR: Cannot reach $REMOTE_URL/health (last status: ${http_code:-none}).${RESET}\n"
        if [[ "$REMOTE_URL" == "$LMSTUDIO_URL" ]]; then
            echo "  - Is LM Studio's server running?  (lms server start)"
            echo "  - Is a model loaded?  (lms ps)"
            echo "  - LM Studio 0.4.1+ is required for the Anthropic /v1/messages endpoint."
        else
            echo "  - Is the remote box actually serving vLLM on that address/port?"
            echo "  - If it's a Tailscale address (100.x), is Tailscale up?  (tailscale status)"
        fi
        exit 1
    fi

    # Model: explicit override wins, else auto-detect from /v1/models
    if [[ -n "$REMOTE_MODEL" ]]; then
        MODEL="$REMOTE_MODEL"
    else
        # Whitespace-tolerant: LM Studio pretty-prints ("id": "x"), vLLM is
        # compact ("id":"x"). `|| true` keeps a no-match from tripping `set -e`
        # so the empty-check below reports a clear error instead of a silent bail.
        MODEL=$(curl -s -m 8 "$REMOTE_URL/v1/models" 2>/dev/null \
            | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
            | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/' || true)
        if [[ -z "$MODEL" ]]; then
            printf "${RED}ERROR: Could not auto-detect a model from $REMOTE_URL/v1/models.${RESET}\n"
            echo "  Pass one explicitly with:  --remote-model <id>"
            exit 1
        fi
    fi
    MODEL_NAME_DISPLAY="$MODEL"
    BASE_URL="$REMOTE_URL"
else
    BASE_URL="http://127.0.0.1:$PORT"
fi

# =============================================================================
# Launch
# =============================================================================
print_header
printf "  ${BOLD}Model:${RESET}  ${MODEL_NAME_DISPLAY:-$MODEL}\n"
printf "  ${DIM}ID:     $MODEL${RESET}\n"
if [[ -n "$REMOTE_URL" ]]; then
    printf "  ${BOLD}Remote:${RESET} $BASE_URL\n"
else
    printf "  ${BOLD}Port:${RESET}   $PORT\n"
    if ! is_cached "$MODEL"; then
        printf "  ${YELLOW}Note:${RESET}   model not cached — first run will download\n"
    fi
fi
echo ""

# Cleanup on exit: revert a sudo'd Metal GPU limit and stop the server.
# Armed BEFORE memory_preflight so the limit is always restored even if the
# launch aborts before the server starts.
cleanup() {
    if [[ -n "${WIRED_RESTORE:-}" ]]; then
        printf "\n${BOLD}Restoring Metal GPU wired limit to ${WIRED_RESTORE}${RESET} — enter your password if prompted:\n"
        # Plain sudo (not -n): if credentials expired this prompts for the
        # password. stderr is left attached so the prompt is visible; only the
        # sysctl stdout (the echoed new value) is suppressed.
        if sudo sysctl iogpu.wired_limit_mb="$WIRED_RESTORE" >/dev/null; then
            printf "${DIM}Restored.${RESET}\n"
        else
            printf "${YELLOW}Restore did not complete.${RESET} Run manually:\n"
            printf "  ${DIM}sudo sysctl iogpu.wired_limit_mb=${WIRED_RESTORE}${RESET}\n"
            printf "${DIM}(It also resets to the macOS default on reboot.)${RESET}\n"
        fi
        WIRED_RESTORE=""
    fi
    if [[ -n "${SERVER_PID:-}" ]]; then
        echo ""
        printf "${DIM}Shutting down vllm-mlx server (pid: $SERVER_PID)...${RESET}\n"
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
        printf "${DIM}Done.${RESET}\n"
    fi
}
trap cleanup EXIT

# --- Local server lifecycle (skipped entirely in remote mode) ---
if [[ -z "$REMOTE_URL" ]]; then
memory_preflight
# After the preflight, so a raised GPU limit is reflected in the budget.
_compute_cache_budget

# Kill any existing process on the port
# Decide what to do about anything already on $PORT.
#
# This used to unconditionally kill whatever held the port. That is right for a
# stale process left by a crashed run, and badly wrong for a second cclocal
# session: it SIGKILLs the first session's server out from under a live Claude
# Code, which then talks to a server that no longer exists. Ask the port what it
# is first, and only kill what isn't answering as a live vllm-mlx.
#
# When it IS a live server, the failure it prevents is nasty: the second server
# can't bind and dies, but Claude Code still launches pointed at that port —
# where the FIRST session's server serves a different model. Every request 404s
# ("The model `X` does not exist. Available model: `Y`"), which Claude Code
# reports as "Waiting for API response ... check your network".
_port_owner_model() {
    curl -s -m 3 "http://127.0.0.1:$PORT/health" 2>/dev/null \
        | grep -oE '"model_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -E 's/.*"([^"]*)"$/\1/' || true
}
if lsof -ti "tcp:$PORT" >/dev/null 2>&1; then
    _owner=$(_port_owner_model)
    if [[ "$_owner" == "$MODEL" ]]; then
        # Same model already served here. Don't start a second one, and don't
        # adopt it either — cleanup() kills SERVER_PID on exit and would take
        # down the other session's server. --remote attaches without owning it.
        printf "${YELLOW}A vllm-mlx server is already running this model on port $PORT.${RESET}\n"
        echo "  Attach to it instead of starting a second copy:"
        echo "    cclocal --remote http://127.0.0.1:$PORT"
        echo "  Or run an independent one:  cclocal <flags> --port $((PORT + 1))"
        exit 1
    elif [[ -n "$_owner" ]]; then
        printf "${RED}ERROR: port $PORT is already serving a different model.${RESET}\n"
        printf "  running:  %s\n" "$_owner"
        printf "  you want: %s\n" "$MODEL"
        echo ""
        echo "  Claude Code would send requests for your model to that server and"
        echo "  get 404s, which it reports as \"check your network\". Either:"
        echo "    - stop the other cclocal session, or"
        echo "    - run this one on its own port:  cclocal <flags> --port $((PORT + 1))"
        exit 1
    else
        # Nothing answered /health. Either a dead vllm-mlx from a crashed run,
        # or an unrelated program. Reclaim the former, refuse the latter.
        existing_pid=$(lsof -ti:"$PORT" 2>/dev/null || true)
        if [[ -n "$existing_pid" ]] && ps -p "$existing_pid" -o command= 2>/dev/null | grep -q "vllm-mlx"; then
            echo "Clearing a non-responsive vllm-mlx on port $PORT (pid: $existing_pid)..."
            kill "$existing_pid" 2>/dev/null || true
            sleep 2
            kill -0 "$existing_pid" 2>/dev/null && kill -9 "$existing_pid" 2>/dev/null || true
        else
            printf "${RED}ERROR: port $PORT is in use by something that isn't vllm-mlx.${RESET}\n"
            echo "  Free it, or pick another:  cclocal <flags> --port $((PORT + 1))"
            exit 1
        fi
    fi
fi

# Rotate the previous runs' logs instead of truncating, so a crashed session
# can still be inspected afterwards. Keep several generations, not one: a
# single .1 is lost as soon as anyone starts two more servers, and "read
# server.log" is the first diagnostic step for every failure in this project —
# a generic "API error" in Claude Code carries no detail at all.
LOG_FILE="$SCRIPT_DIR/server.log"
LOG_KEEP=5
if [[ -f "$LOG_FILE" ]]; then
    rm -f "$LOG_FILE.$LOG_KEEP" 2>/dev/null || true
    for (( _i=LOG_KEEP-1; _i>=1; _i-- )); do
        [[ -f "$LOG_FILE.$_i" ]] && mv -f "$LOG_FILE.$_i" "$LOG_FILE.$((_i+1))" 2>/dev/null || true
    done
    mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
fi
printf "${DIM}Starting vllm-mlx server (logs: $LOG_FILE, previous: $LOG_FILE.1 … .$LOG_KEEP)...${RESET}\n"
fi

# CLAUDE_CODE_MAX_OUTPUT_TOKENS — per-request output cap sent by Claude Code.
# Distinct from vllm-mlx's `--max-tokens` flag below (the server-side context
# window default).
#
# This must be generous: a Write/Edit tool call serializes the ENTIRE file
# body as output tokens inside the tool-use JSON. The old 4096 truncated the
# tool call mid-`content`, the JSON never closed, the streaming tool-call
# parser couldn't build a tool_use block, and the write silently did nothing
# (no error). 8192 is a balanced default — roughly doubles file-write headroom
# vs the old 4096 while costing less generation memory than 16384. Override
# per-run with `--out-tokens N` (e.g. 16384 for big files; pair with `--safe`
# to raise the GPU limit if a large model OOMs).
CC_OUTPUT_TOKENS="${CC_OUTPUT_TOKENS_OVERRIDE:-8192}"

# CLAUDE_CODE_MAX_CONTEXT_TOKENS — the context window Claude Code assumes, and
# therefore when auto-compact fires.
#
# Claude Code doesn't recognise these model IDs, so it falls back to assuming a
# 200k window and says so. That assumption is dangerous here rather than merely
# cosmetic: the server bounds the KV cache at --max-kv-size (32K), and past it
# RotatingKVCache silently evicts the oldest tokens. Left at 200k, Claude Code
# would let a session grow ~6x past the real window before compacting, while
# the model quietly forgot the start of the conversation — looking like the
# model going stupid, not like a misconfiguration.
#
# So pin it to the window we actually serve. In remote mode we don't know the
# remote's bound — it may well be far larger — so leave it unset and let
# Claude Code use its own default.
# A custom --model isn't in the catalog and has no KV size, so fall back to a
# conservative default rather than leaving Claude Code on its 200k assumption.
#
# Report 85% of the real bound, not 100%. Claude Code compacts as it nears the
# window it believes in, and compaction is itself a model call that has to fit
# inside that window. At exactly --max-kv-size the two thresholds coincide with
# RotatingKVCache's eviction point, so a session can start losing its oldest
# tokens right as it tries to summarise them. The margin is cheap — slightly
# earlier compaction — and the failure it avoids is silent.
CC_CONTEXT_TOKENS=""
if [[ -z "$REMOTE_URL" ]]; then
    CC_CONTEXT_TOKENS=$(( ${MAX_KV_SIZE:-32768} * 85 / 100 ))
fi

# Environment variables passed to Claude Code. Kept as a single array so the
# --server print-out and the in-process launch cannot drift apart.
CLAUDE_ENV=(
    "ANTHROPIC_BASE_URL=$BASE_URL"
    "ANTHROPIC_API_KEY=not-needed"
    "ANTHROPIC_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_OPUS_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_SONNET_MODEL=$MODEL"
    "ANTHROPIC_DEFAULT_HAIKU_MODEL=$MODEL"
    "CLAUDE_CODE_SUBAGENT_MODEL=$MODEL"
    "CLAUDE_CODE_MAX_OUTPUT_TOKENS=$CC_OUTPUT_TOKENS"
    # Claude Code's client-side timeouts assume a cloud API. A local model is
    # one to two orders of magnitude slower, and it is the CLIENT that gives up
    # first — the server keeps generating happily while Claude Code reports
    # "Waiting for API response ... check your network", which points nowhere
    # near the real cause.
    #
    #   API_TIMEOUT_MS                     default 600000 (10 min). A 26B model
    #                                      observed at 1.6 tok/s needs ~85 min
    #                                      for an 8192-token file. 30 min here.
    #   API_FORCE_IDLE_TIMEOUT=0           disables the 5-minute "no bytes
    #                                      arrived" abort, which is ON for every
    #                                      non-Anthropic provider — i.e. always,
    #                                      for us. A long prefill sends nothing
    #                                      for minutes and trips it.
    #   CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS the byte-level watchdog; Claude Code
    #                                      clamps it to 30 min, so ask for that.
    "API_TIMEOUT_MS=1800000"
    "API_FORCE_IDLE_TIMEOUT=0"
    "CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS=1800000"
    "CLAUDE_CODE_ATTRIBUTION_HEADER=0"
    "DISABLE_PROMPT_CACHING=1"
    "DISABLE_AUTOUPDATER=1"
    "DISABLE_TELEMETRY=1"
    "DISABLE_ERROR_REPORTING=1"
    "DISABLE_NON_ESSENTIAL_MODEL_CALLS=1"
)
# Only when we know the real window (local server with a KV bound) — see above.
[[ -n "$CC_CONTEXT_TOKENS" ]] && \
    CLAUDE_ENV+=("CLAUDE_CODE_MAX_CONTEXT_TOKENS=$CC_CONTEXT_TOKENS")
# Proactive guidance: a local model's output is token-capped, and an
# oversized single Write/Edit serializes the whole file into one tool call
# that gets truncated and dropped (see README #18). Tell the model up front
# to write large files in sections so it pre-empts the wall. The fork's
# --tool-call-truncation-notice (below) is the reactive backstop.
_WRITE_IN_PARTS_GUIDANCE="When creating or substantially editing a file longer than ~150 lines, do NOT emit it in a single Write/Edit tool call. First create the file with an initial section, then append each remaining section with separate, smaller Write/Edit calls. This local model's output is token-capped; an oversized single tool call is truncated and silently dropped."

CLAUDE_FLAGS=(
    --strict-mcp-config
    --mcp-config "$MCP_CONFIG"
    --tools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
    # Pre-allow the same 8 built-in tools so auto mode never makes its
    # model-based safety-classifier call (a slow, serialized local model
    # can't service it in time -> "model temporarily unavailable", Write
    # blocked). Tool set stays scoped to these 8 via --tools above; nothing
    # outside the list is auto-approved.
    --allowedTools "Bash,Read,Edit,Write,Glob,Grep,WebSearch,WebFetch"
    --append-system-prompt "$_WRITE_IN_PARTS_GUIDANCE"
)

# --- Reasoning / thinking configuration -------------------------------------
# Default OFF. Claude Code drives long agentic loops, and a reasoning model
# spends its whole token budget deliberating before the first tool call.
# Qwen3.8 in particular defaults to reasoning_effort=xhigh, which turns a
# trivial task into minutes of silent thinking at local token rates.
#
# Two levers, both via the chat template:
#   enable_thinking=false  -> template emits an empty <think></think> and the
#                             model skips reasoning entirely.
#   preserve_thinking=false -> prior turns' reasoning is NOT re-injected. This
#                             matters more than it looks: Qwen3.8 defaults it
#                             to true, so in an agentic loop every turn carries
#                             every earlier think block.
#
# --think switches to reasoning_effort=low (the template rejects "none", and
# xhigh/medium are not worth their latency here) and turns on the qwen3
# reasoning parser so <think> content becomes a structured Anthropic thinking
# block instead of leaking into the text stream.
#
# Sampling follows Qwen's published recommendations, which differ per mode.
# Note the model's own generation_config ships the *thinking* values, so the
# non-thinking defaults have to be set explicitly.
REASONING_FLAGS=()
if [[ "$ENABLE_THINKING" == "true" ]]; then
    REASONING_FLAGS+=(
        --default-chat-template-kwargs '{"reasoning_effort": "low", "preserve_thinking": false}'
        --reasoning-parser "${REASONING_PARSER:-qwen3}"
        --default-temperature 1.0
        --default-top-p 0.95
        # NOT --default-top-k: it disables the system-prompt KV cache, see the
        # note on the non-thinking branch below. Qwen recommends top_k=20 for
        # thinking mode, but re-prefilling ~13k system tokens every turn costs
        # far more than the sampling tweak is worth.
    )
else
    REASONING_FLAGS+=(
        --default-chat-template-kwargs '{"enable_thinking": false, "preserve_thinking": false}'
    )
    # Qwen publishes temp 0.7 / top_p 0.80 for non-thinking mode. Apply it only
    # to Qwen models: Gemma and GLM ship their own generation_config, and
    # overriding it silently changes their output quality for no reason.
    if [[ "$MODEL" == *[Qq]wen* ]]; then
        REASONING_FLAGS+=(--default-temperature 0.7 --default-top-p 0.80)
    fi
    # Some models ignore enable_thinking=false. For those the catalog names a
    # reasoning parser, so the reasoning becomes a structured thinking block
    # instead of leaking into the text as if it were the answer.
    if [[ -n "$REASONING_PARSER" ]]; then
        REASONING_FLAGS+=(--reasoning-parser "$REASONING_PARSER")
    fi
fi
# Deliberately NOT set: --default-top-k / --default-min-p /
# --default-presence-penalty / --default-repetition-penalty.
#
# Qwen publishes top_k=20 and presence_penalty=1.5 for non-thinking mode, but
# vllm-mlx's system-prompt KV cache only covers the temperature+top_p sampler.
# Any of those four at a non-default value makes the engine skip the cache
# ("System KV cache SKIP ... cache branch cannot honor (['top_k',
# 'presence_penalty'])") and re-prefill Claude Code's entire system prompt on
# every single turn. That is the same 90% slowdown as problem #4, bought for a
# marginal sampling tweak. temperature and top_p are honoured by the cached
# path, so those we keep.

# --max-kv-size bounds the KV cache per sequence (RotatingKVCache). Only set
# for models where the cache, not the weights, is the binding constraint.
KV_FLAGS=()
[[ -n "$MAX_KV_SIZE" ]] && KV_FLAGS+=(--max-kv-size "$MAX_KV_SIZE")

# KV cache quantization halves cache memory — longer conversations before OOM
# Prefix cache sized per-model from what's left after the weights (see
# _compute_cache_budget); falls back to the engine default if unknown
# Larger prefill chunks for faster time-to-first-token
# Batch 4 tokens before streaming for better throughput
# 1800s server timeout, matched to the client timeouts set above — a slow local
# model generating a large file can legitimately run for tens of minutes
# Tool parser comes from the catalog: qwen3_xml for the Qwen 3.5/3.8/Coder
# XML format, "auto" (sniffs Gemma 4 / Mistral / Llama / Hermes) otherwise.
# --- Start local server + wait for it to be ready (skipped in remote mode) ---
if [[ -z "$REMOTE_URL" ]]; then
# Claude Code issues overlapping requests. The engine is deliberately
# serialized (no --continuous-batching, see README #7 — concurrent Metal work
# OOMs a big model on 24GB), and its default admission policy is "fail_fast":
# a second in-flight request is REJECTED rather than queued, which reaches
# Claude Code as a fatal API error mid-session. "wait" keeps the same
# one-at-a-time execution but makes the second request queue on the lock.
VLLM_MLX_SIMPLE_ENGINE_LOCK_ADMISSION=wait \
VLLM_MLX_ENABLE_THINKING=$([[ "$ENABLE_THINKING" == "true" ]] && echo true || echo false) \
"$VLLM_BIN" serve "$MODEL" \
    --port "$PORT" \
    --max-tokens "$VLLM_MAX_TOKENS" \
    --kv-cache-quantization \
    ${CACHE_MEMORY_MB:+--cache-memory-mb "$CACHE_MEMORY_MB"} \
    --prefill-step-size 4096 \
    --stream-interval 4 \
    --timeout 1800 \
    --enable-auto-tool-choice \
    --tool-call-parser "$TOOL_PARSER" \
    --tool-call-truncation-notice \
    ${REASONING_FLAGS[@]+"${REASONING_FLAGS[@]}"} \
    ${KV_FLAGS[@]+"${KV_FLAGS[@]}"} \
    > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
# cleanup()/trap are armed earlier (before memory_preflight) so a sudo'd GPU
# limit is reverted even if the launch fails before the server starts.

# Wait for server to be ready.
# First run downloads the model from HuggingFace into $HF_CACHE, which can take
# many minutes for large models. Instead of a blind fixed timeout, watch the
# model's cache dir grow and show live download size + speed. We only give up
# if there's genuinely no progress — a slow-but-progressing download won't fail.
MODEL_CACHE_DIR="$HF_CACHE/models--${MODEL//\//--}"
STALL_LIMIT=240   # seconds with neither download progress nor a ready server
POLL=3

fmt_kb() {
    local kb=$1
    if   [[ $kb -ge 1048576 ]]; then printf '%d.%dGB' $((kb / 1048576)) $(((kb % 1048576) * 10 / 1048576))
    elif [[ $kb -ge 1024 ]];    then printf '%dMB' $((kb / 1024))
    else printf '%dKB' "$kb"; fi
}

printf "${DIM}Waiting for server...${RESET}\n"
start_ts=$(date +%s)
last_ts=$start_ts
last_kb=0
stall_secs=0

while true; do
    if curl -s "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q "healthy"; then
        printf "\r\033[K${GREEN}Server ready${RESET} ${DIM}($(( $(date +%s) - start_ts ))s)${RESET}\n"
        break
    fi
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        printf "\r\033[K${RED}Server process died${RESET}. Check: ${DIM}tail $LOG_FILE${RESET}\n"
        exit 1
    fi

    now_ts=$(date +%s)
    cur_kb=0
    [[ -d "$MODEL_CACHE_DIR" ]] && cur_kb=$(du -sk "$MODEL_CACHE_DIR" 2>/dev/null | cut -f1)
    cur_kb=${cur_kb:-0}

    if [[ "$cur_kb" -gt "$last_kb" ]]; then
        # Actively downloading — show size + speed, reset the stall timer
        dt=$(( now_ts - last_ts )); [[ $dt -lt 1 ]] && dt=1
        rate_kb=$(( (cur_kb - last_kb) / dt ))
        printf "\r\033[K${CYAN}⬇ Downloading model${RESET} ${BOLD}%s${RESET} ${DIM}(%d.%d MB/s)${RESET}" \
            "$(fmt_kb "$cur_kb")" "$(( rate_kb / 1024 ))" "$(( (rate_kb % 1024) * 10 / 1024 ))"
        stall_secs=0
        last_kb=$cur_kb
        last_ts=$now_ts
    else
        stall_secs=$(( stall_secs + POLL ))
        if [[ "$cur_kb" -gt 0 ]]; then
            printf "\r\033[K${DIM}⏳ Model cached (%s) — loading into memory... %ss${RESET}" \
                "$(fmt_kb "$cur_kb")" "$stall_secs"
        else
            printf "\r\033[K${DIM}⏳ Starting server... %ss${RESET}" "$stall_secs"
        fi
        if [[ "$stall_secs" -ge "$STALL_LIMIT" ]]; then
            printf "\r\033[K${RED}timeout${RESET} — no download activity and not ready after ${STALL_LIMIT}s\n"
            echo "Check: tail -f $LOG_FILE"
            exit 1
        fi
    fi
    sleep "$POLL"
done
fi
# --- end local server lifecycle ---

if [[ "$SERVER_ONLY" == true ]]; then
    echo ""
    if [[ -n "$REMOTE_URL" ]]; then
        printf "${BOLD}Remote server already running at $BASE_URL${RESET}\n"
    else
        printf "${BOLD}Server running at $BASE_URL${RESET}\n"
    fi
    echo "Connect Claude Code from any terminal with:"
    echo ""
    echo "  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \\"
    for var in "${CLAUDE_ENV[@]}"; do
        echo "    $var \\"
    done
    echo "    claude ${CLAUDE_FLAGS[*]}"
    echo ""
    if [[ -n "$REMOTE_URL" ]]; then
        echo "(Remote server is managed elsewhere — nothing to keep alive here.)"
    else
        echo "Press Ctrl+C to stop."
        wait $SERVER_PID
    fi
else
    echo ""
    printf "${DIM}Launching Claude Code...${RESET}\n\n"

    # Env vars scoped to this process only — nothing touches ~/.claude/settings.json.
    # -u flags unset any real API keys from the parent shell so they don't leak through.
    env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        "${CLAUDE_ENV[@]}" \
        claude "${CLAUDE_FLAGS[@]}"
fi
