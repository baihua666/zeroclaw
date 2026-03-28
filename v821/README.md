# V821 — ZeroClaw on Allwinner V821

全志 V821 (RISC-V 32-bit, Tina Linux) 上运行 ZeroClaw 的完整指南。

## 目录

- [架构概览](#架构概览)
- [环境准备](#环境准备)
- [编译](#编译)
- [Relay 部署](#relay-部署)
- [发布到全新 V821 设备](#发布到全新-v821-设备)
- [启动运行](#启动运行)
- [日常运维](#日常运维)
- [TLS 不可用根因分析](#tls-不可用根因分析)
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
│  provider: custom:  │
│  http://云服务器:    │
│  19091/v1           │
└─────────┬──────────┘
          │ HTTP (公网)
          ▼
┌────────────────────┐
│  云服务器 relay      │
│  120.24.23.161:19091│
│  bailian-relay.js   │
│  (systemd 常驻)     │
│  注入 API key       │
└─────────┬──────────┘
          │ HTTPS
          ▼
┌────────────────────┐
│  阿里百练 API       │
│  coding.dashscope.  │
│  aliyuncs.com       │
└────────────────────┘
```

**为什么需要 relay？** V821 平台 TLS 栈完全不可用（详见 [TLS 不可用根因分析](#tls-不可用根因分析)），设备无法直连任何 HTTPS 端点。relay 做 HTTP→HTTPS 中转，是该平台唯一可行的联网方案。

---

## 环境准备

### 开发机（Mac / Linux）

- ADB（USB 连接 V821 设备）
- SSH 到云服务器：`ssh root@120.24.23.161`

### 云服务器（120.24.23.161）

- Node.js（v18+，当前 v24.14.0）
- Tina Linux SDK：`/home/tubao/code/v821-tina-v13`
- Rust nightly + `rust-src`（安装在 root 用户 `/root/.cargo/bin/`）
- 交叉编译器：`riscv32-linux-musl-gcc`（Tina SDK 自带）

### V821 设备

- Tina Linux, kernel 5.4.220, RISC-V 32-bit
- WiFi 已连接局域网（例如 `192.168.3.148`）
- 持久存储：`/mnt/UDISK/`（重启不丢失）
- 临时存储：`/tmp/`（重启清空）
- 已有系统库：`/usr/lib/libssl.so.1.1`, `/usr/lib/libcrypto.so.1.1`（但 TLS 不可用）
- 已有 CA 证书：`/etc/ssl/certs/ca-certificates.crt`（3293 行，有效）

---

## 编译

### 前提条件

云服务器上需要：

```bash
# 检查 Tina SDK
ls /home/tubao/code/v821-tina-v13/prebuilt/rootfsbuilt/riscv/nds32le-linux-musl-v5d/bin/riscv32-linux-musl-gcc

# 检查 Rust
export PATH=/root/.cargo/bin:$PATH
rustup +nightly component list --installed | grep rust-src
# 如果没有: rustup +nightly component add rust-src
```

### 编译命令

```bash
# 在云服务器上
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

- 约 14.5MB，ELF 32-bit RISC-V，静态链接（musl）
- Profile: `release-v821`（thin LTO, opt-level=z, codegen-units=1）
- Feature: `v821`（禁用 prometheus、websocket、ring；启用 aws-lc-rs）

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

## Relay 部署

### 首次部署（一次性）

```bash
ssh root@120.24.23.161

# 创建 systemd 服务
cat > /etc/systemd/system/bailian-relay.service << 'EOF'
[Unit]
Description=Bailian API Relay (HTTP→HTTPS) for V821
After=network.target

[Service]
Type=simple
Environment=DASHSCOPE_API_KEY=sk-sp-85875c80488f42b08302e62f02b688b6
Environment=RELAY_HOST=0.0.0.0
Environment=RELAY_PORT=19091
ExecStart=/usr/local/bin/node /home/tubao/code/zeroclaw/v821/bailian-relay.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动
systemctl daemon-reload
systemctl enable bailian-relay
systemctl start bailian-relay
```

### 验证 relay

```bash
# 在云服务器上
systemctl status bailian-relay

# 从任意机器
curl http://120.24.23.161:19091/v1/models
# 预期: 404（正常，说明 relay 在运行）
```

### 日常管理

```bash
systemctl status bailian-relay    # 查看状态
systemctl restart bailian-relay   # 重启
systemctl stop bailian-relay      # 停止
journalctl -u bailian-relay -f    # 实时日志
journalctl -u bailian-relay -n 50 # 最近 50 条日志
```

### 在全新服务器上部署 relay

#### 前提条件

- Linux 服务器，有公网 IP
- Node.js v18+（需要全局 `fetch` API）
- 端口 19091 可被 V821 设备访问（检查安全组/防火墙）

#### 步骤

```bash
# 1. 安装 Node.js（如果没有）
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node --version  # 确认 v18+

# 2. 上传 relay 脚本
mkdir -p /opt/zeroclaw-relay
# 将 v821/bailian-relay.js 复制到服务器：
scp v821/bailian-relay.js root@<新服务器IP>:/opt/zeroclaw-relay/bailian-relay.js

# 3. 创建 systemd 服务
cat > /etc/systemd/system/bailian-relay.service << 'EOF'
[Unit]
Description=Bailian API Relay (HTTP→HTTPS) for V821
After=network.target

[Service]
Type=simple
Environment=DASHSCOPE_API_KEY=sk-sp-85875c80488f42b08302e62f02b688b6
Environment=RELAY_HOST=0.0.0.0
Environment=RELAY_PORT=19091
ExecStart=/usr/local/bin/node /opt/zeroclaw-relay/bailian-relay.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# 4. 启用并启动
systemctl daemon-reload
systemctl enable bailian-relay
systemctl start bailian-relay

# 5. 验证
systemctl status bailian-relay
curl http://localhost:19091/v1/models  # 预期 404（正常）
```

#### systemd 服务参数说明

| 参数 | 值 | 说明 |
|------|-----|------|
| `DASHSCOPE_API_KEY` | `sk-sp-...` | 百练 API key，也可用 `BAILIAN_API_KEY` 或 `ZEROCLAW_API_KEY` |
| `RELAY_HOST` | `0.0.0.0` | 监听地址，`0.0.0.0` 表示接受所有来源 |
| `RELAY_PORT` | `19091` | 监听端口 |
| `BAILIAN_BASE_URL` | (可选) | 上游 API 地址，默认 `https://coding.dashscope.aliyuncs.com` |
| `Restart=always` | — | 进程异常退出后自动重启 |
| `RestartSec=5` | — | 重启间隔 5 秒 |

#### 更换 API key

```bash
# 编辑 service 文件
vim /etc/systemd/system/bailian-relay.service
# 修改 Environment=DASHSCOPE_API_KEY=新的key

# 重新加载并重启
systemctl daemon-reload
systemctl restart bailian-relay
```

#### 更换上游 API（非百练）

relay 支持任何 OpenAI 兼容端点。通过 `BAILIAN_BASE_URL` 环境变量指定：

```bash
# 例如使用 OpenRouter
Environment=BAILIAN_BASE_URL=https://openrouter.ai/api
Environment=DASHSCOPE_API_KEY=sk-or-v1-your-key
```

#### 设备端配置适配

在新服务器部署 relay 后，需要更新设备配置中的 provider 地址：

```bash
# 修改 config-bailian.toml 中的 default_provider
default_provider = "custom:http://<新服务器IP>:19091/v1"
```

### Relay 源码说明

`bailian-relay.js`（v821/bailian-relay.js）是一个 ~60 行的无状态 HTTP 代理：

```
请求流程:
  V821 设备 → HTTP POST /v1/chat/completions (无 auth)
       ↓
  relay 接收 → 注入 Authorization: Bearer <API_KEY>
       ↓
  relay 转发 → HTTPS POST https://coding.dashscope.aliyuncs.com/v1/chat/completions
       ↓
  上游响应 → relay 原样返回给设备
```

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `BAILIAN_API_KEY` / `DASHSCOPE_API_KEY` / `ZEROCLAW_API_KEY` | (必填) | 优先级从左到右 |
| `RELAY_HOST` | `0.0.0.0` | 监听地址 |
| `RELAY_PORT` | `19091` | 监听端口 |
| `BAILIAN_BASE_URL` | `https://coding.dashscope.aliyuncs.com` | 上游 HTTPS 端点 |

设备侧只需 HTTP，不需要 TLS 能力。relay 无状态，可水平扩展。

---

## 发布到全新 V821 设备

### 步骤 1：下载编译产物到本地

```bash
scp root@120.24.23.161:/home/tubao/code/zeroclaw/target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw /tmp/zeroclaw_v821
```

### 步骤 2：连接设备并推送文件

```bash
# 确认设备已连接
adb devices

# 推送二进制
adb push /tmp/zeroclaw_v821 /mnt/UDISK/zeroclaw
adb shell 'chmod +x /mnt/UDISK/zeroclaw'

# 推送配置模板
adb push v821/config-bailian.toml /mnt/UDISK/config-bailian.toml

# 推送启动脚本
adb shell 'cat > /mnt/UDISK/start_zeroclaw.sh << "SCRIPT"
#!/bin/sh
# ZeroClaw V821 启动脚本
export ZEROCLAW_V821_DEBUG=1
export ZEROCLAW_ALLOW_PUBLIC_BIND=true
export ZEROCLAW_API_KEY=sk-sp-85875c80488f42b08302e62f02b688b6

CONFIG_DIR="${1:-/tmp/zc_test_run}"
PORT="${2:-9091}"

killall zeroclaw 2>/dev/null
sleep 1

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config.toml" ]; then
    cp /mnt/UDISK/config-bailian.toml "$CONFIG_DIR/config.toml"
fi

exec /mnt/UDISK/zeroclaw --config-dir "$CONFIG_DIR" daemon --host 0.0.0.0 --port "$PORT"
SCRIPT
chmod +x /mnt/UDISK/start_zeroclaw.sh'
```

### 步骤 3：验证

```bash
# 快速验证二进制可运行
adb shell '/mnt/UDISK/zeroclaw --help'

# 验证 relay 可达
adb shell 'wget -O /dev/null http://120.24.23.161:19091/ 2>&1'
# 预期: HTTP/1.1 404 Not Found（说明网络通）
```

### 设备端文件清单

| 路径 | 大小 | 说明 |
|------|------|------|
| `/mnt/UDISK/zeroclaw` | ~14.5MB | 主二进制 |
| `/mnt/UDISK/start_zeroclaw.sh` | ~0.5KB | 一键启动脚本 |
| `/mnt/UDISK/config-bailian.toml` | ~2.5KB | 百练配置模板 |

---

## 启动运行

### 方式 A：设备端脚本（推荐）

```bash
adb shell '/mnt/UDISK/start_zeroclaw.sh'
```

脚本会自动：停旧进程 → 初始化配置 → 启动 daemon（局域网模式，端口 9091）

### 方式 B：本地脚本

```bash
./v821/run-daemon.sh --lan --bailian --api-key 'sk-sp-85875c80488f42b08302e62f02b688b6' --debug
```

### 方式 C：手动启动

```bash
adb shell '
ZEROCLAW_V821_DEBUG=1 \
ZEROCLAW_ALLOW_PUBLIC_BIND=true \
ZEROCLAW_API_KEY=sk-sp-85875c80488f42b08302e62f02b688b6 \
/mnt/UDISK/zeroclaw --config-dir /tmp/zc_test_run daemon --host 0.0.0.0 --port 9091
'
```

### 访问

1. 获取设备 IP：`adb shell 'ifconfig wlan0 | grep "inet addr"'`
2. 浏览器打开：`http://<设备IP>:9091/`
3. 首次使用需配对（日志中会打印 6 位配对码）

### 注意事项

- `adb shell` 退出时会杀死后台进程。如需 daemon 持续运行，保持 `adb shell` 会话不退出，或在设备端配置 init 脚本
- 每次 daemon 重启后需要重新配对（V821 模式下 token 不持久化）
- `/tmp/` 下的配置重启后丢失，启动脚本会自动从 `/mnt/UDISK/config-bailian.toml` 恢复

---

## 日常运维

### 更新二进制

```bash
# 1. 云服务器编译
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

# Relay 状态
ssh root@120.24.23.161 "systemctl status bailian-relay"

# 设备网络状态
adb shell 'ifconfig wlan0'

# doctor 诊断
adb shell 'ZEROCLAW_V821_DEBUG=1 /mnt/UDISK/zeroclaw --config-dir /tmp/zc_test_run doctor'
```

### 磁盘空间不足（编译服务器）

```bash
ssh root@120.24.23.161
cd /home/tubao/code/zeroclaw
# 清理非 V821 编译缓存
rm -rf target/debug target/riscv32gc-unknown-linux-musl/debug
# 清理增量编译缓存
rm -rf target/riscv32gc-unknown-linux-musl/incremental
```

---

## TLS 不可用根因分析

### 现象

V821 设备无法建立任何 HTTPS 连接，包括 zeroclaw 应用和系统自带工具。

### 验证过的方案（全部失败）

| # | 方案 | TLS 后端 | 链接方式 | 结果 | 错误详情 |
|---|------|---------|---------|------|---------|
| 1 | rustls + aws-lc-rs | aws-lc-rs | 静态 | ❌ 握手挂住 | TCP 连接成功，TLS 握手无输出，7 秒后超时 `checkout dropped` |
| 2 | native-tls + SDK OpenSSL | OpenSSL 1.1.1n | 静态 | ❌ signal 11 | 空指针崩溃 `at 0x00000000`，`scause: 0x0c`（指令页错误） |
| 3 | native-tls + SDK OpenSSL | OpenSSL 1.1.1n | 动态 | ❌ signal 11 | 同 #2，链接设备 `/usr/lib/libssl.so.1.1` 后仍崩溃 |
| 4 | native-tls-vendored | OpenSSL 3.5.5 源码 | 静态 | ❌ 编译失败 | `openssl-src` 不认识 `riscv32gc-unknown-linux-musl` target |
| 5 | 设备 wget | wolfSSL (BusyBox) | 系统 | ❌ 连接重置 | `Connection reset by peer`（TLS 握手失败） |
| 6 | 设备 curl | OpenSSL 1.1 | 系统 | ❌ CA 错误 | `error setting certificate verify locations`（curl 自身配置问题，但即使修复也会走到 TLS 握手失败） |

### 技术分析

**方案 1 详细分析（rustls + aws-lc-rs）：**

```
# 使用 RUST_LOG=reqwest=trace,hyper_util=trace 抓取的日志
connecting to 59.110.154.215:443     ← TCP 连接成功
connected to 59.110.154.215:443      ← TCP 建立
                                     ← 无任何 rustls trace 输出
checkout dropped                     ← 7 秒后超时
```

aws-lc-rs 是 AWS 开源的密码学库，内部包含大量汇编优化代码。在 RISC-V 32-bit 上，其 TLS 握手所需的密码学运算（ECDHE 密钥交换、RSA/ECDSA 证书验证）静默失败——不崩溃也不报错，只是挂住。

**方案 2/3 详细分析（OpenSSL）：**

```
# dmesg 输出
zeroclaw[595]: unhandled signal 11 code 0x1 at 0x00000000 in zeroclaw[8002f000+ce4000]
scause: 0000000c  ← 指令页错误：CPU 尝试在地址 0x00000000 执行指令
```

OpenSSL 在 TLS 握手时通过函数指针表调用密码学算法。在 RISC-V 32-bit 上，某些函数指针为 NULL（可能是引擎初始化不完整或平台特定的汇编代码缺失），导致跳转到地址 0 执行，触发 SIGSEGV。

静态链接（`OPENSSL_STATIC=1`）和动态链接（`libssl.so.1.1`）结果完全一致，排除了 -fPIC / PIE 不兼容的可能。

**根本原因：**

全志 V821 使用的是 T-Head（平头哥）扩展的 RISC-V 32-bit 内核（`rv32imfdcxandes`），其 ISA 扩展和 ABI 与标准 RISC-V 32-bit 存在差异。当前主流密码学库（aws-lc-rs、OpenSSL）的 RISC-V 支持主要针对 64-bit（rv64），32-bit 支持不完整：

- aws-lc-rs：RISC-V 32-bit 汇编路径缺失或有 bug，密码学运算挂住
- OpenSSL 1.1.1n：RISC-V 32-bit 的引擎/方法表初始化不完整，函数指针为 NULL
- 该设备的 Linux 内核（5.4.220）和 C 库（musl）本身工作正常，问题仅在 TLS 握手层

### 解决方案

**云服务器 relay**（当前方案，已验证）：

- 设备通过 HTTP 连接云服务器的 relay 服务
- relay 处理 HTTPS 通信，将请求转发到目标 API
- relay 同时注入 API key，设备侧无需存储密钥
- relay 部署为 systemd 服务，自动重启，开机自启

**未来可能的改进方向：**

- 等待 aws-lc-rs / OpenSSL 完善 RISC-V 32-bit 支持
- 尝试 mbedTLS（嵌入式场景更常用，可能对 rv32 支持更好）
- 在设备上运行本地 relay（需要找到可用的 TLS 实现，如用 Go/Python 编写）

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

openclaw 格式参考：

```json
{
  "bailian": {
    "baseUrl": "https://coding.dashscope.aliyuncs.com/v1",
    "apiKey": "sk-sp-85875c80488f42b08302e62f02b688b6",
    "api": "openai-completions",
    "models": [
      { "id": "qwen3.5-plus", "contextWindow": 1000000, "maxTokens": 65536 },
      { "id": "qwen3-coder-next", "contextWindow": 262144, "maxTokens": 65536 }
    ]
  }
}
```

---

## 脚本一览

| 脚本 | 用途 |
|------|------|
| `build.sh` | V821 交叉编译（含 Web Dashboard） |
| `deploy.sh` | 停旧进程 + adb push 新二进制 |
| `run-daemon.sh` | 本地启动设备 daemon（支持 --lan / --bailian / --debug） |
| `run-bailian-relay.sh` | 本地启动 relay（开发调试用） |
| `bailian-relay.js` | relay 服务主程序（Node.js） |
| `common.sh` | 共享配置和辅助函数 |
| `config-bailian.toml` | 设备端配置模板 |
