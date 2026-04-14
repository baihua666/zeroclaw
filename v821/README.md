# V821 — ZeroClaw on Allwinner V821

全志 V821 (RISC-V 32-bit, Tina Linux) 上运行 ZeroClaw 的完整指南。

## 目录

- [架构概览](#架构概览)
- [环境准备](#环境准备)
- [编译](#编译)
- [发布到全新 V821 设备](#发布到全新-v821-设备)
- [启动运行](#启动运行)
- [日常运维](#日常运维)
- [TLS 说明](#tls-说明)
- [可用模型](#可用模型)
- [API Key 参考](#api-key-参考)

---

## 架构概览

```
┌────────────────────┐
│  浏览器 / 客户端    │
│  http://设备IP:9091 │
└─────────┬──────────┘
          │ HTTP (局域网)
          ▼
┌────────────────────┐
│  V821 设备          │
│  /mnt/UDISK/zeroclaw│
│  daemon 0.0.0.0:9091│
│  provider: qwen-code│
└─────────┬──────────┘
          │ HTTPS 直连
          ▼
┌────────────────────┐
│  阿里百练 API       │
│  coding.dashscope.  │
│  aliyuncs.com       │
└────────────────────┘
```

V821 使用 rustls + aws-lc-rs 直连百练 HTTPS API，无需中转服务。

**前提条件**：V821 无 RTC 电池，开机后系统时间为 1970-01-01，TLS 证书验证会失败。启动脚本会自动同步宿主机时间到设备。

---

## 环境准备

### 开发机（Mac / Linux）

- ADB（USB 连接 V821 设备）
- SSH 到编译服务器：`ssh root@120.24.23.161`

### 编译服务器（120.24.23.161）

- Tina Linux SDK：`/home/tubao/code/v821-tina-v13`
- Rust nightly + `rust-src`（`/root/.cargo/bin/`）
- 交叉编译器：`riscv32-linux-musl-gcc`（Tina SDK 自带）

### V821 设备

- Tina Linux, kernel 5.4.220, RISC-V 32-bit
- WiFi 已连接局域网（例如 `192.168.3.148`）
- 持久存储：`/mnt/UDISK/`（重启不丢失）
- 临时存储：`/tmp/`（重启清空）

---

## 编译

### 编译命令

```bash
# 在编译服务器上
ssh root@120.24.23.161
export PATH=/root/.cargo/bin:$PATH
cd /home/tubao/code/zeroclaw

# 完整编译（含 Web Dashboard，约 20-35 分钟）
./v821/build.sh build

# 仅清理
./v821/build.sh clean
```

### 编译产物

```
target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw
```

- 约 14.8MB，ELF 32-bit RISC-V，动态链接（musl）
- Profile: `release-v821`（thin LTO, opt-level=z, codegen-units=1）
- Feature: `v821`（禁用 prometheus、ring；启用 aws-lc-rs + channels-websocket）

### 编译原理

| 配置项 | 值 |
|--------|-----|
| Target | `riscv32gc-unknown-linux-musl` |
| 编译器 | `cargo +nightly` with `-Z build-std=std,panic_abort` |
| 交叉链接器 | `riscv32-linux-musl-gcc` (Tina SDK) |
| CFLAGS | `-march=rv32imfdcxandes -mabi=ilp32d -mcmodel=medany` |
| LTO | thin（fat LTO 导致链接器 OOM） |
| Feature | `v821`（排除 ring、prometheus 等 64-bit 依赖） |

### V821 feature 下的运行时行为差异

- `tokio::fs` 替换为 `std::fs`（异步文件 I/O 不稳定）
- `Path::exists()` / `Path::is_file()` 替换为 `libc::access()`（路径探测不稳定）
- Daemon 后台任务禁用：`state_writer`、`heartbeat supervisor`、`scheduler supervisor`
- 配置反序列化增加 V821 兼容重试（strip 空数组字段）
- Memory hygiene / hydrate 跳过

---

## 发布到全新 V821 设备

### 一键部署（推荐）

```bash
# 从编译服务器下载二进制并部署（已有编译产物）
./v821/setup-device.sh --api-key sk-sp-xxx

# 先编译再部署（约 20 分钟）
./v821/setup-device.sh --api-key sk-sp-xxx --build

# 使用本地已下载的二进制
./v821/setup-device.sh --api-key sk-sp-xxx --binary /tmp/zeroclaw_v821
```

脚本自动完成 7 个步骤：ADB 检查 → 获取二进制 → 清理设备 → 部署文件（5 项） → 同步时间 → 启动 daemon → 验证（进程/QQ/Gateway/signal 11）。

### 手动部署（逐步）

<details>
<summary>展开手动步骤</summary>

```bash
# 1. 下载编译产物
scp root@120.24.23.161:/home/tubao/code/zeroclaw/target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw /tmp/zeroclaw_v821

# 2. 推送二进制
adb push /tmp/zeroclaw_v821 /mnt/UDISK/zeroclaw
adb shell 'chmod +x /mnt/UDISK/zeroclaw'

# 3. 推送配置和脚本
adb push v821/config-bailian.toml /mnt/UDISK/config-bailian.toml
adb push v821/start_zeroclaw.sh /mnt/UDISK/start_zeroclaw.sh
adb shell 'chmod 755 /mnt/UDISK/start_zeroclaw.sh'

# 4. 写入 API key
echo 'export DASHSCOPE_API_KEY="sk-sp-xxx"
export ZEROCLAW_PROVIDER="qwen-code"
export ZEROCLAW_MODEL="qwen3-coder-next"
export QWEN_OAUTH_RESOURCE_URL="coding.dashscope.aliyuncs.com"' > /tmp/zc.env
adb push /tmp/zc.env /mnt/UDISK/zeroclaw.env

# 5. 部署开机自启
adb push v821/S95zeroclaw /etc/init.d/S95zeroclaw
adb shell 'chmod 755 /etc/init.d/S95zeroclaw'

# 6. 同步时间
adb shell "date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')'"

# 7. 验证
adb shell '/mnt/UDISK/zeroclaw --help'
```

</details>

### 设备端文件清单

| 路径 | 大小 | 说明 |
|------|------|------|
| `/mnt/UDISK/zeroclaw` | ~14.8MB | 主二进制 |
| `/mnt/UDISK/config-bailian.toml` | ~2.1KB | 配置模板（含 QQ 通道、session_persistence=false） |
| `/mnt/UDISK/zeroclaw.env` | ~0.2KB | 环境变量（API key、provider 参数） |
| `/mnt/UDISK/start_zeroclaw.sh` | ~2.9KB | 设备端启动脚本（WiFi + NTP + daemon） |
| `/etc/init.d/S95zeroclaw` | ~1.3KB | 开机自启 init 脚本 |

---

## 启动运行

### 方式 A：开发机脚本（推荐）

```bash
DASHSCOPE_API_KEY=sk-sp-xxx ./v821/run-daemon.sh --lan --bailian --debug
```

脚本会自动：停旧进程 → 同步时间 → 生成启动脚本 → 启动 daemon → 显示状态

### 方式 B：设备端脚本

```bash
# 先同步时间
adb shell "date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')'"

# 启动（在同一个 adb shell 会话中）
adb shell '/mnt/UDISK/start_zeroclaw.sh'
```

### 方式 C：手动启动

```bash
adb shell '
date -u -s "2026-03-30 00:00:00"
ZEROCLAW_ALLOW_PUBLIC_BIND=true \
QWEN_OAUTH_RESOURCE_URL=coding.dashscope.aliyuncs.com \
ZEROCLAW_PROVIDER="qwen-code" \
ZEROCLAW_MODEL="qwen3-coder-next" \
DASHSCOPE_API_KEY="sk-sp-xxx" \
/mnt/UDISK/zeroclaw --config-dir /tmp/zc_run daemon --host 0.0.0.0 --port 9091
'
```

### 访问

1. 获取设备 IP：`adb shell 'ifconfig wlan0 | grep "inet addr"'`
2. 浏览器打开：`http://<设备IP>:9091/`
3. 首次使用需配对（日志中会打印 6 位配对码）

### 注意事项

- **时间同步**：每次设备重启后必须同步时间，否则 TLS 证书验证失败
- **adb 后台进程**：`adb shell` 退出时会杀死后台进程。如需 daemon 持续运行，保持会话不退出，或在设备端 shell 内执行
- **配对码**：每次 daemon 重启后需重新配对（V821 模式下 token 不持久化）
- **配置恢复**：`/tmp/` 下的配置重启后丢失，启动脚本会自动从 `/mnt/UDISK/config-bailian.toml` 恢复

---

## 日常运维

### 更新二进制

```bash
# 1. 编译服务器编译
ssh root@120.24.23.161
export PATH=/root/.cargo/bin:$PATH
cd /home/tubao/code/zeroclaw && ./v821/build.sh build

# 2. 下载到本地
scp root@120.24.23.161:/home/tubao/code/zeroclaw/target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw /tmp/zeroclaw_v821

# 3. 部署到设备
adb shell 'killall zeroclaw 2>/dev/null'
adb push /tmp/zeroclaw_v821 /mnt/UDISK/zeroclaw
adb shell 'chmod +x /mnt/UDISK/zeroclaw'

# 也可使用: ./v821/deploy.sh
```

### 常用诊断命令

```bash
# 设备进程状态
adb shell 'ps | grep zeroclaw'

# 设备内核崩溃记录
adb shell 'dmesg | grep zeroclaw'

# 设备网络状态
adb shell 'ifconfig wlan0'

# 端口监听确认
adb shell 'netstat -tlnp | grep 9091'

# doctor 诊断
adb shell 'ZEROCLAW_V821_DEBUG=1 /mnt/UDISK/zeroclaw --config-dir /tmp/zc_run doctor'

# health 检查
adb shell 'wget -q -O - http://127.0.0.1:9091/health'
```

### 磁盘空间不足（编译服务器）

```bash
ssh root@120.24.23.161
cd /home/tubao/code/zeroclaw
rm -rf target/debug target/riscv32gc-unknown-linux-musl/debug
rm -rf target/riscv32gc-unknown-linux-musl/incremental
```

---

## TLS 说明

### 当前方案

V821 使用 **rustls + aws-lc-rs** 直连 HTTPS，已验证完全可用。

关键前提：**系统时间必须正确**。V821 无 RTC 电池，开机后时间为 1970-01-01，TLS 证书验证会因时间错误而失败。启动脚本会自动从宿主机同步时间。

### 已验证的 HTTPS 访问

| 目标 | 结果 |
|------|------|
| `https://www.baidu.com/` | HTTP 200 |
| `https://httpbin.org/get` | HTTP 200 |
| `https://api.github.com/` | HTTP 200 |
| `https://coding.dashscope.aliyuncs.com/v1/chat/completions` | HTTP 200（对话成功） |

TLS 握手参数：`TLSv1_2, TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`

### 百练 API 接入要点

- Provider：使用 `qwen-code`（而非 `custom:`），它会设置 `User-Agent: QwenCode/1.0`（coding 端点要求）
- 端点覆盖：`QWEN_OAUTH_RESOURCE_URL=coding.dashscope.aliyuncs.com`
- API Key：`DASHSCOPE_API_KEY=sk-sp-xxx`

### 已知限制

- **native-tls (OpenSSL)** 在 rv32 上有 bug（signal 11 空指针崩溃），不可用
- 仅 **rustls + aws-lc-rs** 可用

---

## 可用模型

| 模型 ID | 上下文窗口 | 最大输出 |
|---------|-----------|---------|
| `qwen3-coder-next` | 262,144 | 65,536 |
| `qwen3.5-plus` | 1,000,000 | 65,536 |

默认模型为 `qwen3-coder-next`，可通过配置文件中 `default_model` 切换。

---

## API Key 参考

百练（DashScope Coding）OpenAI 兼容端点：

```
Base URL: https://coding.dashscope.aliyuncs.com/v1
API Key:  sk-sp-85875c80488f42b08302e62f02b688b6
```

---

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `setup-device.sh` | **全新设备一键部署**（推荐入口，含编译/下载/部署/验证） |
| `build.sh` | V821 交叉编译（含 Web Dashboard） |
| `deploy.sh` | 停旧进程 + adb push 新二进制 |
| `deploy-autostart.sh` | 部署启动脚本 + init.d 自启到设备 |
| `run-daemon.sh` | 本地启动设备 daemon（支持 --lan / --bailian / --debug） |
| `start_zeroclaw.sh` | 设备端启动脚本（WiFi 等待 + NTP 时间同步 + daemon） |
| `S95zeroclaw` | 设备 init.d 开机自启脚本 |
| `common.sh` | 共享配置和辅助函数 |
| `config-bailian.toml` | 设备端配置模板（含 QQ 通道 + session_persistence=false） |
