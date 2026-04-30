#!/usr/bin/env bash
# 00-env-check.sh - 环境依赖与权限预检
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="环境就绪"
    detail="-"

    # 1. kubectl 存在性
    if ! command -v kubectl &>/dev/null; then
        status="FAIL"
        conclusion="kubectl 未安装"
        detail="未找到 kubectl 命令"
        end=$(date +%s)
        duration=$((end - start))s
        add_report_line "环境检查" "${status}" "${duration}" "${conclusion}" "${detail}"
        add_summary "${status}"
        return 1
    fi

    # 2. kubectl 版本
    local version
    version=$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || kubectl version --client 2>/dev/null | head -1 || echo "unknown")
    log_info "kubectl 版本: ${version}"

    # 3. kubeconfig 与连接性
    if ! kubectl cluster-info &>/dev/null; then
        status="FAIL"
        conclusion="无法连接集群"
        detail="kubectl cluster-info 失败，检查 kubeconfig"
        end=$(date +%s)
        duration=$((end - start))s
        add_report_line "环境检查" "${status}" "${duration}" "${conclusion}" "${detail}"
        add_summary "${status}"
        return 1
    fi

    # 4. 权限检查
    local can_list_nodes can_list_pods
    can_list_nodes=$(kubectl auth can-i list nodes 2>/dev/null || echo "no")
    can_list_pods=$(kubectl auth can-i list pods --all-namespaces 2>/dev/null || echo "no")
    if [[ "${can_list_nodes}" != "yes" || "${can_list_pods}" != "yes" ]]; then
        status="FAIL"
        conclusion="权限不足"
        detail="list nodes: ${can_list_nodes}, list pods: ${can_list_pods}"
        end=$(date +%s)
        duration=$((end - start))s
        add_report_line "环境检查" "${status}" "${duration}" "${conclusion}" "${detail}"
        add_summary "${status}"
        return 1
    fi

    log_pass "环境检查通过: kubectl ${version}, 权限正常"
    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "环境检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    return 0
}

run_check "$@"
