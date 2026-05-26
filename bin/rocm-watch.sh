#!/bin/bash
# Log GPU state to CSV. Usage: rocm-watch.sh [interval_sec] [output.csv]
# Each row: iso_ts,edge_C,ppt_W,sclk_mhz,gtt_used_gb,gtt_total_gb
INTERVAL="${1:-5}"
OUT="${2:-/home/ramb0t/rocm-watch-$(date +%Y%m%d-%H%M%S).csv}"
echo "ts,edge_C,ppt_W,sclk_mhz,gtt_used_gb,gtt_total_gb" > "$OUT"
echo "logging to $OUT every ${INTERVAL}s (Ctrl+C to stop)"
while true; do
  smi=$(rocm-smi --showtemp --showpower --showclocks --showmeminfo gtt 2>/dev/null)
  edge=$(echo "$smi" | awk -F': ' '/Temperature \(Sensor edge\)/ {print $NF; exit}')
  ppt=$(echo "$smi" | awk -F': ' '/Graphics Package Power/ {print $NF; exit}')
  sclk=$(echo "$smi" | awk '/sclk clock level/ {match($0,/\(([0-9]+)Mhz\)/,a); print a[1]; exit}')
  gtt_used=$(echo "$smi" | awk -F': ' '/GTT Total Used/ {printf "%.2f", $NF/1073741824; exit}')
  gtt_total=$(echo "$smi" | awk -F': ' '/GTT Total Memory/ {printf "%.2f", $NF/1073741824; exit}')
  printf "%s,%s,%s,%s,%s,%s\n" "$(date -Iseconds)" "$edge" "$ppt" "$sclk" "$gtt_used" "$gtt_total" | tee -a "$OUT"
  sleep "$INTERVAL"
done
