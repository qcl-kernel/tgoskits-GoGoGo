#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)"
ENTRYPOINT="$ROOT/run-task123.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'task123 entrypoint contract: FAIL: %s\n' "$*" >&2
    exit 1
}

fake_runner="$tmp/fake-comparison-runner"
cat > "$fake_runner" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

printf '%s\0' "$@" > "$TASK123_TEST_ARGUMENTS"

output=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            output=$2
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "$output" ]]
mkdir -p -- "$output"
printf 'fake runner called\n' > "$output/fake-runner-called"
EOF
chmod 0755 "$fake_runner"

TASK123_TEST_ARGUMENTS="$tmp/help-arguments" "$ENTRYPOINT" --help > "$tmp/help.out"
grep -Fq -- 'Usage:' "$tmp/help.out" || fail '--help did not print usage'

if TASK123_TEST_ARGUMENTS="$tmp/invalid-arguments" \
    TASK123_COMPARISON_RUNNER="$fake_runner" "$ENTRYPOINT" --bad-option \
    > "$tmp/invalid.out" 2>&1; then
    fail 'invalid option was accepted'
fi
[[ ! -s "$tmp/invalid-arguments" ]] ||
    fail 'invalid invocation started the comparison runner'

quick="$tmp/quick"
quick_arguments="$tmp/quick-arguments"
TASK123_TEST_ARGUMENTS="$quick_arguments" \
    TASK123_COMPARISON_RUNNER="$fake_runner" "$ENTRYPOINT" \
    --quick --allow-qemu-timer-limit --output "$quick" > "$tmp/quick.out"

tr '\0' '\n' < "$quick_arguments" > "$tmp/quick-arguments.txt"
grep -Fxq -- '--quick' "$tmp/quick-arguments.txt" ||
    fail 'quick invocation did not forward --quick'
grep -Fxq -- '--allow-qemu-timer-limit' "$tmp/quick-arguments.txt" ||
    fail 'quick invocation did not forward --allow-qemu-timer-limit'
grep -Fxq -- '--output' "$tmp/quick-arguments.txt" ||
    fail 'quick invocation did not forward --output'
grep -Fxq -- "$quick" "$tmp/quick-arguments.txt" ||
    fail 'quick invocation forwarded the wrong output directory'
[[ -s "$quick/fake-runner-called" ]] || fail 'quick output is missing fake marker'
[[ -s "$quick/run.log" ]] || fail 'quick output is missing run.log'

long="$tmp/long"
cache="$tmp/cache/nested"
long_arguments="$tmp/long-arguments"
TASK123_TEST_ARGUMENTS="$long_arguments" \
    TASK123_COMPARISON_RUNNER="$fake_runner" "$ENTRYPOINT" \
    --long --cache "$cache" --output "$long" > "$tmp/long.out"

tr '\0' '\n' < "$long_arguments" > "$tmp/long-arguments.txt"
grep -Fxq -- '--full' "$tmp/long-arguments.txt" ||
    fail 'long invocation did not map to --full'
grep -Fxq -- '--cache' "$tmp/long-arguments.txt" ||
    fail 'long invocation did not forward --cache'
grep -Fxq -- "$cache" "$tmp/long-arguments.txt" ||
    fail 'long invocation forwarded the wrong cache directory'
[[ -s "$long/fake-runner-called" ]] || fail 'long output is missing fake marker'
[[ -s "$long/run.log" ]] || fail 'long output is missing run.log'

printf 'task123 entrypoint contract: PASS\n'
