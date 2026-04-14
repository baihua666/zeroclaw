#!/bin/bash
# 部署 ZeroClaw 开机自启到 V821 设备
#
# 用法: ./v821/deploy-autostart.sh [--api-key KEY]
#
# 部署内容:
#   /mnt/UDISK/start_zeroclaw.sh  — 启动脚本（WiFi等待 + NTP时间同步 + daemon启动）
#   /mnt/UDISK/zeroclaw.env       — 环境变量（API key 等，仅首次创建）
#   /etc/init.d/S95zeroclaw       — 开机自启 init 脚本

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

V821_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_KEY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --api-key)
            API_KEY="$2"
            shift 2
            ;;
        -h|--help)
            echo "用法: ./v821/deploy-autostart.sh [--api-key KEY]"
            exit 0
            ;;
        *)
            print_error "未知参数: $1"
            ;;
    esac
done

require_command adb

# 1. 推送启动脚本
print_info "推送 start_zeroclaw.sh"
adb push "${V821_DIR}/start_zeroclaw.sh" /mnt/UDISK/start_zeroclaw.sh
adb shell 'chmod 755 /mnt/UDISK/start_zeroclaw.sh'

# 2. 推送配置文件（不覆盖已有）
HAS_CONFIG=$(device_shell "ls /mnt/UDISK/config-bailian.toml 2>/dev/null && echo YES || echo NO" | tr -d '\r')
if echo "$HAS_CONFIG" | grep -q "NO"; then
    print_info "推送 config-bailian.toml"
    adb push "${V821_DIR}/config-bailian.toml" /mnt/UDISK/config-bailian.toml
else
    echo "config-bailian.toml 已存在，跳过"
fi

# 3. 创建 env 文件（不覆盖已有）
HAS_ENV=$(device_shell "ls /mnt/UDISK/zeroclaw.env 2>/dev/null && echo YES || echo NO" | tr -d '\r')
if [ -n "$API_KEY" ]; then
    print_info "写入 zeroclaw.env"
    ENV_CONTENT="# ZeroClaw 环境变量 - 开机自启时加载
# 使用 qwen-code provider + coding 端点（需要 QWEN_OAUTH_RESOURCE_URL）
export DASHSCOPE_API_KEY=\"${API_KEY}\"
export ZEROCLAW_PROVIDER=\"qwen-code\"
export ZEROCLAW_MODEL=\"qwen3-coder-next\"
export QWEN_OAUTH_RESOURCE_URL=\"coding.dashscope.aliyuncs.com\""
    echo "$ENV_CONTENT" | adb shell "cat > /mnt/UDISK/zeroclaw.env"
elif echo "$HAS_ENV" | grep -q "NO"; then
    echo "提示: 未指定 --api-key，请手动创建 /mnt/UDISK/zeroclaw.env"
else
    echo "zeroclaw.env 已存在，未指定 --api-key 跳过更新"
fi

# 4. 推送 init 脚本
print_info "推送 S95zeroclaw init 脚本"
adb push "${V821_DIR}/S95zeroclaw" /etc/init.d/S95zeroclaw
adb shell 'chmod 755 /etc/init.d/S95zeroclaw'

# 5. 验证
print_info "部署完成，验证"
adb shell 'ls -la /mnt/UDISK/start_zeroclaw.sh /mnt/UDISK/zeroclaw.env /etc/init.d/S95zeroclaw 2>/dev/null'

echo ""
echo "=== 部署成功 ==="
echo "设备重启后 zeroclaw 将自动启动"
echo "手动控制:"
echo "  adb shell '/etc/init.d/S95zeroclaw start'    # 启动"
echo "  adb shell '/etc/init.d/S95zeroclaw stop'     # 停止"
echo "  adb shell '/etc/init.d/S95zeroclaw restart'  # 重启"
echo "  adb shell '/etc/init.d/S95zeroclaw status'   # 状态"
echo ""
echo "日志: adb shell 'tail -f /tmp/zeroclaw_v821_daemon.log'"
