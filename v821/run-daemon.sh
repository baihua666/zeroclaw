#!/bin/bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

HOST="${DEFAULT_HOST}"
PORT="${DEFAULT_PORT}"
CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
LOG_PATH="${DEFAULT_LOG_PATH}"
EXTRA_ENV_PARTS=()
DEBUG=0
EXPLICIT_API_KEY=""
PROVIDER_OVERRIDE=""
MODEL_OVERRIDE=""
BAILIAN_MODE=0
BAILIAN_BASE_URL="https://coding.dashscope.aliyuncs.com/v1"
BAILIAN_MODEL_DEFAULT="qwen3-coder-next"

shell_quote() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

append_env_if_set() {
    local name="$1"
    local value="${!name:-}"
    if [ -n "${value}" ]; then
        EXTRA_ENV_PARTS+=("${name}=$(shell_quote "${value}")")
    fi
}

append_env_if_set_as() {
    local from_name="$1"
    local to_name="$2"
    local value="${!from_name:-}"
    if [ -n "${value}" ]; then
        EXTRA_ENV_PARTS+=("${to_name}=$(shell_quote "${value}")")
    fi
}

print_help() {
    cat <<'HELP'
ZeroClaw V821 daemon 启动脚本

使用方法: ./v821/run-daemon.sh [options]

选项:
  --lan                 以局域网模式启动，自动传入 0.0.0.0 和 ZEROCLAW_ALLOW_PUBLIC_BIND=true
  --host HOST           自定义监听地址
  --port PORT           自定义端口
  --config-dir PATH     设备上的 config_dir
  --device-path PATH    设备上的 zeroclaw 路径
  --log-path PATH       设备上的日志路径
  --provider NAME       覆盖 default_provider，例如 qwen / openai / custom:https://...
  --model NAME          覆盖 default_model
  --bailian             使用阿里百炼 Coding 兼容端点，默认模型 qwen3-coder-next
  --api-key KEY         显式传入 provider API key，同时注入 OPENROUTER_API_KEY 和 ZEROCLAW_API_KEY
  --debug               打开 ZEROCLAW_V821_DEBUG=1
  -h, --help            显示帮助
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --lan)
            HOST="0.0.0.0"
            EXTRA_ENV_PARTS+=("ZEROCLAW_ALLOW_PUBLIC_BIND=true")
            shift
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --config-dir)
            CONFIG_DIR="$2"
            shift 2
            ;;
        --device-path)
            DEVICE_BINARY_PATH="$2"
            shift 2
            ;;
        --log-path)
            LOG_PATH="$2"
            shift 2
            ;;
        --provider)
            PROVIDER_OVERRIDE="$2"
            shift 2
            ;;
        --model)
            MODEL_OVERRIDE="$2"
            shift 2
            ;;
        --bailian)
            BAILIAN_MODE=1
            shift
            ;;
        --api-key)
            EXPLICIT_API_KEY="$2"
            shift 2
            ;;
        --debug)
            DEBUG=1
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

print_info "停止设备上的旧 zeroclaw 进程"
device_kill_zeroclaw

if [ "${BAILIAN_MODE}" -eq 1 ]; then
    # 使用 qwen-code provider 直连百练 HTTPS
    # qwen-code 会自动设置 User-Agent: QwenCode/1.0（coding 端点要求）
    PROVIDER_OVERRIDE="qwen-code"
    EXTRA_ENV_PARTS+=("QWEN_OAUTH_RESOURCE_URL=coding.dashscope.aliyuncs.com")
    if [ -z "${MODEL_OVERRIDE}" ]; then
        MODEL_OVERRIDE="${BAILIAN_MODEL_DEFAULT}"
    fi
fi

if [ -n "${PROVIDER_OVERRIDE}" ]; then
    EXTRA_ENV_PARTS+=("ZEROCLAW_PROVIDER=$(shell_quote "${PROVIDER_OVERRIDE}")")
fi

if [ -n "${MODEL_OVERRIDE}" ]; then
    EXTRA_ENV_PARTS+=("ZEROCLAW_MODEL=$(shell_quote "${MODEL_OVERRIDE}")")
fi

if [ -n "${EXPLICIT_API_KEY}" ]; then
    EXTRA_ENV_PARTS+=("OPENROUTER_API_KEY=$(shell_quote "${EXPLICIT_API_KEY}")")
    EXTRA_ENV_PARTS+=("ZEROCLAW_API_KEY=$(shell_quote "${EXPLICIT_API_KEY}")")
    EXTRA_ENV_PARTS+=("DASHSCOPE_API_KEY=$(shell_quote "${EXPLICIT_API_KEY}")")
fi

append_env_if_set "OPENROUTER_API_KEY"
append_env_if_set "ZEROCLAW_API_KEY"
append_env_if_set "DASHSCOPE_API_KEY"
append_env_if_set_as "BAILIAN_API_KEY" "ZEROCLAW_API_KEY"
append_env_if_set_as "BAILIAN_API_KEY" "DASHSCOPE_API_KEY"
append_env_if_set "OPENAI_API_KEY"
append_env_if_set "ANTHROPIC_API_KEY"

if [ "${DEBUG}" -eq 1 ]; then
    EXTRA_ENV_PARTS+=("ZEROCLAW_V821_DEBUG=1")
fi

EXTRA_ENV="${EXTRA_ENV_PARTS[*]}"

if [ -z "${EXPLICIT_API_KEY}" ] && [ -z "${OPENROUTER_API_KEY:-}" ] && [ -z "${ZEROCLAW_API_KEY:-}" ] && [ -z "${DASHSCOPE_API_KEY:-}" ] && [ -z "${BAILIAN_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "WARN: 当前未检测到任何 provider API key 环境变量。若 default_provider 需要联网模型，请用 --api-key 或先在本机导出 OPENROUTER_API_KEY/ZEROCLAW_API_KEY 后再启动。" >&2
fi

# V821 无 RTC 电池，开机后系统时间为 1970，TLS 证书验证会失败
# 自动同步宿主机时间到设备
print_info "同步设备时间"
HOST_TIME="$(date -u '+%Y-%m-%d %H:%M:%S')"
device_shell "date -u -s '${HOST_TIME}'"
echo "设备时间已同步: ${HOST_TIME} UTC"

# 生成设备端启动脚本
# 用 adb shell 的单次 heredoc 写入 + 执行，确保后台进程存活
SCRIPT_BODY="#!/bin/sh"$'\n'
for env_entry in "${EXTRA_ENV_PARTS[@]}"; do
    # 去掉 shell_quote 的单引号
    clean_entry="$(echo "${env_entry}" | sed "s/'//g")"
    SCRIPT_BODY+="export ${clean_entry}"$'\n'
done
SCRIPT_BODY+="${DEVICE_BINARY_PATH} --config-dir ${CONFIG_DIR} daemon --host ${HOST} --port ${PORT} >${LOG_PATH} 2>&1 &"

print_info "启动设备 daemon"
# V821 adb shell 限制：后台进程在 adb shell 退出时被杀
# 必须在同一次 adb shell 会话中完成 写入脚本 + 启动 + sleep（保活）+ 状态检查
adb shell "cat > /tmp/zeroclaw_start.sh << 'ZCEOF'
${SCRIPT_BODY}
ZCEOF
chmod 755 /tmp/zeroclaw_start.sh && : >${LOG_PATH} && sh /tmp/zeroclaw_start.sh && sleep 3 && ps | grep zeroclaw | grep -v grep && echo '---' && tail -n 30 ${LOG_PATH}"

echo "Host: ${HOST}"
echo "Port: ${PORT}"
echo "Config Dir: ${CONFIG_DIR}"
echo "Log Path: ${LOG_PATH}"
if [ -n "${PROVIDER_OVERRIDE}" ]; then
    echo "Provider Override: ${PROVIDER_OVERRIDE}"
fi
if [ -n "${MODEL_OVERRIDE}" ]; then
    echo "Model Override: ${MODEL_OVERRIDE}"
fi
