#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 QEMU_PID OUTPUT [INTERVAL_MS]" >&2
    exit 2
fi

pid=$1
output=$2
interval_ms=${3:-100}

[[ "$pid" =~ ^[0-9]+$ && "$pid" -ge 1 ]] || {
    echo "QEMU_PID must be a positive integer" >&2
    exit 2
}
[[ "$interval_ms" =~ ^[0-9]+$ && "$interval_ms" -ge 1 && "$interval_ms" -le 60000 ]] || {
    echo "INTERVAL_MS must be an integer from 1 to 60000" >&2
    exit 2
}

output_dir=$(dirname -- "$output")
[[ -d "$output_dir" && -w "$output_dir" ]] || {
    echo "metrics output directory is missing or unwritable: $output_dir" >&2
    exit 2
}

clk_tck=$(getconf CLK_TCK)
start_ns=$(date +%s%N)
sample_count=0
peak_rss_kb=0
max_threads=0
last_cpu_ticks=0

read_sample() {
    local status_file="/proc/$pid/status"
    local stat_file="/proc/$pid/stat"
    local rss
    local threads
    local cpu_ticks
    [[ -r "$status_file" && -r "$stat_file" ]] || return 1

    rss=$(awk '/^VmHWM:/ {print $2; found=1} END {if (!found) exit 1}' "$status_file") ||
        rss=$(awk '/^VmRSS:/ {print $2; found=1} END {if (!found) exit 1}' "$status_file")
    threads=$(awk '/^Threads:/ {print $2; found=1} END {if (!found) exit 1}' "$status_file")
    cpu_ticks=$(awk '{print $14 + $15}' "$stat_file")

    [[ "$rss" =~ ^[0-9]+$ && "$threads" =~ ^[0-9]+$ && "$cpu_ticks" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        return 1
    ((rss > peak_rss_kb)) && peak_rss_kb=$rss
    ((threads > max_threads)) && max_threads=$threads
    last_cpu_ticks=${cpu_ticks%.*}
    sample_count=$((sample_count + 1))
    return 0
}

interval_seconds=$(printf '%d.%03d' $((interval_ms / 1000)) $((interval_ms % 1000)))
while kill -0 "$pid" 2>/dev/null; do
    read_sample || true
    sleep "$interval_seconds"
done
read_sample || true

end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
cpu_time_ms=$(( (last_cpu_ticks * 1000) / clk_tck ))

tmp="$output.tmp.$$"
trap 'rm -f -- "$tmp"' EXIT
{
    printf 'schema=1\n'
    printf 'qemu_pid=%s\n' "$pid"
    printf 'elapsed_ms=%s\n' "$elapsed_ms"
    printf 'cpu_time_ms=%s\n' "$cpu_time_ms"
    printf 'peak_rss_kb=%s\n' "$peak_rss_kb"
    printf 'max_threads=%s\n' "$max_threads"
    printf 'sample_count=%s\n' "$sample_count"
    printf 'interval_ms=%s\n' "$interval_ms"
} > "$tmp"
mv -- "$tmp" "$output"
trap - EXIT
