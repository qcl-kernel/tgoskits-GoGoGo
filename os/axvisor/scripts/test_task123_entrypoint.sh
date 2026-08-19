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
printf '%s\n' "${TASK123_NO_NETWORK-UNSET}" > "$TASK123_TEST_ENV"

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

help_arguments="$tmp/help-arguments"
TASK123_TEST_ARGUMENTS="$help_arguments" \
    TASK123_COMPARISON_RUNNER="$fake_runner" "$ENTRYPOINT" --help > "$tmp/help.out" 2>&1
grep -Fq -- 'Usage:' "$tmp/help.out" || fail '--help did not print usage'
[[ ! -e "$help_arguments" ]] ||
    fail 'help invocation started the comparison runner'

if TASK123_TEST_ARGUMENTS="$tmp/invalid-arguments" \
    TASK123_COMPARISON_RUNNER="$fake_runner" "$ENTRYPOINT" --bad-option \
    > "$tmp/invalid.out" 2>&1; then
    fail 'invalid option was accepted'
fi
[[ ! -e "$tmp/invalid-arguments" ]] ||
    fail 'invalid invocation started the comparison runner'

quick="$tmp/quick"
quick_arguments="$tmp/quick-arguments"
quick_environment="$tmp/quick-environment"
TASK123_TEST_ARGUMENTS="$quick_arguments" \
    TASK123_TEST_ENV="$quick_environment" \
    TASK123_COMPARISON_RUNNER="$fake_runner" "$ENTRYPOINT" \
    --quick --allow-qemu-timer-limit --output "$quick" > "$tmp/quick.out"

printf '%s\0' --quick --output "$quick" --allow-qemu-timer-limit > "$tmp/quick-expected-arguments"
cmp -s "$tmp/quick-expected-arguments" "$quick_arguments" ||
    fail 'quick invocation forwarded an unexpected argv sequence'
grep -Fxq '1' "$quick_environment" ||
    fail 'quick invocation did not pass TASK123_NO_NETWORK=1 to the comparison runner'
[[ -s "$quick/fake-runner-called" ]] || fail 'quick output is missing fake marker'
[[ -s "$quick/run.log" ]] || fail 'quick output is missing run.log'

long="$tmp/long"
cache="$tmp/cache/nested"
long_arguments="$tmp/long-arguments"
long_environment="$tmp/long-environment"
TASK123_TEST_ARGUMENTS="$long_arguments" \
    TASK123_TEST_ENV="$long_environment" \
    TASK123_COMPARISON_RUNNER="$fake_runner" "$ENTRYPOINT" \
    --long --cache "$cache" --output "$long" > "$tmp/long.out"

printf '%s\0' --full --output "$long" --cache "$cache" > "$tmp/long-expected-arguments"
cmp -s "$tmp/long-expected-arguments" "$long_arguments" ||
    fail 'long invocation forwarded an unexpected argv sequence'
[[ -s "$long/fake-runner-called" ]] || fail 'long output is missing fake marker'
[[ -s "$long/run.log" ]] || fail 'long output is missing run.log'

printf 'task123 entrypoint contract: PASS\n'
