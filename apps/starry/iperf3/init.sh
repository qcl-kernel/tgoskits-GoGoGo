iperf3_server="${IPERF3_SERVER:-}"
iperf3_port="${IPERF3_PORT:-5201}"
iperf3_duration="${IPERF3_DURATION:-10}"
iperf3_omit="${IPERF3_OMIT:-2}"
iperf3_parallel="${IPERF3_PARALLEL:-1}"
iperf3_block_size="${IPERF3_BLOCK_SIZE:-128K}"
iperf3_output_dir="${IPERF3_OUTPUT_DIR:-/tmp/starry-iperf3}"
iperf3_success_marker="${IPERF3_SUCCESS_MARKER:-STARRY_IPERF3_APP_PASSED}"
iperf3_session_marker="${IPERF3_SESSION_MARKER:-STARRY_IPERF3_APP}"

iperf3_app_failed() {
  printf '\n%s_FAILED\n' "$iperf3_session_marker"
  return 1
}

iperf3_positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

iperf3_nonnegative_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

iperf3_valid_port() {
  iperf3_positive_integer "$1" && [ "$1" -le 65535 ]
}

iperf3_run_profile() {
  profile="$1"
  shift
  result="$iperf3_output_dir/$profile.json"

  printf '\niperf3-app: profile=%s server=%s port=%s duration=%ss omit=%ss parallel=%s block=%s\n' \
    "$profile" "$iperf3_server" "$iperf3_port" "$iperf3_duration" "$iperf3_omit" \
    "$iperf3_parallel" "$iperf3_block_size"
  rm -f "$result"
  if ! iperf3 \
    --client "$iperf3_server" \
    --port "$iperf3_port" \
    --time "$iperf3_duration" \
    --omit "$iperf3_omit" \
    --parallel "$iperf3_parallel" \
    --length "$iperf3_block_size" \
    --connect-timeout 5000 \
    --json \
    "$@" >"$result" 2>&1; then
    cat "$result"
    return 1
  fi

  cat "$result"
  if [ ! -s "$result" ] ||
    grep -q '"error"[[:space:]]*:' "$result" ||
    ! grep -q '"end"[[:space:]]*:' "$result"; then
    return 1
  fi

  printf '%s\n' "STARRY_IPERF3_${profile}_OK"
}

iperf3_app_main() {
  if [ -z "$iperf3_server" ] ||
    ! iperf3_valid_port "$iperf3_port" ||
    ! iperf3_positive_integer "$iperf3_duration" ||
    ! iperf3_nonnegative_integer "$iperf3_omit" ||
    ! iperf3_positive_integer "$iperf3_parallel" ||
    [ -z "$iperf3_block_size" ]; then
    echo "iperf3-app: invalid configuration"
    return 1
  fi

  if ! command -v iperf3 >/dev/null 2>&1; then
    echo "iperf3-app: iperf3 is not installed in the StarryOS rootfs"
    return 1
  fi

  if ! mkdir -p "$iperf3_output_dir"; then
    echo "iperf3-app: cannot create output directory $iperf3_output_dir"
    return 1
  fi

  iperf3 --version
  iperf3_run_profile TCP_UPLOAD || return 1
  iperf3_run_profile TCP_DOWNLOAD --reverse || return 1

  sync
  printf '\n%s\n' "$iperf3_success_marker"
}

iperf3_app_main || iperf3_app_failed
