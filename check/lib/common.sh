#!/usr/bin/env bash
# common.sh - 公共函数库
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_DIR="${PROJECT_ROOT}/report"
REPORT_FILE=""
LOG_FILE=""
TEST_NS_PREFIX="k8s-acceptance"
TEST_NS=""

# 颜色定义
CLR_INFO='\033[0;34m'
CLR_PASS='\033[0;32m'
CLR_WARN='\033[1;33m'
CLR_FAIL='\033[0;31m'
CLR_RESET='\033[0m'

init_report() {
    mkdir -p "${REPORT_DIR}"
    REPORT_FILE="${REPORT_DIR}/acceptance-report-$(date +%Y%m%d-%H%M%S).md"
    LOG_FILE="${REPORT_DIR}/acceptance-$(date +%Y%m%d-%H%M%S).log"
    REPORT_ACC="${REPORT_DIR}/.report_acc.$$"
    SUMMARY_ACC="${REPORT_DIR}/.summary_acc.$$"
    touch "${LOG_FILE}"
    : > "${REPORT_ACC}"
    : > "${SUMMARY_ACC}"
}

__log_write() {
    local level="$1" msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ -n "${LOG_FILE}" && -f "${LOG_FILE}" ]]; then
        echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
    fi
}

log_info()  { echo -e "${CLR_INFO}[INFO]${CLR_RESET}  $*"; __log_write "INFO" "$*"; }
log_pass()  { echo -e "${CLR_PASS}[PASS]${CLR_RESET}  $*"; __log_write "PASS" "$*"; }
log_warn()  { echo -e "${CLR_WARN}[WARN]${CLR_RESET}  $*"; __log_write "WARN" "$*"; }
log_fail()  { echo -e "${CLR_FAIL}[FAIL]${CLR_RESET}  $*"; __log_write "FAIL" "$*"; }

add_report_line() {
    local module="$1" status="$2" duration="$3" conclusion="$4" detail="$5"
    printf "| %s | %s | %s | %s | %s |\n" "${module}" "${status}" "${duration}" "${conclusion}" "${detail}" >> "${REPORT_ACC}"
}

add_summary() {
    local status="$1"
    echo "${status}" >> "${SUMMARY_ACC}"
}

gen_report() {
    local total pass fail skip
    total=$(wc -l < "${SUMMARY_ACC}" | tr -d ' ')
    pass=$(grep -c "PASS" "${SUMMARY_ACC}" || true)
    fail=$(grep -c "FAIL" "${SUMMARY_ACC}" || true)
    skip=$(grep -c "SKIP" "${SUMMARY_ACC}" || true)
    pass=${pass:-0}
    fail=${fail:-0}
    skip=${skip:-0}

    cat > "${REPORT_FILE}" <<EOF
# K8s 集群验收报告

生成时间: $(date '+%Y-%m-%d %H:%M:%S')

## 汇总统计

| 指标 | 数值 |
|------|------|
| 总计 | ${total} |
| 通过 | ${pass} |
| 失败 | ${fail} |
| 跳过 | ${skip} |

## 详细结果

| 模块 | 状态 | 耗时 | 关键结论 | 失败详情 |
|------|------|------|----------|----------|
EOF
    cat "${REPORT_ACC}" >> "${REPORT_FILE}"

    rm -f "${REPORT_ACC}" "${SUMMARY_ACC}"
    echo "${REPORT_FILE}"
}

ensure_test_ns() {
    if [[ -z "${TEST_NS:-}" ]]; then
        TEST_NS="${TEST_NS_PREFIX}-$(date +%s)"
    fi
    if ! kubectl get namespace "${TEST_NS}" &>/dev/null; then
        kubectl create namespace "${TEST_NS}" >/dev/null
    fi
    echo "${TEST_NS}"
}

cleanup_test_ns() {
    if [[ -n "${TEST_NS:-}" ]]; then
        kubectl delete namespace "${TEST_NS}" --wait=false &>/dev/null || true
    fi
    # 清理所有以 k8s-acceptance- 开头的 namespace
    kubectl get namespaces -o name | grep "namespace/${TEST_NS_PREFIX}-" | xargs -r kubectl delete --wait=false &>/dev/null || true
}

# 注册退出清理
trap_cleanup() {
    if [[ "${ACCEPTANCE_CLEANUP:-true}" == "true" ]]; then
        cleanup_test_ns
    fi
}
