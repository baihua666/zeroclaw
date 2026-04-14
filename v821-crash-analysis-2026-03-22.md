# V821 平台经验记录

ZeroClaw 在全志 V821（RISC-V 32-bit, Tina Linux）上的适配经验、已知问题与解决方案。

## 平台概要

| 项 | 值 |
|----|-----|
| SoC | 全志 V821, RISC-V 32-bit (rv32imafdc) |
| OS | Tina Linux 5.0 (基于 OpenWrt), Linux 5.4.220 |
| libc | musl |
| 编译目标 | `riscv32gc-unknown-linux-musl` |
| 特殊限制 | 无 RTC 电池（开机时间 1970）、单核 CPU、23MB 用户存储 |
| 连接方式 | ADB (USB) |
| 设备二进制 | `/mnt/UDISK/zeroclaw` |
| 设备配置 | `/mnt/UDISK/config-bailian.toml`, `/mnt/UDISK/zeroclaw.env` |

## 编译与部署

### 编译链路

```bash
# 远端 Ubuntu 服务器编译（交叉编译，约 15-20 分钟）
ssh root@120.24.23.161
source /root/.cargo/env
cd /home/tubao/code/zeroclaw
./v821/build.sh build

# 产物路径
target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw
```

### 部署到设备

```bash
# 多设备时需指定 serial
export ANDROID_SERIAL="<serial>"
adb shell 'killall zeroclaw 2>/dev/null'
scp root@120.24.23.161:/home/tubao/code/zeroclaw/target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw /tmp/zeroclaw_v821
adb push /tmp/zeroclaw_v821 /mnt/UDISK/zeroclaw
adb shell 'chmod +x /mnt/UDISK/zeroclaw'
```

### 常见运维

```bash
# adb push 后出现 "Text file busy" — 等待几秒即可
# 设备空间不足 — 清理 coredump
adb shell 'rm -f /mnt/UDISK/coredump-*'
# 时间同步（TLS 前置条件）
adb shell 'date -s "2026-04-15 00:00:00"'
```

## V821 已知平台限制

以下是 V821 (rv32 + musl + tokio) 上已验证的不稳定 API，**均会导致 signal 11 (null pointer at 0x00000000)**：

| 不可用 API | 替代方案 | 影响模块 |
|-----------|---------|---------|
| `tokio::fs::read_to_string` | `std::fs::read_to_string` | daemon, channels |
| `tokio::fs::write` | `std::fs::write` | daemon state_writer |
| `tokio::fs::create_dir_all` | `std::fs::create_dir_all` | daemon, auth |
| `tokio::fs::metadata` | 返回 `None` 跳过 | channels config_file_stamp |
| `Path::exists()` / `Path::is_file()` | 直接 `open()` 或 `read_dir()` | doctor |
| native-tls (OpenSSL) | rustls + aws-lc-rs | 全局 TLS |

### V821 下禁用的 daemon 后台任务

| 任务 | 原因 | 代码位置 |
|------|------|---------|
| `state_writer` 循环 | tokio::fs 周期写入崩溃 | `src/daemon/mod.rs` |
| `scheduler supervisor` | 后台定时任务路径崩溃 | `src/daemon/mod.rs` |
| `heartbeat supervisor` | 异步心跳路径崩溃 | `src/daemon/mod.rs` |
| 运行时配置重载 | `config_file_stamp` 触发 provider warmup 崩溃 | `src/channels/mod.rs` |

## 问题修复记录

### 1. doctor / daemon / auth 启动崩溃（2026-03-22）

**现象**：`doctor`、`daemon`、`auth` 命令在设备上 Segmentation fault。

**根因**：三个独立问题，非同一链路：
- `doctor`：`Path::exists()` / `Path::is_file()` 在 V821 上不稳定
- `daemon`：`state_writer` 中 `tokio::fs::create_dir_all` / `tokio::fs::write` 崩溃
- `auth`：`acquire_lock()` 中重复 `create_dir_all`，配置目录已在更早阶段创建

**修复**：
- `doctor`：路径探测改为实际 `open()` / `read_dir()`
- `daemon`：`v821` feature 下用同步 `std::fs`
- `auth`：去掉重复的 `create_dir_all`，profile store 改用同步 fs，`reqwest::Client` 懒初始化

### 2. daemon 长时间运行崩溃（2026-03-25 ~ 03-26）

**现象**：daemon 启动后十几秒到几分钟后 EXIT:139。

**根因**：`state_writer`、`scheduler`、`heartbeat` 三条后台路径中的异步 I/O / 定时器。

**修复**：`v821` feature 下禁用这三条后台路径，仅保留 gateway + channels 主路径。

**验证**：soak 测试 10+ 分钟稳定，dmesg 无新增 signal 11。

### 3. TLS/HTTPS 不可用（2026-03-28 ~ 03-29）

**现象**：HTTPS 请求静默超时或 signal 11。

**根因**：V821 无 RTC 电池，开机时间为 1970-01-01，所有 TLS 证书验证失败。native-tls (OpenSSL) 在 rv32 上有真实 bug (signal 11)。

**修复**：
- 使用 rustls + aws-lc-rs（验证正常）
- 启动前同步系统时间（`run-daemon.sh` 自动处理）
- 移除 HTTP relay 中转方案，改为 HTTPS 直连

### 4. 百练 API 405（2026-03-29）

**现象**：`coding.dashscope.aliyuncs.com` 返回 405。

**根因**：`custom:` 前缀不设置 `User-Agent: QwenCode/1.0`。

**修复**：使用内置 `qwen-code` provider。

### 5. QQ 通道未编译进 V821（2026-04-14）

**现象**：配置了 QQ 但日志显示 `compiled without channels-websocket feature; skipping QQ`。

**根因**：`v821` Cargo feature 未包含 `channels-websocket`。

**修复**：
```toml
v821 = ["dep:aws-lc-rs", "channels-websocket"]
channels-websocket = ["dep:tokio-tungstenite", "tokio-tungstenite/rustls-tls-webpki-roots"]
```

### 6. QQ 被动回复缺少 msg_id（2026-04-14）

**现象**：QQ API v2 被动回复需要 `msg_id`，缺失时按主动消息计（月限 4 条）。

**修复**：`qq.rs` — `listen()` 将原始 `msg_id` 存入 `thread_ts`，`send()` 从中读取传给 API。

### 7. QQ 消息处理时 signal 11（2026-04-15）

**现象**：QQ 消息接收成功（`💬 [qq] from ...`），处理回复时崩溃。

**定位**：在 `process_channel_message` 中逐步加 `[v821-debug][msg] step:*` 标记，确认崩在 `config_file_stamp` 返回后。

**根因**：V821 简化版 `config_file_stamp()` 返回当前时间戳，每次调用都不同，导致 `maybe_apply_runtime_config_update()` 误判配置变更 → 重新读配置文件 → 创建新 provider → `provider.warmup()` (HTTPS) → signal 11。

**修复**：V821 下 `config_file_stamp()` 返回 `None`，跳过运行时配置重载。

## 已验证命令

| 命令 | 结果 | 备注 |
|------|------|------|
| `--help` | ✅ | |
| `status` | ✅ | |
| `providers` | ✅ | |
| `config schema` | ✅ | |
| `channel list` | ✅ | |
| `memory stats` | ✅ | |
| `cron list` | ✅ | |
| `completions bash` | ✅ | |
| `doctor` | ✅ | 10 ok, 7 warnings, 1 errors |
| `doctor traces` | ✅ | |
| `models status` | ✅ | |
| `estop status` | ✅ | EXIT:1（未启用，预期） |
| `peripheral list` | ✅ | |
| `gateway start` | ✅ | |
| `daemon` | ✅ | state_writer/heartbeat/scheduler 禁用 |
| `auth status` | ✅ | |
| `auth list` | ✅ | |
| `auth logout` | ✅ | EXIT:2（参数校验，预期） |
| daemon + QQ C2C 对话 | ✅ | 端到端：消息接收 → AI → 被动回复 |

## ADB 后台进程保活

V821 的 adb 实现在 shell 退出时会杀死后台进程。解决方案：

```sh
# 方法 1：trap 忽略 SIGHUP
cat > /tmp/zc_persist.sh << 'EOF'
#!/bin/sh
trap '' HUP
export ZEROCLAW_V821_DEBUG=1
export ZEROCLAW_ALLOW_PUBLIC_BIND=true
. /mnt/UDISK/zeroclaw.env
exec /mnt/UDISK/zeroclaw --config-dir /tmp/zc_data daemon --host 0.0.0.0 --port 9092 >> /tmp/daemon.log 2>&1
EOF
adb shell 'sh /tmp/zc_persist.sh &'

# 方法 2：使用 run-daemon.sh（推荐）
DASHSCOPE_API_KEY=sk-sp-xxx ./v821/run-daemon.sh --lan --bailian --debug

# 方法 3：设备启动脚本
/mnt/UDISK/start_zeroclaw.sh  # 含 WiFi 等待 + NTP 时间同步
```

## 调试方法论

1. **埋点定位**：使用 `#[cfg(feature = "v821")] eprintln!("[v821-debug] ...")` 逐步缩小崩点
2. **dmesg 确认**：`adb shell 'dmesg | grep "signal 11" | wc -l'` 对比前后计数
3. **coredump 注意**：崩溃会产生 coredump 到 `/mnt/UDISK/`，会耗尽 23MB 存储，需及时清理
4. **核心原则**：V821 上所有 `tokio::fs` 和 `Path::exists()` 相关调用都应视为可疑，优先替换为同步 `std::fs` 或直接返回 `None`/跳过
