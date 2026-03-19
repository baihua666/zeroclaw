#!/bin/bash
#
# ZeroClaw V821 编译脚本
#
# 用于编译 ZeroClaw 到全志 V821 开发板 (Tina Linux, RISC-V 32-bit)
#
# 使用方法:
#   ./dev/build_v821.sh [clean|build|release]
#
# 编译产物位置:
#   target/riscv32gc-unknown-linux-musl/release-v821/zeroclaw
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================================
# 环境配置
# ============================================================================

# V821 Tina Linux SDK 目录 (可根据实际情况修改)
export TINA_LINUX_DIR="${TINA_LINUX_DIR:-${ROOT_DIR}/../v821-tina-v13}"
export STAGING_DIR="${TINA_LINUX_DIR}/out/v821/aitoy/openwrt/staging_dir"

# 交叉编译工具链 (Andes 工具链)
export CROSS_COMPILE="${TINA_LINUX_DIR}/prebuilt/rootfsbuilt/riscv/nds32le-linux-musl-v5d/bin/riscv32-linux-musl-"

# Rust target
TARGET="riscv32gc-unknown-linux-musl"

# ============================================================================
# 函数定义
# ============================================================================

print_info() {
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_error() {
    echo "❌ ERROR: $1" >&2
    exit 1
}

check_prerequisites() {
    print_info "检查编译环境..."

    # 检查 Tina SDK 目录
    if [ ! -d "${TINA_LINUX_DIR}" ]; then
        print_error "未找到 Tina Linux SDK: ${TINA_LINUX_DIR}"
        echo "请设置环境变量 TINA_LINUX_DIR 指向 SDK 目录"
        exit 1
    fi

    # 检查交叉编译器
    if [ ! -x "${CROSS_COMPILE}gcc" ]; then
        print_error "未找到交叉编译器：${CROSS_COMPILE}gcc"
        exit 1
    fi

    # 检查 Rust nightly
    if ! command -v rustup &> /dev/null; then
        print_error "未安装 rustup"
        exit 1
    fi

    # 检查 rust-src 组件
    if ! rustup +nightly component list --installed 2>/dev/null | grep -q "rust-src"; then
        print_info "安装 rust-src 组件..."
        rustup +nightly component add rust-src
    fi

    print_info "环境检查通过"
    echo "  TINA_LINUX_DIR: ${TINA_LINUX_DIR}"
    echo "  CROSS_COMPILE:  ${CROSS_COMPILE}gcc"
    echo "  TARGET:         ${TARGET}"
}

setup_cargo_env() {
    print_info "配置 Cargo 环境..."

    # 仅设置目标三元组专用变量，避免宿主 build-script / proc-macro 被误导到交叉工具链。
    export CARGO_TARGET_RISCV32GC_UNKNOWN_LINUX_MUSL_LINKER="${CROSS_COMPILE}gcc"
    export CARGO_TARGET_RISCV32GC_UNKNOWN_LINUX_MUSL_AR="${CROSS_COMPILE}ar"
    export CC_riscv32gc_unknown_linux_musl="${CROSS_COMPILE}gcc"

    # 仅对目标 C/C++ 依赖注入架构参数；v821 默认不走 ring 路径。
    export CFLAGS_target_riscv32gc_unknown_linux_musl="-march=rv32imfdcxandes -mabi=ilp32d -mcmodel=medany -D__riscv32__"
    export CXXFLAGS_target_riscv32gc_unknown_linux_musl="-march=rv32imfdcxandes -mabi=ilp32d -mcmodel=medany -D__riscv32__"
}

clean_build() {
    print_info "清理编译产物..."
    cd "${ROOT_DIR}"
    cargo clean --target "${TARGET}"
    print_info "清理完成"
}

do_build() {
    local profile="${1:-release-v821}"
    local features="${2:-}"
    local cargo_profile_arg=""
    local output_profile="${profile}"

    print_info "开始编译 ZeroClaw for V821..."
    echo "  Profile:  ${profile}"
    echo "  Features: ${features:-v821}"
    echo ""

    cd "${ROOT_DIR}"

    # 构建命令
    local cargo_cmd="cargo +nightly build"
    cargo_cmd+=" --target ${TARGET}"
    cargo_cmd+=" -Z build-std=std,panic_abort"

    case "${profile}" in
        dev)
            output_profile="debug"
            ;;
        release)
            cargo_profile_arg="--release"
            output_profile="release"
            ;;
        *)
            cargo_profile_arg="--profile ${profile}"
            ;;
    esac

    if [ -n "${cargo_profile_arg}" ]; then
        cargo_cmd+=" ${cargo_profile_arg}"
    fi

    # 添加特性标志
    if [ -n "${features}" ]; then
        cargo_cmd+=" --no-default-features --features=\"${features}\""
    else
        # 默认使用 v821 特性 (禁用 ring / prometheus，保留 aws-lc-rs TLS 路径)
        # 注意：channel-nostr 依赖 ring，所以 V821 默认不包含它
        cargo_cmd+=" --no-default-features --features=\"v821\""
    fi

    echo "执行命令：${cargo_cmd}"
    echo ""

    # 执行编译
    eval "${cargo_cmd}"

    print_info "编译完成!"
    echo "产物位置："
    echo "  target/${TARGET}/${output_profile}/zeroclaw"
    echo ""

    # 显示文件信息
    local binary_path="${ROOT_DIR}/target/${TARGET}/${output_profile}/zeroclaw"
    if [ -f "${binary_path}" ]; then
        print_info "二进制文件信息:"
        file "${binary_path}"
    fi
}

print_help() {
    cat <<'EOF'
ZeroClaw V821 编译脚本

使用方法：./dev/build_v821.sh [command] [options]

命令:
  build       编译 V821 release 版本 (默认)
  release     同 build
  debug       编译 debug 版本
  clean       清理编译产物
  help        显示帮助信息

特性选项:
  默认使用 v821 特性集 (禁用 ring / prometheus)
  可通过环境变量 CUSTOM_FEATURES 指定特性

环境变量:
  TINA_LINUX_DIR     Tina Linux SDK 目录 (默认：../v821-tina-v13)
  CUSTOM_FEATURES    自定义特性列表

示例:
  ./dev/build_v821.sh build
  CUSTOM_FEATURES="channel-telegram" ./dev/build_v821.sh build
  ./dev/build_v821.sh clean
EOF
}

# ============================================================================
# 主函数
# ============================================================================

main() {
    local cmd="${1:-build}"

    case "${cmd}" in
        build|release)
            check_prerequisites
            setup_cargo_env
            do_build "release-v821" "${CUSTOM_FEATURES:-}"
            ;;
        debug)
            check_prerequisites
            setup_cargo_env
            do_build "dev" "${CUSTOM_FEATURES:-}"
            ;;
        clean)
            check_prerequisites
            clean_build
            ;;
        help|--help|-h)
            print_help
            ;;
        *)
            print_error "未知命令：${cmd}"
            print_help
            exit 1
            ;;
    esac
}

main "$@"
