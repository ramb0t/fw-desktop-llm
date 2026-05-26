# Operations

## Start

```bash
podman exec -d llama-rocm-7.2.3 bash ~/fw-desktop-llm/bin/launch.sh
```

`bin/launch.sh` does `cd "$HOME" && exec ./serve.sh` (assumes the live `serve.sh`
is in `~`; adjust if you make the repo the source of truth).

On first run the 30B and 4B come up in ~5 s each. The 80B does **not** start —
`llama-swap` is listening on 11434 and will spawn it on the first inbound request.

## Verify health

```bash
# All three endpoints respond?
for port in 11434 11435 11436; do
  echo -n "$port: "; curl -s -m 3 http://localhost:$port/v1/models \
    | jq -r '.data[0].id // .models[0].name // "DOWN"'
done

# Processes
pgrep -af "llama-server|llama-swap"

# Real GPU signals (NOT gpu_busy_percent, see findings.md)
rocm-smi --showpower --showclocks --showmeminfo gtt
```

A healthy idle stack with only 30B + 4B loaded shows ~31 GiB GTT and ~9 W package
power. With the 80B also resident: ~85 GiB GTT, 35 W idle.

## Stop

If `serve.sh` is running in a TTY, Ctrl+C triggers its cleanup trap and stops everything.
If it was launched via `podman exec -d`:

```bash
pkill -f llama-swap
pkill -f "Qwen3-Coder"   # kills 30B + 80B (if loaded)
pkill -f "Qwen3-4B"
```

Pkill matching `llama-server` alone misses `llama-swap`, and matching the swap alone
misses its spawned children. Match by model name to be sure.

## Logs

Each server writes to its own file in `~`:

| File                              | Source                                     |
|-----------------------------------|--------------------------------------------|
| `~/llama-swap.log`                | `llama-swap` proxy + spawned 80B output    |
| `~/llama-30b.log`                 | 30B `llama-server`                          |
| `~/llama-4b.log`                  | 4B `llama-server`                           |
| `~/llama-*.log.prev`              | Previous generation (rotated on each restart) |

```bash
# Live tail
tail -F ~/llama-{swap,30b,4b}.log
```

`serve.sh` rotates `~/llama-*.log` → `~/llama-*.log.prev` on every restart, so the
on-disk footprint stays bounded to ~2× the inter-restart usage. At typical traffic
(~500 requests/day) that's well under 100 MB total.

## Adjusting the 80B idle TTL

Edit `ttl:` in `~/llama-swap.yaml`. Because the swap is launched with `-watch-config`,
the change applies on file save without a restart.

- For testing: `ttl: 60` (1 min)
- For normal use: `ttl: 1800` (30 min) — balances unload aggressiveness against cold-start cost

## Probing performance

```bash
~/bin/llm-probe.sh                # default: probe the 80B
~/bin/llm-probe.sh --all          # all three sequentially
~/bin/llm-probe.sh --concurrent   # all three in parallel (worst-case load test)
```

Reports TTFT and tg t/s.

## GPU monitoring

```bash
~/bin/rocm-watch.sh > ~/gpu.csv &  # logs ts,edge_C,ppt_W,sclk,gtt_used_gb,gtt_total_gb
```

**Do not trust** btop / nvtop / `gpu_busy_percent`. Use package power and `sclk` step
as the real load signals. See [findings.md](findings.md#gpu_busy_percent-is-broken-on-gfx1151).

## Troubleshooting

### "Address already in use" on port 11434

Likely Ollama. The Fedora `ollama.service` defaults to port 11434 and conflicts.
```bash
sudo systemctl disable --now ollama
```

### `./serve.sh: No such file or directory` in serve.log

The container's working directory wasn't `$HOME`. Use `bin/launch.sh` rather
than calling `serve.sh` directly via `podman exec`.

### 80B never spawns despite hits on 11434

Check `~/llama-swap.log` for the spawn attempt. Likely causes:
- Model file moved/renamed (check `cmd:` paths in `llama-swap.yaml`)
- llama-swap can't find `llama-server` in PATH — must run inside the toolbox
- `healthCheckTimeout` exceeded (default 300 s); first-ever cold load on a slow disk can
  exceed this — bump to 600 if needed
