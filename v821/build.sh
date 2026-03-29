#!/bin/bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

export TINA_LINUX_DIR="${TINA_LINUX_DIR:-${ROOT_DIR}/../v821-tina-v13}"
export STAGING_DIR="${TINA_LINUX_DIR}/out/v821/aitoy/openwrt/staging_dir"
export CROSS_COMPILE="${TINA_LINUX_DIR}/prebuilt/rootfsbuilt/riscv/nds32le-linux-musl-v5d/bin/riscv32-linux-musl-"

check_prerequisites() {
    print_info "检查编译环境"

    if [ ! -d "${TINA_LINUX_DIR}" ]; then
        print_error "未找到 Tina Linux SDK: ${TINA_LINUX_DIR}"
    fi

    if [ ! -x "${CROSS_COMPILE}gcc" ]; then
        print_error "未找到交叉编译器: ${CROSS_COMPILE}gcc"
    fi

    require_command rustup

    if ! rustup +nightly component list --installed 2>/dev/null | grep -q "rust-src"; then
        print_info "安装 rust-src 组件"
        rustup +nightly component add rust-src
    fi

    print_info "环境检查通过"
    echo "TINA_LINUX_DIR: ${TINA_LINUX_DIR}"
    echo "CROSS_COMPILE: ${CROSS_COMPILE}gcc"
    echo "TARGET: ${TARGET_TRIPLE}"
}

build_web_dashboard() {
    local web_dir="${ROOT_DIR}/web"
    local dist_index="${web_dir}/dist/index.html"

    print_info "构建 Web Dashboard"

    [ -f "${web_dir}/package.json" ] || print_error "未找到 web/package.json"
    require_command npm

    cd "${web_dir}"
    if [ -f "package-lock.json" ]; then
        npm ci --ignore-scripts
    else
        npm install --ignore-scripts
    fi

    npm run build
    [ -f "${dist_index}" ] || print_error "Web Dashboard 构建失败: 缺少 ${dist_index}"

    print_info "Web Dashboard 构建完成"
    echo "Dashboard: ${dist_index}"
}

setup_cargo_env() {
    print_info "配置 Cargo 环境"

    export CARGO_TARGET_RISCV32GC_UNKNOWN_LINUX_MUSL_LINKER="${CROSS_COMPILE}gcc"
    export CARGO_TARGET_RISCV32GC_UNKNOWN_LINUX_MUSL_AR="${CROSS_COMPILE}ar"
    export CC_riscv32gc_unknown_linux_musl="${CROSS_COMPILE}gcc"

    if [ -n "${V821_RUSTFLAGS:-}" ]; then
        export CARGO_TARGET_RISCV32GC_UNKNOWN_LINUX_MUSL_RUSTFLAGS="${V821_RUSTFLAGS}"
    fi

    export CFLAGS_target_riscv32gc_unknown_linux_musl="-march=rv32imfdcxandes -mabi=ilp32d -mcmodel=medany -D__riscv32__"
    export CXXFLAGS_target_riscv32gc_unknown_linux_musl="-march=rv32imfdcxandes -mabi=ilp32d -mcmodel=medany -D__riscv32__"

    # V821 TLS 栈 (rustls + aws-lc-rs) 在系统时间正确时完全可用，HTTPS 直连。
    # 注意: V821 无 RTC 电池，启动前需同步时间（run-daemon.sh 已自动处理）。
}

clean_build() {
    print_info "清理编译产物"
    cd "${ROOT_DIR}"
    cargo clean --target "${TARGET_TRIPLE}"
}

do_build() {
    local profile="${1:-${DEFAULT_PROFILE}}"
    local features="${2:-}"
    local cargo_profile_arg=""
    local output_profile="${profile}"
    local cargo_cmd="cargo +nightly build"

    print_info "开始编译 ZeroClaw for V821"
    echo "Profile: ${profile}"
    echo "Features: ${features:-${DEFAULT_FEATURES}}"

    cd "${ROOT_DIR}"

    cargo_cmd+=" --target ${TARGET_TRIPLE}"
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

    if [ -n "${features}" ]; then
        cargo_cmd+=" --no-default-features --features=\"${features}\""
    else
        cargo_cmd+=" --no-default-features --features=\"${DEFAULT_FEATURES}\""
    fi

    echo "执行命令: ${cargo_cmd}"
    eval "${cargo_cmd}"

    local binary_path="${ROOT_DIR}/target/${TARGET_TRIPLE}/${output_profile}/zeroclaw"
    print_info "编译完成"
    echo "产物位置: ${binary_path}"
    if [ -f "${binary_path}" ]; then
        file "${binary_path}"
    fi
}

print_help() {
    cat <<'HELP'
ZeroClaw V821 编译脚本

使用方法: ./v821/build.sh [command]

命令:
  build       编译 V821 精简 release 版本 (默认)
  release     同 build
  minimal     同 build
  debug       编译 debug 版本
  clean       清理编译产物
  help        显示帮助信息

环境变量:
  TINA_LINUX_DIR     Tina Linux SDK 目录
  CUSTOM_FEATURES    自定义 features
  V821_RUSTFLAGS     覆盖目标 RUSTFLAGS
HELP
}

main() {
    local cmd="${1:-build}"

    case "${cmd}" in
        build|release|minimal)
            check_prerequisites
            build_web_dashboard
            setup_cargo_env
            do_build "${DEFAULT_PROFILE}" "${CUSTOM_FEATURES:-${DEFAULT_FEATURES}}"
            ;;
        debug)
            check_prerequisites
            build_web_dashboard
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
            print_error "未知命令: ${cmd}"
            ;;
    esac
}

main "$@"
