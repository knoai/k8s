#!/usr/bin/env bash
# 10-node-check.sh - 节点健康检查
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="所有节点正常"
    detail="-"

    local total ready not_ready pressure_nodes
    total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    ready=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || true)
    not_ready=$((total - ready))

    if [[ "${total}" -eq 0 ]]; then
        status="FAIL"
        conclusion="未获取到节点"
        detail="kubectl get nodes 返回空"
        end=$(date +%s)
        duration=$((end - start))s
        add_report_line "节点检查" "${status}" "${duration}" "${conclusion}" "${detail}"
        add_summary "${status}"
        return 1
    fi

    # 计算 Ready 率
    local ratio
    ratio=$(awk "BEGIN {printf \"%.2f\", ${ready}/${total}}")
    if awk "BEGIN {exit !(${ratio} < ${NODE_READY_MIN_RATIO:-1.0})}"; then
        status="FAIL"
        conclusion="节点 Ready 率不足"
        detail="Ready ${ready}/${total} (${ratio})，低于阈值 ${NODE_READY_MIN_RATIO:-1.0}"
    fi

    # 检查压力状态
    pressure_nodes=$(kubectl get nodes -o json 2>/dev/null | jq -r '
        .items[] |
        select(.status.conditions[]? | select(.type == "DiskPressure" or .type == "MemoryPressure" or .type == "PIDPressure") | .status == "True") |
        .metadata.name' | paste -sd ',' -)
    if [[ -n "${pressure_nodes}" ]]; then
        status="FAIL"
        conclusion="存在压力节点"
        detail="${pressure_nodes}"
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "节点检查通过: ${ready}/${total} Ready"
    else
        log_fail "节点检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "节点检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"
