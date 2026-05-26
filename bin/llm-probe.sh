#!/bin/bash
# Probe one or all llama-server endpoints. Streams response, reports TTFT and tg t/s.
#
# Usage:
#   llm-probe.sh                            # default: 80B endpoint
#   llm-probe.sh HOST:PORT MODEL [prompt_file_or_-]
#   llm-probe.sh --all                      # all 3 stack endpoints sequentially
#   llm-probe.sh --concurrent               # all 3 in parallel (worst-case load)
#   llm-probe.sh --label NAME HOST:PORT MODEL [prompt_file_or_-]
set -u

# Known stack — keep in sync with serve.sh
STACK=(
  "80B|localhost:11434|qwen3-coder-next"
  "30B|localhost:11435|qwen3-coder-30b"
  "4B|localhost:11436|qwen3-4b-ha"
)

DEFAULT_PROMPT='Write a Python function that flattens an arbitrarily nested list. Include a brief docstring and one example call.'

probe_one() {
  local label="$1" hp="$2" model="$3" prompt="$4"
  local body start_ns first_ns tokens line payload content gen_ms tps ttft_ms end_ns
  body=$(jq -n --arg m "$model" --arg p "$prompt" '{
    model:$m, stream:true, max_tokens:256, temperature:0.2,
    messages:[{role:"user", content:$p}]
  }')
  start_ns=$(date +%s%N)
  first_ns=0
  tokens=0
  while IFS= read -r line; do
    case "$line" in
      data:\ \[DONE\]) break ;;
      data:\ *)
        payload="${line#data: }"
        content=$(echo "$payload" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)
        if [ -n "$content" ]; then
          if [ "$first_ns" = "0" ]; then
            first_ns=$(date +%s%N)
            ttft_ms=$(( (first_ns - start_ns) / 1000000 ))
            printf '[%s] TTFT: %s ms\n' "$label" "$ttft_ms" >&2
          fi
          tokens=$((tokens + 1))
        fi
        ;;
    esac
  done < <(curl -sN -H "Content-Type: application/json" -d "$body" "http://$hp/v1/chat/completions")
  end_ns=$(date +%s%N)
  if [ "$first_ns" != "0" ] && [ "$tokens" -gt 0 ]; then
    gen_ms=$(( (end_ns - first_ns) / 1000000 ))
    tps=$(awk -v t="$tokens" -v ms="$gen_ms" 'BEGIN{ if(ms>0) printf "%.2f", (t*1000)/ms; else print "0"}')
    printf '[%s] tokens=%s gen_ms=%s tg=%s t/s\n' "$label" "$tokens" "$gen_ms" "$tps" >&2
  else
    printf '[%s] ERROR: no tokens received\n' "$label" >&2
  fi
}

load_prompt() {
  local src="$1"
  if [ -z "$src" ]; then echo "$DEFAULT_PROMPT"
  elif [ "$src" = "-" ]; then cat
  else cat "$src"
  fi
}

case "${1:-}" in
  --all)
    PROMPT="$(load_prompt "${2:-}")"
    for row in "${STACK[@]}"; do
      IFS='|' read -r lbl hp model <<< "$row"
      probe_one "$lbl" "$hp" "$model" "$PROMPT"
    done
    ;;
  --concurrent)
    PROMPT="$(load_prompt "${2:-}")"
    pids=()
    for row in "${STACK[@]}"; do
      IFS='|' read -r lbl hp model <<< "$row"
      probe_one "$lbl" "$hp" "$model" "$PROMPT" &
      pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p"; done
    ;;
  --label)
    LBL="$2"; HP="$3"; MODEL="$4"; SRC="${5:-}"
    probe_one "$LBL" "$HP" "$MODEL" "$(load_prompt "$SRC")"
    ;;
  *)
    HP="${1:-localhost:11434}"
    MODEL="${2:-qwen3-coder-next}"
    SRC="${3:-}"
    probe_one "$HP" "$HP" "$MODEL" "$(load_prompt "$SRC")"
    ;;
esac
