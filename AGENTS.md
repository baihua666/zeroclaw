# CLAUDE.md — ZeroClaw

## Commands

```bash
cargo fmt --all -- --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Full pre-PR validation (recommended):

```bash
./dev/ci.sh all
```

Docs-only changes: run markdown lint and link-integrity checks. If touching bootstrap scripts: `bash -n install.sh`.

## Project Snapshot

ZeroClaw is a Rust-first autonomous agent runtime optimized for performance, efficiency, stability, extensibility, sustainability, and security.

Core architecture is trait-driven and modular. Extend by implementing traits and registering in factory modules.

Key extension points:

- `src/providers/traits.rs` (`Provider`)
- `src/channels/traits.rs` (`Channel`)
- `src/tools/traits.rs` (`Tool`)
- `src/memory/traits.rs` (`Memory`)
- `src/observability/traits.rs` (`Observer`)
- `src/runtime/traits.rs` (`RuntimeAdapter`)
- `src/peripherals/traits.rs` (`Peripheral`) — hardware boards (STM32, RPi GPIO)

## Repository Map

- `src/main.rs` — CLI entrypoint and command routing
- `src/lib.rs` — module exports and shared command enums
- `src/config/` — schema + config loading/merging
- `src/agent/` — orchestration loop
- `src/gateway/` — webhook/gateway server
- `src/security/` — policy, pairing, secret store
- `src/memory/` — markdown/sqlite memory backends + embeddings/vector merge
- `src/providers/` — model providers and resilient wrapper
- `src/channels/` — Telegram/Discord/Slack/etc channels
- `src/tools/` — tool execution surface (shell, file, memory, browser)
- `src/peripherals/` — hardware peripherals (STM32, RPi GPIO)
- `src/runtime/` — runtime adapters (currently native)
- `docs/` — topic-based documentation (setup-guides, reference, ops, security, hardware, contributing, maintainers)
- `.github/` — CI, templates, automation workflows

## Risk Tiers

- **Low risk**: docs/chore/tests-only changes
- **Medium risk**: most `src/**` behavior changes without boundary/security impact
- **High risk**: `src/security/**`, `src/runtime/**`, `src/gateway/**`, `src/tools/**`, `.github/workflows/**`, access-control boundaries

When uncertain, classify as higher risk.

## Workflow

1. **Read before write** — inspect existing module, factory wiring, and adjacent tests before editing.
2. **One concern per PR** — avoid mixed feature+refactor+infra patches.
3. **Implement minimal patch** — no speculative abstractions, no config keys without a concrete use case.
4. **Validate by risk tier** — docs-only: lightweight checks. Code changes: full relevant checks.
5. **Document impact** — update PR notes for behavior, risk, side effects, and rollback.
6. **Queue hygiene** — stacked PR: declare `Depends on #...`. Replacing old PR: declare `Supersedes #...`.

Branch/commit/PR rules:
- Work from a non-`master` branch. Open a PR to `master`; do not push directly.
- Use conventional commit titles. Prefer small PRs (`size: XS/S/M`).
- Follow `.github/pull_request_template.md` fully.
- Never commit secrets, personal data, or real identity information (see `@docs/contributing/pr-discipline.md`).

## Anti-Patterns

- Do not add heavy dependencies for minor convenience.
- Do not silently weaken security policy or access constraints.
- Do not add speculative config/feature flags "just in case".
- Do not mix massive formatting-only changes with functional changes.
- Do not modify unrelated modules "while here".
- Do not bypass failing checks without explicit explanation.
- Do not hide behavior-changing side effects in refactor commits.
- Do not include personal identity or sensitive information in test data, examples, docs, or commits.

## Linked References

- `@docs/contributing/change-playbooks.md` — adding providers, channels, tools, peripherals; security/gateway changes; architecture boundaries
- `@docs/contributing/pr-discipline.md` — privacy rules, superseded-PR attribution/templates, handoff template
- `@docs/contributing/docs-contract.md` — docs system contract, i18n rules, locale parity

## Environment Context (V821)

- 设备: 全志 V821, RISC-V 32-bit, Tina Linux 5.0, 单核, 23MB 用户存储
- ADB can directly connect to the V821 RISC-V 32-bit development board.
- App binary path on device: `/mnt/UDISK/zeroclaw`.
- If device-side information, debugging, or runtime verification is needed, use `adb` commands directly.
- Current local project path is an SSHFS mount from a remote Ubuntu server.
- Canonical project path on the server: `/home/tubao/code/zeroclaw`.
- Cross-compilation must be done on the Ubuntu server.
- SSH access for server-side build/debug: `ssh root@120.24.23.161`.
- 挂载SSHFS：`/Users/tubao/work/ubuntu/start_ubuntu_sshfs.sh`
- Web Dashboard: `http://<设备IP>:9091/`（默认端口 9091）
- 当多个 ADB 设备连接时需 `export ANDROID_SERIAL="<serial>"`

### V821 脚本一览

| 脚本 | 用途 | 使用方式 |
|------|------|---------|
| `v821/setup-device.sh` | **全新设备一键部署**（推荐入口） | `./v821/setup-device.sh --api-key sk-sp-xxx` |
| `v821/build.sh` | 远端交叉编译（约 20 分钟） | `ssh root@120.24.23.161 'source /root/.cargo/env && cd /home/tubao/code/zeroclaw && ./v821/build.sh build'` |
| `v821/deploy.sh` | 仅推送二进制到设备 | `./v821/deploy.sh` |
| `v821/deploy-autostart.sh` | 部署启动脚本 + init.d 自启 | `./v821/deploy-autostart.sh --api-key sk-sp-xxx` |
| `v821/run-daemon.sh` | 从开发机启动设备 daemon | `DASHSCOPE_API_KEY=sk-sp-xxx ./v821/run-daemon.sh --lan --bailian --debug` |
| `v821/start_zeroclaw.sh` | 设备端启动脚本（WiFi 等待 + NTP + daemon） | 设备上 `/mnt/UDISK/start_zeroclaw.sh` |
| `v821/S95zeroclaw` | init.d 开机自启脚本 | 设备上 `/etc/init.d/S95zeroclaw start\|stop\|restart\|status` |
| `v821/config-bailian.toml` | 配置模板（百练 + QQ 通道） | 部署时自动推送到设备 |

### V821 常用操作

```bash
# 全新设备一键部署（含编译）
./v821/setup-device.sh --api-key sk-sp-xxx --build

# 全新设备部署（已有本地二进制）
./v821/setup-device.sh --api-key sk-sp-xxx --binary /tmp/zeroclaw_v821

# 全新设备部署（从服务器下载已编译的二进制）
./v821/setup-device.sh --api-key sk-sp-xxx

# 日常更新二进制
./v821/deploy.sh

# 查看设备日志
adb shell 'tail -f /tmp/zeroclaw_v821_daemon.log'

# 设备状态
adb shell 'ps | grep zeroclaw'
adb shell '/etc/init.d/S95zeroclaw status'

# 停止/重启
adb shell 'killall zeroclaw'
adb shell '/etc/init.d/S95zeroclaw restart'

# 诊断
adb shell 'dmesg | grep zeroclaw | tail -10'
adb shell 'ZEROCLAW_V821_DEBUG=1 /mnt/UDISK/zeroclaw --config-dir /tmp/zc_run doctor'

# 设备空间不足时清理 coredump
adb shell 'rm -f /mnt/UDISK/coredump-*'
```

### V821 已知平台限制（必读）

详细记录见 `v821-crash-analysis-2026-03-22.md`。核心要点：

1. **tokio::fs 不可用** — `tokio::fs::read_to_string`、`tokio::fs::write`、`tokio::fs::metadata` 在 V821 上 signal 11，必须用 `std::fs` 替代
2. **Path::exists() 不稳定** — 用 `open()` 或 `read_dir()` 替代
3. **无 RTC 电池** — 开机时间 1970，启动前必须同步时间（脚本已自动处理），否则 TLS 证书验证失败
4. **native-tls (OpenSSL) 不可用** — 仅 rustls + aws-lc-rs 可用
5. **daemon 后台任务** — `state_writer`、`heartbeat`、`scheduler` 在 v821 feature 下已禁用
6. **运行时配置重载** — `config_file_stamp()` 在 v821 下返回 `None` 跳过，避免重载路径 signal 11
7. **session_persistence** — 必须在配置中设为 `false`
8. **adb 后台进程** — shell 退出时杀进程，用 `trap '' HUP` 或 double-fork 保活

### V821 QQ 通道

- QQ 机器人 app_id: `1903829956`
- 配置位于 `v821/config-bailian.toml` 的 `[channels_config.qq]`
- 功能: C2C 私聊（消息接收 + 被动回复），使用 WebSocket 网关 + HTTPS 直连
- `send()` 通过 `thread_ts` 传递原始 `msg_id` 实现被动回复（QQ API v2 要求）
- `allowed_users = ["*"]` 允许所有用户

## 代码修改
- 把v821相关的编译脚本,运行脚本等定制代码,统一放到 zeroclaw/v821目录, 尽量少修改框架原始代码，优先通过参数传入，更上层的使用方面进行适配，减少后续维护成本
- 每次遇到问题，先结合之前的问题总结文档：v821-crash-analysis-2026-03-22.md 进行分析，例如tls, agent配置等，解决问题后，要再归档到这个文档，方便后续排查

## 文档维护要求
- **v821/README.md** — V821 平台的完整使用指南（架构、编译、部署、运维、TLS、模型），修改 V821 相关脚本或流程后必须同步更新此文档
- **v821-crash-analysis-2026-03-22.md** — V821 平台经验记录（已知限制、问题修复、调试方法论），遇到新问题解决后必须归档到此文档
- 这两个文档是 V821 开发的核心参考，AI 在每次 V821 相关任务开始时应先阅读