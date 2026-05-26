# Architecture

## Three-tier layout

| Port  | Model                              | Context | Slots | CPU cores | Why this tier |
|-------|------------------------------------|--------:|------:|-----------|---------------|
| 11434 | Qwen3-Coder-Next 80B-A3B Q4_K_XL   | 262144  |     1 | 0-7       | Heavy agentic work, full training context for long-context routing |
| 11435 | Qwen3-Coder 30B-A3B Q4_K_XL        |  65536  |     2 | 8-13      | Fast codegen, two concurrent slots for CCR background route |
| 11436 | Qwen3-4B-Instruct-2507 Q4_K_XL     |  16384  |     2 | 14-15     | Home Assistant voice — kept on its own cores so HA latency never queues behind codegen |

### CPU pinning rationale

The Strix Halo has 16 physical cores. The 80B is the priority workload and is bench-tuned at 8 threads,
so it gets cores 0-7. The 30B's tg is memory-bound (MoE with 3B active), so narrowing it to 6 cores
costs almost nothing. The 4B is isolated on the last 2 cores so HA Assist voice responses never share
silicon with active codegen — minimum needed since 4B prefill is ~2000 t/s.

### Why `--parallel 1` for the 80B

With `-c 262144` and full-precision KV, the 80B already eats ~55 GiB of GTT. A second slot would
either double the KV (busting memory) or chop the per-slot context in half (defeating the purpose).
Concurrent 80B requests queue at the slot level; this is acceptable because CCR routes the
"background" workload to the 30B already.

## On-demand 80B via llama-swap

The 80B alone occupies ~55 GiB of GTT and ~25 W of idle power even when no requests are running.
[`llama-swap`](https://github.com/mostlygeek/llama-swap) sits in front of port 11434 and:

1. Lazily spawns the 80B `llama-server` on the first inbound request
2. Proxies subsequent requests to the spawned server (transparent OpenAI-compatible)
3. Kills the server after `ttl` seconds of no inbound requests, freeing GTT

Cold-start cost is ~16 s (model load + first token) with a warm page cache, ~45 s on a fully cold
disk. Warm-path TTFT is sub-second.

The 30B and 4B are NOT in the swap config — they're launched directly by `serve.sh` because they're
small enough to stay always-resident without cost concerns and their latency budget doesn't tolerate
cold starts.

## Why everything runs inside a toolbox

`kyuz0/amd-strix-halo-toolboxes` ships a `llama-server` built against ROCm 7.2.3 with all the
right RDNA3.5 patches, sparing us from building llama.cpp + ROCm from source on the host. The
trade-off is that `serve.sh` must be launched via `podman exec` so `llama-server` resolves; the
host can still talk to the ports because the toolbox shares the host network namespace by default.

`bin/launch.sh` is the tiny wrapper that does `cd /home/ramb0t/fw-desktop-llm && exec ./serve.sh` —
necessary because `podman exec -d` doesn't set a working directory matching the host's `$PWD`, and
`serve.sh` references models with relative paths.

## Routing

Client routing happens off-box via [claude-code-router](https://github.com/musistudio/claude-code-router) (CCR)
running on a separate Linux machine. CCR maps "default" → 80B (11434), "background" → 30B (11435).
Home Assistant talks directly to the 4B on 11436.
