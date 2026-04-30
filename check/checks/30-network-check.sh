#!/usr/bin/env bash
# 30-network-check.sh - 网络功能检查
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-utils.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="网络功能正常"
    detail="-"

    local ns
    ns=$(ensure_test_ns)
    local timeout=${TIMEOUT_POD_READY:-120}

    # 1. 部署网络测试 DaemonSet（每个节点一个 nginx）
    local ds_file="${PROJECT_ROOT}/manifests/network-test/daemonset.yaml"
    if [[ ! -f "${ds_file}" ]]; then
        status="FAIL"
        conclusion="缺少测试清单"
        detail="未找到 ${ds_file}"
        end=$(date +%s)
        duration=$((end - start))s
        add_report_line "网络检查" "${status}" "${duration}" "${conclusion}" "${detail}"
        add_summary "${status}"
        return 1
    fi

    kubectl apply -f "${ds_file}" -n "${ns}" >/dev/null
    if ! wait_for_pod "${ns}" "app=net-test-nginx" "${timeout}"; then
        status="FAIL"
        conclusion="网络测试 Pod 未就绪"
        detail="DaemonSet Pod 未在 ${timeout}s 内 Ready"
        end=$(date +%s)
        duration=$((end - start))s
        add_report_line "网络检查" "${status}" "${duration}" "${conclusion}" "${detail}"
        add_summary "${status}"
        return 1
    fi

    # 2. DNS 解析测试
    local job_file="${PROJECT_ROOT}/manifests/network-test/dns-check-job.yaml"
    if [[ -f "${job_file}" ]]; then
        kubectl apply -f "${job_file}" -n "${ns}" >/dev/null
        if ! wait_for_job "${ns}" "dns-check" "${TIMEOUT_JOB_COMPLETE:-180}"; then
            status="FAIL"
            conclusion="DNS 解析测试失败"
            detail="dns-check Job 未完成"
        else
            log_pass "DNS 解析测试通过"
        fi
    else
        log_warn "未找到 DNS 测试 Job 清单，跳过 DNS 检查"
    fi

    # 3. Pod 跨节点通信测试
    local job_file2="${PROJECT_ROOT}/manifests/network-test/connectivity-job.yaml"
    if [[ -f "${job_file2}" ]]; then
        kubectl apply -f "${job_file2}" -n "${ns}" >/dev/null
        if ! wait_for_job "${ns}" "connectivity-check" "${TIMEOUT_JOB_COMPLETE:-180}"; then
            status="FAIL"
            conclusion="Pod 跨节点通信测试失败"
            detail="connectivity-check Job 未完成"
        else
            log_pass "Pod 跨节点通信测试通过"
        fi
    else
        log_warn "未找到连通性测试 Job 清单，跳过连通性检查"
    fi

    # 4. Ingress/NetworkPolicy（可选，仅当集群存在 IngressClass 时检查）
    local ingress_classes
    ingress_classes=$(kubectl get ingressclass --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${ingress_classes}" -gt 0 ]]; then
        log_info "检测到 ${ingress_classes} 个 IngressClass"
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "网络检查通过"
    else
        log_fail "网络检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "网络检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"
