# fw-desktop-llm

Local LLM serving stack for the Framework Desktop (Ryzen AI Max+ 395 "Strix Halo",
Radeon 8060S iGPU, 128 GB unified memory).

Three concurrent `llama.cpp` servers behind an on-demand proxy for the heaviest tier.
Optimised for agentic coding workloads (Claude Code / Cline via [claude-code-router](https://github.com/musistudio/claude-code-router))
plus a Home Assistant voice tier.

## Stack

| Port  | Alias              | Model                                | Role                              | Always warm? |
|-------|--------------------|--------------------------------------|-----------------------------------|--------------|
| 11434 | `qwen3-coder-next` | Qwen3-Coder-Next 80B-A3B Q4_K_XL     | Heavy agentic, 262K ctx            | No — on-demand via `llama-swap`, 30 min idle TTL |
| 11435 | `qwen3-coder-30b`  | Qwen3-Coder 30B-A3B Q4_K_XL          | Fast codegen, 64K ctx, 2 slots     | Yes |
| 11436 | `qwen3-4b-ha`      | Qwen3-4B-Instruct-2507 Q4_K_XL       | Home Assistant voice, 16K ctx      | Yes |

CPU pinning: 80B → cores 0-7, 30B → 8-13, 4B → 14-15. Reasoning in
[docs/architecture.md](docs/architecture.md).

## Hardware / software baseline

- **CPU/GPU**: AMD Ryzen AI Max+ 395 w/ Radeon 8060S (gfx1151, RDNA3.5)
- **Memory**: 128 GB LPDDR5X unified, 124 GiB GTT carveout
- **OS**: Fedora Silverblue, container: [`kyuz0/amd-strix-halo-toolboxes`](https://github.com/kyuz0/amd-strix-halo-toolboxes) `llama-rocm-7.2.3`
- **Stack**: ROCm 7.2.3, llama.cpp build 9251 (e2b129e1b)
- **Proxy**: [`llama-swap`](https://github.com/mostlygeek/llama-swap) v216

## Quick start

```bash
# 1. Install llama-swap binary
mkdir -p ~/bin
curl -sL https://github.com/mostlygeek/llama-swap/releases/download/v216/llama-swap_216_linux_amd64.tar.gz \
  | tar -xz -C /tmp/ llama-swap
mv /tmp/llama-swap ~/bin/llama-swap && chmod +x ~/bin/llama-swap

# 2. Place models under ~/models/ matching the paths in serve.sh and llama-swap.yaml.

# 3. Launch (must happen inside the toolbox so llama-server resolves):
podman exec -d llama-rocm-7.2.3 bash ~/fw-desktop-llm/bin/launch.sh
```

See [docs/operations.md](docs/operations.md) for stop/restart, logs, health checks.

## Layout

```
fw-desktop-llm/
├── serve.sh              # Main launcher — starts llama-swap + 30B + 4B
├── llama-swap.yaml       # 80B on-demand config (proxied via port 11434)
├── bin/
│   ├── launch.sh         # Tiny wrapper used by `podman exec` to cd into repo
│   ├── llm-probe.sh      # Probe TTFT and tg t/s of any endpoint
│   └── rocm-watch.sh     # CSV-log GPU power / clocks / GTT
└── docs/
    ├── architecture.md   # Layout, CPU pinning, llama-swap rationale
    ├── findings.md       # Benchmarks, KV-quant regression, GPU% driver bug
    └── operations.md     # Start, stop, logs, troubleshooting
```

## Findings worth knowing about this hardware

- **`-b 4096 -ub 1024` is the prefill knee** on gfx1151 — +15-17% pp4096 over defaults. See [findings](docs/findings.md#prefill-batch-knee).
- **Do NOT quantise KV cache** on this stack — `q8_0` KV regresses tg by 17-35% across all Qwen3 model classes. See [findings](docs/findings.md#kv-cache-quantisation-is-a-regression).
- **btop's GPU % is a lie** on gfx1151 — the AMDGPU `gpu_busy_percent` counter pins at 100 with multiple ROCm contexts loaded, regardless of actual work. Trust power draw instead. See [findings](docs/findings.md#gpu_busy_percent-is-broken-on-gfx1151).

## License

MIT — do whatever, no warranty.
