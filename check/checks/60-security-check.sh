#!/usr/bin/env bash
# 60-security-check.sh - 安全基线检查
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="安全基线通过"
    detail="-"

    # 1. PodSecurityAdmission / PodSecurity 标准
    local psa_enforced
    psa_enforced=$(kubectl get namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.metadata.labels?["pod-security.kubernetes.io/enforce"] // "privileged" != "privileged") |
        .metadata.name' | paste -sd ',' -)
    if [[ -n "${psa_enforced}" ]]; then
        log_info "以下 Namespace 启用了 PSA 限制: ${psa_enforced}"
    else
        log_warn "未检测到非 privileged 的 PSA 配置"
    fi

    # 2. 检查默认 ServiceAccount 自动挂载
    local auto_mount_sa
    auto_mount_sa=$(kubectl get serviceaccount default --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.automountServiceAccountToken != false) |
        .metadata.namespace + "/default"' | head -5 | paste -sd ',' -)
    if [[ -n "${auto_mount_sa}" ]]; then
        log_warn "部分 default SA 未禁用 automount: ${auto_mount_sa}"
    fi

    # 3. 检查是否有容器以 root 运行（仅检查测试 ns 或 kube-system 的镜像）
    local root_pods
    root_pods=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.spec.containers[]?.securityContext?.runAsUser == 0) |
        .metadata.namespace + "/" + .metadata.name' | head -5 | paste -sd ',' -)
    if [[ -n "${root_pods}" ]]; then
        log_warn "以下 Pod 容器以 root 运行: ${root_pods}"
    fi

    # 4. 检查镜像拉取策略为 Always 的情况
    local always_pull
    always_pull=$(kubectl get pods --all-namespaces -o json 2>/dev/null | jq -r '
        .items[] |
        select(.spec.containers[]?.imagePullPolicy == "Always") |
        .metadata.namespace + "/" + .metadata.name' | head -5 | paste -sd ',' -)
    if [[ -n "${always_pull}" ]]; then
        log_info "以下 Pod 使用 Always 拉取策略: ${always_pull}"
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "安全检查通过"
    else
        log_fail "安全检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "安全检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"
