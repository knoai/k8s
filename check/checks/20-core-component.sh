#!/usr/bin/env bash
# 20-core-component.sh - 核心组件健康检查
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-utils.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="核心组件正常"
    detail="-"

    # 1. kube-system 核心 Pod 状态
    local ns="kube-system"
    local total running ratio
    total=$(kubectl get pod -n "${ns}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    running=$(kubectl get pod -n "${ns}" --no-headers 2>/dev/null | grep -c "Running" || true)
    ratio=1.0
    if [[ "${total}" -gt 0 ]]; then
        ratio=$(awk "BEGIN {printf \"%.2f\", ${running}/${total}}")
    fi
    if awk "BEGIN {exit !(${ratio} < ${CORE_POD_READY_MIN_RATIO:-1.0})}"; then
        status="FAIL"
        conclusion="核心 Pod Ready 率不足"
        detail="Running ${running}/${total} (${ratio}) in ${ns}"
    fi

    # 2. apiserver 延迟
    local latency
    latency=$(apiserver_latency_ms)
    if [[ "${latency}" -gt "${APISERVER_LATENCY_MS_MAX:-500}" ]]; then
        status="FAIL"
        conclusion="apiserver 延迟过高"
        detail="${latency}ms > ${APISERVER_LATENCY_MS_MAX:-500}ms"
    fi
    log_info "apiserver 延迟: ${latency}ms"

    # 3. etcd 健康
    local etcd_healthy
    etcd_healthy=$(check_etcd_health)
    if [[ "${etcd_healthy}" != "N/A" && "${etcd_healthy}" -lt "${ETCD_HEALTHY_MIN:-1}" ]]; then
        status="FAIL"
        conclusion="etcd 健康检查未通过"
        detail="健康成员数: ${etcd_healthy}"
    fi

    # 4. coredns
    local coredns_ready
    coredns_ready=$(kubectl get deployment coredns -n "${ns}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${coredns_ready}" == "0" || -z "${coredns_ready}" ]]; then
        status="FAIL"
        conclusion="CoreDNS 未就绪"
        detail="readyReplicas=${coredns_ready}"
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "核心组件检查通过: latency=${latency}ms, coredns_ready=${coredns_ready}"
    else
        log_fail "核心组件检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "核心组件" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"
