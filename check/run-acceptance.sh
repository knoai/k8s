#!/usr/bin/env bash
# run-acceptance.sh - K8s 集群一键测试验收主控脚本
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}"

# 加载配置（环境变量优先级高于 config.env，便于容器化注入）
__env_backup_file=$(mktemp)
env | grep -E '^(CHECK_|TIMEOUT_|NODE_|APISERVER_|ETCD_|CORE_|OPERATOR_|PERF_|ACCEPTANCE_|TEST_NS_|REPORT_DIR|LOG_FILE|PROJECT_ROOT)' > "$__env_backup_file" || true
source "${SCRIPT_DIR}/config.env"
source "${SCRIPT_DIR}/lib/common.sh"
while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    export "$key=$value"
done < "$__env_backup_file"
rm -f "$__env_backup_file"

# 命令行参数
CLEANUP_ONLY=false
DRY_RUN=false
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cleanup)
            CLEANUP_ONLY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Options:
  --cleanup         仅清理所有测试创建的 Namespace/资源
  --dry-run         打印将要执行的检查清单，不实际执行
  -o, --output DIR  指定报告和日志输出目录（默认: ./report）
  -h, --help        显示此帮助

环境变量:
  可在执行前通过环境变量覆盖 config.env 中的配置，例如:
    CHECK_PERFORMANCE=true ./run-acceptance.sh

EOF
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            exit 1
            ;;
    esac
done

# 如果指定了输出目录，覆盖 REPORT_DIR
if [[ -n "${OUTPUT_DIR}" ]]; then
    mkdir -p "${OUTPUT_DIR}"
    REPORT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
fi

# 清理模式
if [[ "${CLEANUP_ONLY}" == "true" ]]; then
    log_info "仅执行清理..."
    cleanup_test_ns
    log_pass "清理完成"
    exit 0
fi

# 初始化报告
init_report
log_info "============================================"
log_info " K8s 集群一键验收测试启动"
log_info " 报告将输出至: ${REPORT_FILE}"
log_info "============================================"

# 注册退出清理
trap 'trap_cleanup' EXIT

# 收集所有检查脚本
checks=()
for f in checks/[0-9]*-*.sh; do
    [[ -f "$f" ]] || continue
    checks+=("$f")
done

if [[ ${#checks[@]} -eq 0 ]]; then
    log_fail "未找到检查脚本"
    exit 1
fi

log_info "共发现 ${#checks[@]} 个检查模块"

# dry-run 模式
if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "[DRY-RUN] 将执行以下检查:"
    for c in "${checks[@]}"; do
        mod_name=$(basename "$c" .sh)
        var_name="CHECK_$(echo "${mod_name##*-}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
        enabled="${!var_name:-true}"
        if [[ "${enabled}" == "true" ]]; then
            echo "  [执行] ${mod_name}"
        else
            echo "  [跳过] ${mod_name} (已禁用)"
        fi
    done
    rm -f "${REPORT_ACC:-}" "${SUMMARY_ACC:-}" "${LOG_FILE:-}" "${REPORT_FILE:-}"
    exit 0
fi

# 执行各模块
total_pass=0
total_fail=0
total_skip=0

for c in "${checks[@]}"; do
    mod_name=$(basename "$c" .sh)
    # 通过环境变量判断是否跳过，变量名如 CHECK_ENV, CHECK_NODE 等
    var_name="CHECK_${mod_name##*-}"
    var_name="${var_name^^}"
    var_name="${var_name//-/_}"
    enabled="${!var_name:-true}"

    if [[ "${enabled}" != "true" ]]; then
        log_info "跳过模块: ${mod_name}"
        add_report_line "${mod_name}" "SKIP" "0s" "已禁用" "-"
        add_summary "SKIP"
        ((total_skip++)) || true
        continue
    fi

    log_info "--------------------------------------------"
    log_info "开始执行: ${mod_name}"
    log_info "--------------------------------------------"

    if bash "${c}"; then
        ((total_pass++)) || true
    else
        ((total_fail++)) || true
    fi
done

# 生成报告
report_path=$(gen_report)

log_info "============================================"
log_info " 验收测试完成"
log_info " 通过: ${total_pass} | 失败: ${total_fail} | 跳过: ${total_skip}"
log_info " 报告: ${report_path}"
log_info "============================================"

if [[ "${total_fail}" -gt 0 ]]; then
    exit 1
fi
exit 0
