#!/usr/bin/env bash
# 80-operator-crd.sh - Operator / CRD 专项验收
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/k8s-utils.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="Operator/CRD 正常"
    detail="-"

    # 1. CRD 状态检查
    local crd_total crd_not_established
    crd_total=$(kubectl get crd --no-headers 2>/dev/null | wc -l | tr -d ' ')
    crd_not_established=$(kubectl get crd -o json 2>/dev/null | jq -r '
        .items[] |
        select(.status.conditions[]? | select(.type == "Established") | .status != "True") |
        .metadata.name' | paste -sd ',' -)
    if [[ "${crd_total}" -eq 0 ]]; then
        log_info "集群中无自定义 CRD"
    else
        log_info "CRD 总数: ${crd_total}"
        if [[ -n "${crd_not_established}" ]]; then
            status="FAIL"
            conclusion="存在未 Established 的 CRD"
            detail="${crd_not_established}"
        fi
    fi

    # 2. Operator Pod 检查
    local op_labels
    op_labels="${OPERATOR_LABELS:-}"
    if [[ -n "${op_labels}" ]]; then
        local op_pods_not_ready
        op_pods_not_ready=$(kubectl get pod --all-namespaces -l "${op_labels}" --no-headers 2>/dev/null | grep -v "Running" | awk '{print $1"/"$2}' | paste -sd ',' -)
        if [[ -n "${op_pods_not_ready}" ]]; then
            status="FAIL"
            conclusion="Operator Pod 未全部就绪"
            detail="${op_pods_not_ready}"
        else
            local op_ready_count
            op_ready_count=$(kubectl get pod --all-namespaces -l "${op_labels}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
            log_info "Operator Pod 就绪数: ${op_ready_count}"
        fi
    else
        log_warn "未配置 OPERATOR_LABELS，跳过 Operator Pod 状态检查"
    fi

    # 3. CR 生命周期测试
    if [[ "${OPERATOR_CR_LIFECYCLE_TEST:-true}" == "true" && "${crd_total}" -gt 0 ]]; then
        local cr_file="${PROJECT_ROOT}/manifests/operator-test/sample-cr.yaml"
        local op_ns
        op_ns="${OPERATOR_TEST_NS:-$(ensure_test_ns)}"
        if [[ -f "${cr_file}" ]]; then
            # 应用 CR
            kubectl apply -f "${cr_file}" -n "${op_ns}" >/dev/null
            log_info "已应用示例 CR，等待状态 Ready..."
            # 等待逻辑：通常 Operator 会在 status 中设置 Ready 条件
            local cr_kind cr_name ready
            cr_kind=$(kubectl get -f "${cr_file}" -n "${op_ns}" -o jsonpath='{.kind}' 2>/dev/null || true)
            cr_name=$(kubectl get -f "${cr_file}" -n "${op_ns}" -o jsonpath='{.metadata.name}' 2>/dev/null || true)
            ready="false"
            for i in $(seq 1 $((${TIMEOUT_OPERATOR_CR:-300} / 5))); do
                if kubectl get "${cr_kind}" "${cr_name}" -n "${op_ns}" -o json 2>/dev/null | jq -e '.status.conditions[]? | select(.type == "Ready" or .type == "Available") | .status == "True"' &>/dev/null; then
                    ready="true"
                    break
                fi
                sleep 5
            done
            if [[ "${ready}" != "true" ]]; then
                status="FAIL"
                conclusion="示例 CR 未变为 Ready"
                detail="${cr_kind}/${cr_name} 在 ${TIMEOUT_OPERATOR_CR:-300}s 内未 Ready"
            else
                log_pass "示例 CR 生命周期创建阶段通过"
            fi

            # 删除 CR 并确认清理
            if [[ "${status}" == "PASS" ]]; then
                kubectl delete -f "${cr_file}" -n "${op_ns}" --wait=false >/dev/null
                sleep 3
                if resource_exists "${cr_kind}" "${cr_name}" "${op_ns}"; then
                    log_warn "CR 删除后仍可查询，可能存在 finalizer"
                else
                    log_pass "示例 CR 已清理"
                fi
            fi
        else
            log_warn "未找到 manifests/operator-test/sample-cr.yaml，跳过 CR 生命周期测试"
        fi
    fi

    # 4. Webhook 检查（如有）
    local webhook_svc
    webhook_svc=$(kubectl get crd -o json 2>/dev/null | jq -r '.items[] | select(.spec.conversion?.strategy == "Webhook") | .metadata.name' | head -1)
    if [[ -n "${webhook_svc}" ]]; then
        log_info "检测到 conversion webhook CRD: ${webhook_svc}"
    fi

    if [[ "${status}" == "PASS" ]]; then
        log_pass "Operator/CRD 检查通过"
    else
        log_fail "Operator/CRD 检查未通过: ${conclusion}"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "Operator/CRD" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"
