#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
HISTORY_DOCS_ROOT="${HISTORY_DOCS_ROOT:-$ROOT/../history-docs}"
if [[ ! -d "$HISTORY_DOCS_ROOT" ]]; then
    printf 'SKIP: history docs archive is not present: %s\n' "$HISTORY_DOCS_ROOT"
    exit 0
fi
REALTIME="$HISTORY_DOCS_ROOT/task12/report/2026-08-17/starryos-replace/docs/docs/build/axvisor/rtthread-realtime-report.md"
REPORT="$HISTORY_DOCS_ROOT/task123/report/2026-08-17/starryos-replace/docs/docs/build/axvisor/task123-test-report.md"
GUIDE="$HISTORY_DOCS_ROOT/task123/guide/2026-08-18/starryos-replace/docs/docs/build/axvisor/task123-reproduction-cn.md"
REPRODUCER="$ROOT/os/axvisor/scripts/reproduce_task123.sh"
REPRODUCER_TEST="$ROOT/os/axvisor/scripts/test_reproduce_task123.sh"
NATIVE_RUNNER="$ROOT/run-native.sh"
NATIVE_RUNNER_TEST="$ROOT/os/axvisor/scripts/test_run_native.sh"
failures=0

fail() {
    printf 'test_task123_docs_contract: FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}

require_file() {
    local file=$1
    [[ -s "$file" ]] || fail "missing or empty ${file#$ROOT/}"
}

require_literal() {
    local file=$1
    local text=$2
    [[ -f "$file" ]] && grep -F -- "$text" "$file" >/dev/null ||
        fail "${file#$ROOT/} is missing: $text"
}

require_regex() {
    local file=$1
    local pattern=$2
    [[ -f "$file" ]] && grep -E -- "$pattern" "$file" >/dev/null ||
        fail "${file#$ROOT/} does not match: $pattern"
}

reject_regex() {
    local file=$1
    local pattern=$2
    if [[ -f "$file" ]] && grep -E -- "$pattern" "$file" >/dev/null; then
        fail "${file#$ROOT/} contains forbidden current claim: $pattern"
    fi
}

verify_hash_if_present() {
    local relative_path=$1
    local expected=$2
    local file="$ROOT/$relative_path"
    local actual
    if [[ ! -f "$file" ]]; then
        fail "partial evidence set is missing $relative_path"
        return
    fi
    actual="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] ||
        fail "$relative_path hash mismatch: expected $expected, got $actual"
}

for file in "$REALTIME" "$REPORT" "$GUIDE" "$REPRODUCER" "$REPRODUCER_TEST" \
    "$NATIVE_RUNNER" "$NATIVE_RUNNER_TEST"; do
    require_file "$file"
done
[[ -x "$REPRODUCER" ]] || fail "os/axvisor/scripts/reproduce_task123.sh is not executable"
[[ -x "$REPRODUCER_TEST" ]] || fail "os/axvisor/scripts/test_reproduce_task123.sh is not executable"
[[ -x "$NATIVE_RUNNER" ]] || fail "run-native.sh is not executable"
[[ -x "$NATIVE_RUNNER_TEST" ]] ||
    fail "os/axvisor/scripts/test_run_native.sh is not executable"

# Pinned source and host identities.
for file in "$REPORT" "$GUIDE"; do
    require_literal "$file" '7e25b6ceeb8a1613705b90d47969482479a10dda'
    require_literal "$file" 'feat/axvisor-task123'
    require_literal "$file" 'ddf52e2cdd977f14fc04035c88672ac204aec713'
    require_literal "$file" 'RT-Thread 5.2.2'
    require_literal "$file" 'QEMU 11.0.2'
done
for file in "$REALTIME" "$REPORT" "$GUIDE"; do
    require_literal "$file" '受测 runtime'
    require_literal "$file" '7e25b6ceeb8a1613705b90d47969482479a10dda'
done
for token in 'Ubuntu 24.04' '6.17.0-40' '2026-07-14' 'uv 0.11.16' '13.3.0'; do
    require_literal "$GUIDE" "$token"
done

# CPU, memory, network, interrupt path, and prohibited shortcuts.
for token in \
    'phys_cpu_ids=[0,1]' '0b1011' 'pCPU 0/1/3' \
    'phys_cpu_ids=[2]' '0b0100' 'pCPU 2' 'busy WFI' \
    '0x80000000..0x9fffffff' '0xa0000000..0xafffffff' \
    '52:54:00:77:00:01' '52:54:00:77:00:03' \
    '192.168.77.11/24' '192.168.77.30/24' 'UDP 9876' 'UDP 9877' \
    'virtio-net' 'VGIC SPI' '即时事件路径' \
    '无 gateway' '无 NAT' '无 TAP' '无 bridge' '无 firewall 入站规则' \
    '禁止使用共享内存' 'HyperCall' 'raw MMIO' 'vsock' \
    '其他非网络应用数据通道'; do
    require_literal "$GUIDE" "$token"
done

# Current completion claims. Task 1 must remain below 100 percent.
require_regex "$REPORT" '\|[[:space:]]*Task 1[[:space:]]*\|[[:space:]]*95%'
require_regex "$REPORT" '\|[[:space:]]*Task 2[[:space:]]*\|[[:space:]]*100%'
require_regex "$REPORT" '\|[[:space:]]*Task 3[[:space:]]*\|[[:space:]]*100%'
reject_regex "$REPORT" '\|[[:space:]]*(Task 1|任务一)[^|]*\|[[:space:]]*\*\*?100%'
for token in '严格长稳门禁未通过' '不宣称硬实时'; do
    require_literal "$REPORT" "$token"
done

# Realtime suite r5 and current-head Task 2 evidence.
for token in \
    'realtime-suite-r5-final/manifest.txt' 'realtime-suite-r5-final/summary.json' \
    'realtime-suite-r5-final/frames.csv' 'realtime-suite-r5-final/console.log' \
    '5.456/36.592/464.912 us' '5.872/34.288/301.456 us' \
    '6.240/42.832/349.664 us' '4.448/5.120/698.016 us' \
    '76.800/86.784/270.000 us' 'miss_1ms=0' \
    '64 B | 3/8/61 ms' '256 B | 3/7/57 ms' '1024 B | 2/3/11 ms' \
    '64 B | 3/4/30 ms' '256 B | 1/3/11 ms' '1024 B | 2/3/31 ms' \
    '1000/1000' '221 ms'; do
    require_literal "$REALTIME" "$token"
done

# All four accepted 300 s observations remain explicit FAIL evidence.
for token in \
    'stability-300s/console.log' '3.636208 ms' 'miss_1ms=14' \
    'stability-300s-r2-timerslack1/console.log' '2.722352 ms' 'miss_1ms=4' \
    'stability-300s-r3-timerslack1/console.log' '5.406368 ms' 'miss_1ms=29' \
    'stability-300s-r4-low-host-load/console.log' '2.353616 ms' 'miss_1ms=2' \
    'expected=299999 collected=299999 missing=0' '90000/90000' \
    'timer slack 1 ns' '811.904 us' 'timer slack 50000 ns' '1.698896 ms' \
    'QEMU timer assert 前' 'TCG 调度等待' 'ulimit' '宿主 affinity 反而退化'; do
    require_literal "$REALTIME" "$token"
done
for token in \
    'CPU 负载分布' '99.28%' '0.54%' '99.56%' '0.00%' \
    '同 QEMU 历史对比' '21.024/83.248/98.240 us' \
    '原生 RT-Thread 基线' '8.432 us' '692.672 us' \
    'Linux Image' 'Linux initramfs' 'RT-Thread normal image'; do
    require_literal "$REALTIME" "$token"
done
require_regex "$REALTIME" 'stability-300s[^|]*\|[^\n]*FAIL'
require_regex "$REALTIME" 'stability-300s-r2-timerslack1[^|]*\|[^\n]*FAIL'
require_regex "$REALTIME" 'stability-300s-r3-timerslack1[^|]*\|[^\n]*FAIL'
require_regex "$REALTIME" 'stability-300s-r4-low-host-load[^|]*\|[^\n]*FAIL'

# Task 3 normal/fault metrics and clock semantics.
for token in \
    '1200/1200' 'errors=0' 'timeouts=0' 'retries=0' 'duplicates=0' 'reconnects=0' \
    '593/600=98.8333%' '607/903/1042/1520 us' '6142/30784/30954/31522 us' \
    '95/267/289/320 us' '9809' '6065' '38.17%' '240 B/s' \
    'settling successes=0' '未形成有效稳定时间结论' \
    'drop-control' 'drop-status' 'duplicate-frame' 'delayed-server' 'malformed' \
    'retry=1' 'duplicates=1' 'application errors=2' 'applied_delta=0' \
    'CLOCK_MONOTONIC_RAW' 'architectural counter' '不声明单向跨 guest latency' \
    'task3-normal/manifest.txt' 'task3-normal/summary.json' \
    'task3-normal/frames.csv' 'task3-normal/console.log' \
    'task3-faults/fault-summary.json' 'result_gate=PASS'; do
    require_literal "$REPORT" "$token"
done

# Reproduction workflow, modes, outputs, markers, diagnosis, and hashes.
for token in \
    'apt-get install' 'uv run --with scons' 'prepare_rtthread_source.sh' \
    'apply-rtthread-patches.sh' 'build_model.sh' 'build_linux.sh' \
    'cargo xtask axvisor build' 'TASK123_TIMEOUT_S' 'QEMU_TIMER_SLACK_NS' \
    '--mode smoke' '--mode realtime-suite' '--mode stability' '--mode task3' \
    '--mode task3-fault' 'drop-control drop-status duplicate-frame delayed-server malformed' \
    'tmp/task123-results/realtime-suite-r5-final' 'tmp/task123-results/stability-300s' \
    'tmp/task123-results/task3-normal' 'tmp/task123-results/task3-faults' \
    'TASK123_LINUX_NET_READY' 'TASK2_LINUX_END status=PASS' \
    'TASK3_LINUX_END status=PASS' 'TASK123_LINUX_END status=PASS' \
    'RTBENCH_END status=PASS' 'result_gate=PASS' 'sha256sum' \
    'Docker 会增加调度噪声' '不是权威实时环境' 'QEMU TCG' \
    '故障诊断'; do
    require_literal "$GUIDE" "$token"
done

for token in \
    'reproduce_task123.sh' '--quick' '--full' '100 样本实时性 suite' \
    '1000 样本实时性 suite' '300 秒长稳' '600+600 帧 Task 3' \
    'task123-quick-evidence.tar.gz' 'task123-full-evidence.tar.gz' \
    'PASS_WITH_QEMU_TIMER_LIMIT' 'miss_1ms' '默认直接在宿主运行'; do
    require_literal "$GUIDE" "$token"
done
for token in \
    './run-native.sh smoke' './run-native.sh suite' './run-native.sh stability' \
    'tmp/native-runs' '--output' 'NATIVE_INPUT_DIR' 'RTTHREAD_SRC' \
    'qemu-system-aarch64' '不需要预先设置环境变量'; do
    require_literal "$GUIDE" "$token"
done
for token in \
    'profile=quick' 'profile=${1#--}' 'RTBENCH_STABILITY_END status=FAIL' \
    'TASK123_LINUX_END status=PASS' 'PASS_WITH_QEMU_TIMER_LIMIT' \
    'task123-${profile}-evidence.tar.gz'; do
    require_literal "$REPRODUCER" "$token"
done

for token in \
    'LINUX_RUNTIME_DIR="$(mktemp -d' \
    'RTTHREAD_RUNTIME_DIR="$(mktemp -d' \
    'generate_linux_vmconfig.sh' 'generate_rtthread_vmconfig.sh' \
    '--vmconfigs "$LINUX_VMCONFIG"' '--vmconfigs "$RTTHREAD_VMCONFIG"'; do
    require_literal "$GUIDE" "$token"
done
reject_regex "$GUIDE" '/generated/(linux|rtthread)-net\.toml'

for hash in \
    '0eb333c1c83b3d596fdc48022529a844922db3da439948bfe246d353fb8f95e6' \
    '11fa72c85130635d0ca939c25d90a1df4bf21501deb34fdfef005db7e7a2f0aa' \
    'aaedefbe5599c172543f67dea56df4b7a996546c76b263455573fc0ea7f5e2e7' \
    '005ae9526cfba29c43b0f62a81292c1eead483ca44b63f76c3ccee2c96774147' \
    'ee54a3d3da08eeb5a0c07cad991644eb0899facc8bfe8d0c7b9969f42a125179'; do
    require_literal "$REPORT" "$hash"
    require_literal "$GUIDE" "$hash"
done
for file in "$REALTIME" "$REPORT" "$GUIDE"; do
    require_literal "$file" \
        '5e2f220eeb7e22bbd540172c77d9818a606f9d0228e81ae8025acc792c5a62ba'
done

for hash in \
    'ddfda7b2051d95af499f720ba4f29eda702a51dd8d4881d91854092bba967e91' \
    '7daba98a12278352bb927f11241e22cb4fa11a000c7601959d030452ddc8f882' \
    '31ce71aaf87d6916da50aefc2b80afcc3cfa172d8eeebbfe2b7a98e1a33f8574' \
    '32a567eb8fd3544175bc97999804fc5dcd349625549d8840f5e0d2de7dcc6dc8' \
    '55fa19d2206012f6a7278363ce05d92f2b513caa60930bdb70474dc82a8cd0f8'; do
    require_literal "$REPORT" "$hash"
    require_literal "$GUIDE" "$hash"
done

# Requirement/evidence traceability table for all three tasks.
require_literal "$REPORT" '| requirement | implementation/config | verification command | accepted artifact/marker | status |'
for token in \
    'Task 1 topology' 'Task 1 memory/device' 'Task 1 timer' \
    'Task 1 callback execution' 'Task 1 preemption' 'Task 1 SGI interrupt' \
    'Task 1 long stability' 'Task 1 CPU load' 'Task 1 RTOS baseline' \
    'Task 2 IP topology' 'Task 2 protocol fields' 'Task 2 bidirectional RT-IPC' \
    'Task 2 64-byte load' 'Task 2 256-byte load' 'Task 2 1024-byte load' \
    'Task 2 timeout/retransmit' 'Task 2 disconnect recovery' \
    'Task 3 AI inference' 'Task 3 network control' 'Task 3 observable output' \
    'Task 3 fixed baseline' 'Task 3 AI improvement' 'Task 3 request gate' \
    'Task 3 accuracy gate' 'Task 3 tracking gate' 'Task 3 clock method' \
    'Task 3 settling' 'Task 3 faults'; do
    require_literal "$REPORT" "$token"
done

# A clean clone checks prose only. Once any accepted output is present, require
# and authenticate the complete evidence set instead of accepting a partial set.
evidence_paths=(
    tmp/task123-results/task3-normal/manifest.txt
    tmp/task123-results/task3-normal/summary.json
    tmp/task123-results/task3-normal/frames.csv
    tmp/task123-results/task3-normal/console.log
    tmp/task123-results/realtime-suite-r5-final/manifest.txt
    tmp/task123-results/stability-300s/console.log
    tmp/task123-results/stability-300s-r2-timerslack1/console.log
    tmp/task123-results/stability-300s-r3-timerslack1/console.log
    tmp/task123-results/stability-300s-r4-low-host-load/console.log
    tmp/task123-results/task3-faults/fault-summary.json
    tmp/task123-results/task123-evidence-7e25b6cee.tar.gz
)
evidence_present=0
for evidence_path in "${evidence_paths[@]}"; do
    if [[ -e "$ROOT/$evidence_path" ]]; then
        evidence_present=1
        break
    fi
done

if (( evidence_present )); then
verify_hash_if_present \
    tmp/task123-results/task3-normal/manifest.txt \
    0eb333c1c83b3d596fdc48022529a844922db3da439948bfe246d353fb8f95e6
verify_hash_if_present \
    tmp/task123-results/task3-normal/summary.json \
    11fa72c85130635d0ca939c25d90a1df4bf21501deb34fdfef005db7e7a2f0aa
verify_hash_if_present \
    tmp/task123-results/task3-normal/frames.csv \
    aaedefbe5599c172543f67dea56df4b7a996546c76b263455573fc0ea7f5e2e7
verify_hash_if_present \
    tmp/task123-results/task3-normal/console.log \
    005ae9526cfba29c43b0f62a81292c1eead483ca44b63f76c3ccee2c96774147
verify_hash_if_present \
    tmp/task123-results/realtime-suite-r5-final/manifest.txt \
    ee54a3d3da08eeb5a0c07cad991644eb0899facc8bfe8d0c7b9969f42a125179
verify_hash_if_present \
    tmp/task123-results/stability-300s/console.log \
    ddfda7b2051d95af499f720ba4f29eda702a51dd8d4881d91854092bba967e91
verify_hash_if_present \
    tmp/task123-results/stability-300s-r2-timerslack1/console.log \
    7daba98a12278352bb927f11241e22cb4fa11a000c7601959d030452ddc8f882
verify_hash_if_present \
    tmp/task123-results/stability-300s-r3-timerslack1/console.log \
    31ce71aaf87d6916da50aefc2b80afcc3cfa172d8eeebbfe2b7a98e1a33f8574
verify_hash_if_present \
    tmp/task123-results/stability-300s-r4-low-host-load/console.log \
    32a567eb8fd3544175bc97999804fc5dcd349625549d8840f5e0d2de7dcc6dc8
verify_hash_if_present \
    tmp/task123-results/task3-faults/fault-summary.json \
    55fa19d2206012f6a7278363ce05d92f2b513caa60930bdb70474dc82a8cd0f8
verify_hash_if_present \
    tmp/task123-results/task123-evidence-7e25b6cee.tar.gz \
    5e2f220eeb7e22bbd540172c77d9818a606f9d0228e81ae8025acc792c5a62ba
fi

if (( failures > 0 )); then
    printf 'test_task123_docs_contract: %d contract check(s) failed\n' "$failures" >&2
    exit 1
fi

echo 'PASS: Task 1/2/3 Chinese documentation contract'
