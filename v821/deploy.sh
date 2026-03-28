#!/bin/bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

BINARY_PATH="${BINARY_PATH:-${ROOT_DIR}/target/${TARGET_TRIPLE}/${DEFAULT_PROFILE}/zeroclaw}"
STOP_FIRST=1

print_help() {
    cat <<'HELP'
ZeroClaw V821 部署脚本

使用方法: ./v821/deploy.sh [options]

选项:
  --binary PATH      指定本地二进制路径
  --device-path PATH 指定设备上的目标路径
  --no-stop          推送前不停止设备上的 zeroclaw
  -h, --help         显示帮助
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --binary)
            BINARY_PATH="$2"
            shift 2
            ;;
        --device-path)
            DEVICE_BINARY_PATH="$2"
            shift 2
            ;;
        --no-stop)
            STOP_FIRST=0
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            print_error "未知参数: $1"
            ;;
    esac
done

require_command adb
[ -f "${BINARY_PATH}" ] || print_error "未找到二进制: ${BINARY_PATH}"

if [ "${STOP_FIRST}" -eq 1 ]; then
    print_info "停止设备上的旧 zeroclaw 进程"
    device_kill_zeroclaw
fi

print_info "推送 V821 二进制到设备"
adb push "${BINARY_PATH}" "${DEVICE_BINARY_PATH}"

print_info "部署完成"
echo "Local:  ${BINARY_PATH}"
echo "Device: ${DEVICE_BINARY_PATH}"
