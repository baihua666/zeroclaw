#!/bin/bash
# V821 全新设备一键部署脚本
#
# 用法:
#   ./v821/setup-device.sh --api-key sk-sp-xxx
#   ./v821/setup-device.sh --api-key sk-sp-xxx --binary /tmp/zeroclaw_v821
#   ./v821/setup-device.sh --api-key sk-sp-xxx --build
#
# 完整流程:
#   1. 检查 ADB 连接
#   2. 获取二进制（从编译服务器下载 / 本地指定 / 现场编译）
#   3. 清理设备 coredump（释放空间）
#   4. 推送二进制 + 配置 + env + 启动脚本 + init.d 自启
#   5. 同步时间（V821 无 RTC 电池，TLS 前置条件）
#   6. 启动 daemon
#   7. 验证：进程存活 + QQ 连接 + health check + 无新 signal 11

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

V821_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SERVER="root@120.24.23.161"
REMOTE_BINARY="/home/tubao/code/zeroclaw/target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw"
LOCAL_BINARY=""
API_KEY=""
DO_BUILD=0
SKIP_VERIFY=0
PORT="${DEFAULT_PORT}"

print_help() {
    cat <<'HELP'
V821 全新设备一键部署

用法: ./v821/setup-device.sh [options]

必需:
  --api-key KEY        百练 API key（DASHSCOPE_API_KEY）

可选:
  --binary PATH        指定本地二进制路径（跳过从服务器下载）
  --build              先在远端编译再部署（耗时约 20 分钟）
  --port PORT          daemon 端口（默认 9091）
  --skip-verify        跳过部署后验证
  -h, --help           显示帮助
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        --api-key)     API_KEY="$2"; shift 2 ;;
        --binary)      LOCAL_BINARY="$2"; shift 2 ;;
        --build)       DO_BUILD=1; shift ;;
        --port)        PORT="$2"; shift 2 ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help)     print_help; exit 0 ;;
        *)             print_error "未知参数: $1" ;;
    esac
done

[ -n "${API_KEY}" ] || print_error "必须指定 --api-key"
require_command adb

# ── 1. 检查 ADB 连接 ──
print_info "步骤 1/7: 检查 ADB 连接"
adb shell 'echo "V821 connected"' || print_error "ADB 连接失败，请检查 USB 连接"

# ── 2. 获取二进制 ──
print_info "步骤 2/7: 获取二进制"
if [ -n "${LOCAL_BINARY}" ]; then
    echo "使用本地二进制: ${LOCAL_BINARY}"
    [ -f "${LOCAL_BINARY}" ] || print_error "文件不存在: ${LOCAL_BINARY}"
else
    LOCAL_BINARY="/tmp/zeroclaw_v821"

    if [ "${DO_BUILD}" -eq 1 ]; then
        echo "远端编译中（约 20 分钟）..."
        ssh "${BUILD_SERVER}" "source /root/.cargo/env && cd /home/tubao/code/zeroclaw && ./v821/build.sh build"
    fi

    echo "从编译服务器下载..."
    scp "${BUILD_SERVER}:${REMOTE_BINARY}" "${LOCAL_BINARY}"
    [ -f "${LOCAL_BINARY}" ] || print_error "下载失败"
    echo "下载完成: $(ls -lh "${LOCAL_BINARY}" | awk '{print $5}')"
fi

# ── 3. 清理设备 ──
print_info "步骤 3/7: 清理设备"
adb shell '
killall zeroclaw 2>/dev/null
rm -f /mnt/UDISK/coredump-*
rm -rf /tmp/zc_* /tmp/zeroclaw_*
' 2>/dev/null || true
echo "coredump 已清理"

# ── 4. 部署文件 ──
print_info "步骤 4/7: 部署文件到设备"

echo "  [1/5] 推送二进制..."
adb shell 'rm -f /mnt/UDISK/zeroclaw'
adb push "${LOCAL_BINARY}" /mnt/UDISK/zeroclaw
adb shell 'chmod +x /mnt/UDISK/zeroclaw'

echo "  [2/5] 推送配置模板..."
adb push "${V821_DIR}/config-bailian.toml" /mnt/UDISK/config-bailian.toml

echo "  [3/5] 写入 zeroclaw.env..."
ENV_TMP="$(mktemp)"
cat > "${ENV_TMP}" <<ENVEOF
# ZeroClaw V821 环境变量
export DASHSCOPE_API_KEY="${API_KEY}"
export ZEROCLAW_PROVIDER="qwen-code"
export ZEROCLAW_MODEL="qwen3-coder-next"
export QWEN_OAUTH_RESOURCE_URL="coding.dashscope.aliyuncs.com"
ENVEOF
adb push "${ENV_TMP}" /mnt/UDISK/zeroclaw.env
rm -f "${ENV_TMP}"

echo "  [4/5] 推送启动脚本..."
adb push "${V821_DIR}/start_zeroclaw.sh" /mnt/UDISK/start_zeroclaw.sh
adb shell 'chmod 755 /mnt/UDISK/start_zeroclaw.sh'

echo "  [5/5] 部署开机自启..."
adb push "${V821_DIR}/S95zeroclaw" /etc/init.d/S95zeroclaw
adb shell 'chmod 755 /etc/init.d/S95zeroclaw'

echo "部署文件清单:"
adb shell 'ls -la /mnt/UDISK/zeroclaw /mnt/UDISK/config-bailian.toml /mnt/UDISK/zeroclaw.env /mnt/UDISK/start_zeroclaw.sh /etc/init.d/S95zeroclaw 2>/dev/null'

# ── 5. 同步时间 ──
print_info "步骤 5/7: 同步设备时间"
HOST_TIME="$(date -u '+%Y-%m-%d %H:%M:%S')"
adb shell "date -u -s '${HOST_TIME}'"
echo "设备时间已同步: ${HOST_TIME} UTC"

# ── 6. 启动 daemon ──
print_info "步骤 6/7: 启动 daemon"
adb shell "
mkdir -p /tmp/zc_run
cp /mnt/UDISK/config-bailian.toml /tmp/zc_run/config.toml
cat > /tmp/zc_persist.sh << 'ZCEOF'
#!/bin/sh
trap '' HUP
export ZEROCLAW_V821_DEBUG=1
export ZEROCLAW_ALLOW_PUBLIC_BIND=true
. /mnt/UDISK/zeroclaw.env
exec /mnt/UDISK/zeroclaw --config-dir /tmp/zc_run daemon --host 0.0.0.0 --port ${PORT} >> /tmp/zeroclaw_v821_daemon.log 2>&1
ZCEOF
chmod +x /tmp/zc_persist.sh
: > /tmp/zeroclaw_v821_daemon.log
sh /tmp/zc_persist.sh &
sleep 15
ps | grep zeroclaw | grep -v grep && echo 'daemon started' || echo 'WARN: daemon not running'
echo '=== QQ ==='
grep 'QQ:' /tmp/zeroclaw_v821_daemon.log || echo '(no QQ logs yet)'
"

if [ "${SKIP_VERIFY}" -eq 1 ]; then
    print_info "部署完成（跳过验证）"
    exit 0
fi

# ── 7. 验证 ──
print_info "步骤 7/7: 部署验证"
sleep 5

PASS=0
FAIL=0

# 7a. 进程存活
echo -n "  进程存活: "
if adb shell 'ps | grep zeroclaw | grep -v grep' >/dev/null 2>&1; then
    echo "✅"
    PASS=$((PASS + 1))
else
    echo "❌"
    FAIL=$((FAIL + 1))
fi

# 7b. QQ 连接
echo -n "  QQ 通道: "
if adb shell 'grep "QQ: connected and identified" /tmp/zeroclaw_v821_daemon.log' >/dev/null 2>&1; then
    echo "✅ connected"
    PASS=$((PASS + 1))
else
    echo "⏳ connecting (check log later)"
fi

# 7c. Gateway 端口
echo -n "  Gateway 端口: "
if adb shell "grep 'listening on' /tmp/zeroclaw_v821_daemon.log" >/dev/null 2>&1; then
    echo "✅ port ${PORT}"
    PASS=$((PASS + 1))
else
    echo "❌"
    FAIL=$((FAIL + 1))
fi

# 7d. 无新 signal 11
echo -n "  signal 11: "
BEFORE_SIG=$(adb shell 'dmesg | grep "zeroclaw.*signal 11" | wc -l' | tr -d '\r')
sleep 3
AFTER_SIG=$(adb shell 'dmesg | grep "zeroclaw.*signal 11" | wc -l' | tr -d '\r')
if [ "${BEFORE_SIG}" = "${AFTER_SIG}" ]; then
    echo "✅ 无新增"
    PASS=$((PASS + 1))
else
    echo "❌ 新增 signal 11！"
    FAIL=$((FAIL + 1))
fi

# 7e. 设备 IP
DEVICE_IP=$(adb shell "ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*inet addr:\\([0-9.]*\\).*/\\1/'" | tr -d '\r')

echo ""
echo "========================================"
echo "部署结果: ${PASS} passed, ${FAIL} failed"
echo "========================================"
if [ -n "${DEVICE_IP}" ] && [ "${DEVICE_IP}" != "" ]; then
    echo "Web Dashboard: http://${DEVICE_IP}:${PORT}/"
fi
echo "日志: adb shell 'tail -f /tmp/zeroclaw_v821_daemon.log'"
echo "停止: adb shell 'killall zeroclaw'"
echo "自启: adb shell '/etc/init.d/S95zeroclaw start|stop|restart|status'"

if [ "${FAIL}" -gt 0 ]; then
    echo ""
    echo "诊断:"
    echo "  adb shell 'tail -30 /tmp/zeroclaw_v821_daemon.log'"
    echo "  adb shell 'dmesg | grep zeroclaw | tail -10'"
    exit 1
fi
