#!/bin/bash
set -e

# Trap Ctrl+C to clean up all servers
cleanup() {
    echo ""
    echo "Stopping all llama-server processes..."
    # Kill all children: llama-swap (which kills its managed 80B) + native llama-servers
    pkill -P $$ 2>/dev/null
    # And any 80B llama-server spawned by llama-swap (grandchild, won't match -P $$)
    pkill -f "Qwen3-Coder-Next" 2>/dev/null
    wait
    echo "Stopped."
    exit 0
}
trap cleanup SIGINT SIGTERM

# Stack-wide settings (bench-validated on gfx1151 + ROCm 7.2.3, llama.cpp 9251):
#  -b 4096 -ub 1024 : prefill knee, +15-17% pp4096 vs default
#  f16 KV           : q8_0 KV regresses tg 17-35% across all Qwen3 model classes here
#                     (ROCm flash-attn fast path requires matched f16 KV)

# Rotate previous logs so each run starts fresh; keep one prior generation.
for f in /home/ramb0t/llama-swap.log /home/ramb0t/llama-30b.log /home/ramb0t/llama-4b.log; do
    [ -f "$f" ] && mv -f "$f" "$f.prev"
done

# Port 11434: llama-swap proxy for the 80B (Qwen3-Coder-Next).
# llama-swap spawns the 80B llama-server on demand (first request) and unloads it
# after 30 min idle. Cores 0-7 are reserved for it via taskset inside the swap config.
# See /home/ramb0t/llama-swap.yaml.
/home/ramb0t/bin/llama-swap \
  -config /home/ramb0t/llama-swap.yaml \
  -listen 0.0.0.0:11434 \
  -watch-config >>/home/ramb0t/llama-swap.log 2>&1 &
PID_BIG=$!

# Port 11435: Fast model (Qwen3-Coder 30B) — cores 8-13, 2 slots
# Narrowed from 8-15 to free 14-15 for the 4B; 30B tg is memory-bound, impact small
taskset -c 8-13 \
llama-server -m models/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL.gguf \
  -c 65536 --parallel 2 --cache-ram 0 -ngl 999 -fa 1 --no-mmap --jinja \
  -b 4096 -ub 1024 \
  -t 6 -tb 6 \
  --host 0.0.0.0 --port 11435 --alias qwen3-coder-30b \
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 >>/home/ramb0t/llama-30b.log 2>&1 &
PID_FAST=$!

# Port 11436: HA tiny (Qwen3-4B-Instruct-2507) — cores 14-15, isolated for voice latency
taskset -c 14-15 \
llama-server -m models/Qwen3-4B-Instruct-2507-GGUF/Qwen3-4B-Instruct-2507-UD-Q4_K_XL.gguf \
  -c 16384 --parallel 2 --cache-ram 0 -ngl 999 -fa 1 --no-mmap --jinja \
  -b 4096 -ub 1024 \
  -t 2 -tb 2 \
  --host 0.0.0.0 --port 11436 --alias qwen3-4b-ha \
  --temp 0.7 --top-p 0.8 --top-k 20 --min-p 0 >>/home/ramb0t/llama-4b.log 2>&1 &
PID_HA=$!

echo "Started: swap PID=$PID_BIG (11434 -> 80B on demand), fast PID=$PID_FAST (cores 8-13), ha PID=$PID_HA (cores 14-15)"
echo "Ctrl+C to stop all three."

# Wait keeps script attached to children — Ctrl+C will trigger the trap
wait
