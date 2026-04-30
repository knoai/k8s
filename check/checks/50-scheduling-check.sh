#!/usr/bin/env bash
# 50-scheduling-check.sh - 调度功能检查
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-utils.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="调度功能正常"
    detail="-"

    local ns
    ns=$(ensure_test_ns)

    # 1. 基础调度测试
    local deploy_file="${PROJECT_ROOT}/manifests/scheduling-test/deployment.yaml"
    if [[ -f "${deploy_file}" ]]; then
        kubectl apply -f "${deploy_file}" -n "${ns}" >/dev/null
        if ! wait_for_deployment "${ns}" "scheduling-test" "${TIMEOUT_DEPLOYMENT_READY:-180}"; then
            status="FAIL"
            conclusion="基础调度测试失败"
            detail="Deployment scheduling-test 未就绪"
        else
            log_pass "基础调度测试通过"
        fi
    else
        log_warn "缺少调度测试 Deployment 清单"
    fi

    # 2. ResourceQuota / LimitRange 测试
    local quota_file="${PROJECT_ROOT}/manifests/scheduling-test/quota.yaml"
    if [[ -f "${quota_file}" ]]; then
        kubectl apply -f "${quota_file}" -n "${ns}" >/dev/null
        # 验证是否创建成功
        if kubectl get resourcequota -n "${ns}" &>/dev/null; then
            log_pass "ResourceQuota/LimitRange 创建成功"
        else
            status="FAIL"
            conclusion="ResourceQuota 未生效"
            detail="无法获取 ResourceQuota"
        fi
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "调度检查通过"
    else
        log_fail "调度检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "调度检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"
