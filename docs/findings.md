# Findings

Hardware-specific behaviour discovered while building this stack on Strix Halo
(gfx1151, ROCm 7.2.3, llama.cpp build 9251). These are non-obvious and
counter to "standard CUDA wisdom" in several places.

## Prefill batch knee

**`-b 4096 -ub 1024`** is the prefill knee for Qwen3-class models on this hardware.
The llama.cpp defaults (`-b 2048 -ub 512`) underfeed the gfx1151 matmul kernels.

Measured on Qwen3-Coder-Next 80B-A3B Q4_K_XL:

| Metric            | Default `-b 2048 -ub 512` | `-b 4096 -ub 1024` | Delta |
|-------------------|--------------------------:|-------------------:|------:|
| pp4096 d=0        | 625 t/s                   | 730 t/s            | +17% |
| pp4096 d=32K      | 414 t/s                   | 452 t/s            | +9%  |
| tg128             | unchanged                 | unchanged          | —    |

`-ub 1024` is the actual knee. `-ub 2048` is slightly worse, `-ub 4096` significantly worse.
`-b 8192` shows no benefit over `-b 4096`. The 4B sees similar but smaller proportional gains;
short-ctx pp on the 4B is roughly flat because it's so cheap.

**Apply to all Qwen3-class models on this hardware unless the llama.cpp build changes substantially.**

## KV cache quantisation is a regression

**Do NOT use `-ctk q8_0 -ctv q8_0`** on this stack. The standard CUDA-land "q8 KV is free"
wisdom is wrong on RDNA3.5 with this ROCm/llama.cpp combination.

Benched 2026-05-20, tg128 at depth 32K:

| Model                        | Arch                | f16 KV  | q8_0 KV | Regression |
|------------------------------|---------------------|--------:|--------:|-----------:|
| Qwen3-Coder-Next 80B Q4_K_XL | hybrid linear-attn MoE | 34.1 t/s | 28.2 t/s | -17% |
| Qwen3-Coder 30B Q4_K_XL      | dense MoE              | 34.2 t/s | 22.3 t/s | **-35%** |
| Qwen3 4B Q4_K_XL             | dense                  | 28.8 t/s | 23.4 t/s | -19% |

Likely cause: the q8_0 KV path drops off the fast flash-attention kernel and uses a slower
compute fallback. Short-context impact is smaller (~5-9% loss) but still net-negative —
there is no regime where q8_0 KV wins here.

**Quantise weights, not KV.** If memory pressure ever forces KV reduction, drop context
size or `--parallel` count first.

## Concurrent multi-model load characterisation

Firing simultaneous requests against all three endpoints (80B + 30B + 4B) drops tg by
~50% per stream. This is **GPU compute saturation** on the single iGPU — no SR-IOV-style
partitioning, all three contexts share the same compute units.

- Not thermal-bound: 66°C peak under sustained 3-way load
- Not memory-bound: 41 GiB GTT headroom remaining
- Not power-bound: 114 W package power, plenty of envelope on the 130 W TDP

CCR routing is configured so 80B and 30B don't normally race; the 4B is light enough
that HA voice rarely contends with codegen.

## `gpu_busy_percent` is broken on gfx1151

**Trust power draw, not the `gpu_busy_percent` sysfs counter.** Tools like btop and
nvtop that read `/sys/class/drm/card*/device/gpu_busy_percent` will show wildly
misleading utilisation on this hardware.

Reproducible symptom: with all three models loaded but idle (no `is_processing` slots,
0% per-process CPU, **no `drm-engine` entries in fdinfo**), the counter latches at 100%
and the DPM stays at the top step (2900 MHz, ~35 W).

Confirmed via `drm-engine` fdinfo: when the counter says 100%, there are zero engine
submissions from any llama-server process. The driver appears to mis-attribute
GTT-resident memory to compute activity, or fail to clock-gate when multiple ROCm
contexts hold allocations.

| Signal | Idle (no work) | Active inference |
|--------|---------------:|-----------------:|
| Package power | 9-14 W (1 model) → 33 W (3 models) | 100-130 W |
| sclk | 600 MHz (idle) → 2900 MHz (stuck-high) | 2900 MHz |
| `/slots is_processing` | false | true |
| llama-server `%CPU` | ~0% | 100+% per thread |
| **`gpu_busy_percent`** | **unreliable** | **unreliable** |

Real cost of the stuck-high idle state: ~25 W of wasted power (~$3-4/year). Not worth
the engineering effort to fix; just ignore the counter.

## Cold-start cost (80B via llama-swap)

| Path                                        | TTFT   |
|---------------------------------------------|-------:|
| First-ever spawn (cold disk)                | ~45 s  |
| Spawn with warm page cache                  | ~16 s  |
| Warm path (within TTL, model already loaded) | ~120 ms |

`--no-mmap` is kept in the 80B config for deterministic GTT residency. Switching to mmap
would shave a few seconds off the warm-page-cache cold start but is not a meaningful win
for the typical agentic workload pattern (long sessions, infrequent cold starts).

## Toolbox launch quirk

`podman exec -d ... bash -lc 'cd "$HOME" && ./serve.sh'` has intermittently arrived
inside the container without the `cd` segment, causing `./serve.sh: No such file or
directory` because the default cwd is `/`. Quoting / serialisation artefact.

**Fix**: launch via a wrapper script (`bin/launch.sh`) that does its own `cd` before
`exec`-ing serve.sh. Robust against any quoting weirdness.
