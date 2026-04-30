#!/usr/bin/env bash
# 70-ha-check.sh - 高可用性检查
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="高可用配置正常"
    detail="-"

    # 1. 控制平面 Endpoint 多后端
    local endpoints
    endpoints=$(kubectl get endpoints kubernetes -n default -o json 2>/dev/null | jq -r '.subsets[0].addresses | length')
    if [[ -z "${endpoints}" || "${endpoints}" == "0" ]]; then
        status="WARN"
        conclusion="无法获取 control plane endpoints"
        detail="kubectl get endpoints kubernetes 异常"
    elif [[ "${endpoints}" -lt 2 ]]; then
        log_warn "控制平面 Endpoint 仅 ${endpoints} 个后端，非高可用架构"
    else
        log_info "控制平面 Endpoint 后端数: ${endpoints}"
    fi

    # 2. etcd 成员数
    local etcd_members
    etcd_members=$(kubectl get pod -n kube-system -l component=etcd --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${etcd_members}" -lt 2 ]]; then
        log_warn "etcd Pod 数仅 ${etcd_members}，非高可用架构"
    else
        log_info "etcd Pod 数: ${etcd_members}"
    fi

    # 3. 工作节点分布
    local worker_count
    worker_count=$(kubectl get nodes --no-headers 2>/dev/null | grep -v "control-plane\|master" | wc -l | tr -d ' ')
    if [[ "${worker_count}" -lt 2 ]]; then
        log_warn "工作节点仅 ${worker_count} 个，无法验证驱逐/分布"
    else
        log_info "工作节点数: ${worker_count}"
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "高可用检查通过"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "高可用检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" || "${status}" == "WARN" ]]
}

run_check "$@"
