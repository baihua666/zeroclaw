#!/bin/sh
# ZeroClaw V821 设备端启动脚本
# 部署到设备 /mnt/UDISK/start_zeroclaw.sh
#
# 功能:
#   1. 等待 WiFi 网络就绪（获取 IP）
#   2. 通过 NTP 同步系统时间（V821 无 RTC 电池）
#   3. 启动 zeroclaw daemon（局域网模式）
#
# 用法:
#   /mnt/UDISK/start_zeroclaw.sh              # 默认参数
#   /mnt/UDISK/start_zeroclaw.sh /tmp/zc_run  # 自定义 config_dir

CONFIG_DIR="${1:-/mnt/UDISK/zc_data}"
PORT="${2:-9091}"
BINARY="/mnt/UDISK/zeroclaw"
LOG="/tmp/zeroclaw_v821_daemon.log"
NTP_SERVER="ntp.aliyun.com"
WIFI_TIMEOUT=60
NTP_TIMEOUT=15

log() {
    echo "[zeroclaw-init] $(date '+%H:%M:%S') $1"
}

# --- 等待 WiFi 就绪 ---
wait_for_wifi() {
    local elapsed=0
    log "等待 WiFi 网络..."
    while [ $elapsed -lt $WIFI_TIMEOUT ]; do
        local ip
        ip=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | sed 's/.*inet addr:\([0-9.]*\).*/\1/')
        if [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ]; then
            log "WiFi 就绪, IP: $ip"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    log "警告: WiFi 超时(${WIFI_TIMEOUT}s), 继续启动"
    return 1
}

# --- NTP 时间同步 ---
sync_time() {
    log "NTP 时间同步..."
    ntpd -n -q -p "$NTP_SERVER" >/dev/null 2>&1 &
    local ntp_pid=$!
    local elapsed=0
    while [ $elapsed -lt $NTP_TIMEOUT ] && kill -0 "$ntp_pid" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    kill "$ntp_pid" 2>/dev/null
    wait "$ntp_pid" 2>/dev/null

    # 验证时间是否合理（> 2025年 = epoch > 1735689600）
    local now
    now=$(date +%s)
    if [ "$now" -gt 1735689600 ]; then
        log "时间同步成功: $(date)"
        return 0
    else
        log "警告: 时间同步失败, 当前: $(date)"
        return 1
    fi
}

# --- 启动 daemon ---
start_daemon() {
    # 停旧进程
    killall zeroclaw 2>/dev/null
    sleep 1

    # 初始化配置目录
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG_DIR/config.toml" ]; then
        if [ -f /mnt/UDISK/config-bailian.toml ]; then
            cp /mnt/UDISK/config-bailian.toml "$CONFIG_DIR/config.toml"
            log "已复制默认配置"
        else
            log "错误: 未找到配置文件"
            return 1
        fi
    fi

    # 环境变量
    export ZEROCLAW_V821_DEBUG=1
    export ZEROCLAW_ALLOW_PUBLIC_BIND=true

    # 从配置文件旁加载 env 文件（如果存在）
    if [ -f /mnt/UDISK/zeroclaw.env ]; then
        log "加载 /mnt/UDISK/zeroclaw.env"
        . /mnt/UDISK/zeroclaw.env
    fi

    log "启动 daemon (0.0.0.0:$PORT)..."
    exec "$BINARY" --config-dir "$CONFIG_DIR" daemon --host 0.0.0.0 --port "$PORT"
}

# --- 主流程 ---
log "===== ZeroClaw V821 启动 ====="

if [ ! -x "$BINARY" ]; then
    log "错误: 未找到二进制 $BINARY"
    exit 1
fi

wait_for_wifi
sync_time
start_daemon
