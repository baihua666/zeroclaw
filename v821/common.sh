#!/bin/bash

set -euo pipefail

V821_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${V821_DIR}")"

TARGET_TRIPLE="${TARGET_TRIPLE:-riscv32gc-unknown-linux-musl}"
DEFAULT_PROFILE="${DEFAULT_PROFILE:-release-v821}"
DEFAULT_FEATURES="${DEFAULT_FEATURES:-v821}"

DEVICE_BINARY_PATH="${DEVICE_BINARY_PATH:-/mnt/UDISK/zeroclaw}"
DEFAULT_CONFIG_DIR="${DEFAULT_CONFIG_DIR:-/tmp/zc_test_run}"
DEFAULT_PORT="${DEFAULT_PORT:-9091}"
DEFAULT_HOST="${DEFAULT_HOST:-127.0.0.1}"
DEFAULT_LOG_PATH="${DEFAULT_LOG_PATH:-/tmp/zeroclaw_v821_daemon.log}"

print_info() {
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_error() {
    echo "ERROR: $1" >&2
    exit 1
}

require_command() {
    local cmd="$1"
    command -v "${cmd}" >/dev/null 2>&1 || print_error "未找到命令: ${cmd}"
}

device_shell() {
    adb shell sh -lc "$1"
}

device_kill_zeroclaw() {
    device_shell "killall zeroclaw >/dev/null 2>&1 || true"
}
